#!/bin/bash
#
# deploy_agent.sh - Infrastructure-as-Code agent for the Student Attendance
# Tracker.
#
# Three features, picked from an interactive menu (or passed as an argument):
#   1. deploy  - build attendance_tracker_{name}/, populate it, secure it,
#                optionally retune the alert thresholds, then verify by running
#   2. run     - execute the app inside an already deployed project
#   3. archive - copy reports/*.log into timestamped files under archives/
#
# While feature 1 is building a project, SIGINT (Ctrl+C) and SIGTSTP (Ctrl+Z)
# are trapped: the half-built project is zipped and removed instead of being
# left behind.
#
# Usage:  ./deploy_agent.sh            # interactive menu
#         ./deploy_agent.sh deploy     # jump straight to one feature
#         ./deploy_agent.sh run
#         ./deploy_agent.sh archive

set -u

# ------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------

# Resolve the directory holding this script so templates/ is found no matter
# where the user invokes the agent from. Deployed projects are created here
# too, which keeps the interrupt .zip next to the project it came from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
cd "$SCRIPT_DIR" || exit 1

DEFAULT_WARNING=75
DEFAULT_FAILURE=50

# Sample roster used by Option B. Index i of one array pairs with index i of
# the other, so the two must stay the same length.
SAMPLE_NAMES=(
    "Aline Uwase"      "Brian Okoth"     "Chantal Mukamana" "David Adeyemi"
    "Esther Wanjiru"   "Felix Nsengiyumva" "Grace Achieng"  "Hamza Toure"
    "Ines Kabera"      "Joseph Mwangi"   "Keza Ingabire"    "Liam Banda"
)
SAMPLE_EMAILS=(
    "a.uwase@alustudent.com"    "b.okoth@alustudent.com"
    "c.mukamana@alustudent.com" "d.adeyemi@alustudent.com"
    "e.wanjiru@alustudent.com"  "f.nsengiyumva@alustudent.com"
    "g.achieng@alustudent.com"  "h.toure@alustudent.com"
    "i.kabera@alustudent.com"   "j.mwangi@alustudent.com"
    "k.ingabire@alustudent.com" "l.banda@alustudent.com"
)

# Set while a deployment is in flight so the signal handler knows what to zip.
# Empty means "nothing half-built right now".
PROJECT_IN_PROGRESS=""

# ------------------------------------------------------------------
# Small output helpers - one place to change the look of every message
# ------------------------------------------------------------------

info() { printf '  %s\n' "$*"; }
ok()   { printf '  [OK] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*"; }
err()  { printf '  [ERROR] %s\n' "$*" >&2; }

banner() {
    echo
    echo "=============================================================="
    echo " $*"
    echo "=============================================================="
}

# A whole number greater than zero. Used for every "how many students" prompt.
is_positive_int() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "$1" -gt 0 ]
}

# A percentage: whole number, 0-100. Used for the threshold prompts.
is_percent() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 0 ] && [ "$1" -le 100 ]
}

# Ask a yes/no question. Returns 0 for yes, 1 for anything else.
confirm() {
    local reply
    read -r -p "  $1 [y/N]: " reply
    case "$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')" in
        y | yes) return 0 ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------
# Signal handling (active only while a project is being built)
# ------------------------------------------------------------------

# Ctrl+C / Ctrl+Z during deployment. The rule is: never leave a half-made
# project on disk, but never throw the operator's work away either. So the
# partial directory is zipped first, then removed.
on_interrupt() {
    local signal="$1"
    local exit_code=130
    [ "$signal" = "SIGTSTP" ] && exit_code=148

    echo
    echo "=============================================================="
    echo " DEPLOYMENT INTERRUPTED ($signal)"
    echo "=============================================================="
    info "The deployment was stopped before it finished, so the project"
    info "is incomplete and cannot be trusted to run."

    if [ -n "$PROJECT_IN_PROGRESS" ] && [ -d "$PROJECT_IN_PROGRESS" ]; then
        local zip_name="${PROJECT_IN_PROGRESS}_archive.zip"
        info "Archiving whatever was built so far..."

        # zip adds to an existing archive rather than replacing it, which
        # would mix two different interrupted attempts into one file.
        rm -f "$zip_name"

        if zip -r -q "$zip_name" "$PROJECT_IN_PROGRESS"; then
            ok "Saved: $SCRIPT_DIR/$zip_name"
            rm -rf "$PROJECT_IN_PROGRESS"
            ok "Removed the incomplete directory: $PROJECT_IN_PROGRESS/"
            info "Inspect the archive with: unzip -l $zip_name"
        else
            err "Could not create $zip_name - leaving $PROJECT_IN_PROGRESS/ in place."
        fi
    else
        info "Nothing had been created yet, so there is nothing to archive."
    fi

    echo
    info "Session closed cleanly. Re-run the deploy feature to start over."
    exit "$exit_code"
}

arm_interrupt_trap() {
    trap 'on_interrupt SIGINT' INT
    trap 'on_interrupt SIGTSTP' TSTP
}

# Hand the signals back to the default handlers. This matters before the
# verification run: Ctrl+C there belongs to the Python marking session, not
# to this script.
disarm_interrupt_trap() {
    trap - INT TSTP
    PROJECT_IN_PROGRESS=""
}

# ------------------------------------------------------------------
# Shared prompts
# ------------------------------------------------------------------

# Read a project suffix and echo the full directory name on stdout.
# Status messages go to stderr so they do not pollute the captured value.
read_project_name() {
    local input
    while true; do
        read -r -p "  Project name suffix (attendance_tracker_<name>): " input
        if [ -z "$input" ]; then
            err "The name cannot be empty." ; continue
        fi
        # Anything outside this set would either break the path or make the
        # directory awkward to work with from the shell.
        case "$input" in
            *[!A-Za-z0-9_-]*)
                err "Use letters, digits, hyphens or underscores only."
                continue ;;
        esac
        break
    done
    printf 'attendance_tracker_%s\n' "$input"
}

# Ask for an existing deployment (features 2 and 3) and validate it.
read_existing_project() {
    local project
    project="$(read_project_name)" || return 1

    if [ ! -d "$project" ]; then
        err "No such project: $SCRIPT_DIR/$project"
        err "Deploy it first with feature 1."
        return 1
    fi
    printf '%s\n' "$project"
}

# ------------------------------------------------------------------
# Feature 1 - Deploy
# ------------------------------------------------------------------

# Every external command the agent depends on. Checking up front means a
# missing tool is reported before any directory is created, not halfway in.
preflight_checks() {
    banner "Pre-flight checks"
    local missing=0

    if command -v python3 >/dev/null 2>&1; then
        ok "python3 found - $(python3 --version 2>&1)"
    else
        err "python3 is not installed or not on PATH (needed to run the app)."
        missing=1
    fi

    if command -v zip >/dev/null 2>&1; then
        ok "zip found - $(command -v zip)"
    else
        err "zip is not installed or not on PATH (needed to archive an"
        err "interrupted deployment)."
        missing=1
    fi

    # Templates are part of the repo; without them there is nothing to deploy.
    local template
    for template in attendance_checker.py assets.csv config.json; do
        if [ -f "$TEMPLATE_DIR/$template" ]; then
            ok "template found - templates/$template"
        else
            err "Missing template: $TEMPLATE_DIR/$template"
            missing=1
        fi
    done

    if [ "$missing" -ne 0 ]; then
        err "Pre-flight failed. Fix the above and try again."
        return 1
    fi
    ok "All pre-flight checks passed."
}

# Build Helpers/assets.csv and echo the matching total_sessions on stdout.
#
# The two options differ in what the roster already contains, and
# total_sessions has to agree with it: the app expects every student to have
# total_sessions - 1 prior sessions on record.
#   Option A - template rows carry 4 prior sessions -> total_sessions 5
#   Option B - fresh rows start at 0/0, so today is session one -> 1
build_roster() {
    local roster="$1"
    local choice count sessions

    echo >&2
    info "How should the class roster be built?" >&2
    info "  A) Copy students from templates/assets.csv (they keep their" >&2
    info "     existing attendance history - 4 prior sessions each)" >&2
    info "  B) Generate a fresh roster (all counts start at 0)" >&2

    while true; do
        read -r -p "  Choose A or B: " choice
        case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
            a)
                local available
                # Count data rows, ignoring the header and any blank lines, so
                # the agent never asks for more students than exist.
                available=$(( $(grep -c '[^[:space:]]' "$TEMPLATE_DIR/assets.csv") - 1 ))
                info "The template has $available students." >&2

                while true; do
                    read -r -p "  How many to copy (1-$available): " count
                    if ! is_positive_int "$count"; then
                        err "Enter a whole number greater than 0."
                    elif [ "$count" -gt "$available" ]; then
                        err "Only $available students are available."
                    else
                        break
                    fi
                done

                # head -n count+1 keeps the header row plus `count` students.
                head -n "$(( count + 1 ))" "$TEMPLATE_DIR/assets.csv" > "$roster"
                sessions=5
                ok "Copied $count students from the template roster." >&2
                break ;;
            b)
                local available=${#SAMPLE_NAMES[@]}
                info "This agent can generate up to $available students." >&2

                while true; do
                    read -r -p "  How many to generate (1-$available): " count
                    if ! is_positive_int "$count"; then
                        err "Enter a whole number greater than 0."
                    elif [ "$count" -gt "$available" ]; then
                        err "Only $available sample students are defined."
                    else
                        break
                    fi
                done

                # Header first, then one row per student with zeroed counts.
                printf 'Email,Names,Attendance Count,Absence Count\n' > "$roster"
                local i=0
                while [ "$i" -lt "$count" ]; do
                    printf '%s,%s,0,0\n' \
                        "${SAMPLE_EMAILS[$i]}" "${SAMPLE_NAMES[$i]}" >> "$roster"
                    i=$(( i + 1 ))
                done
                sessions=1
                ok "Generated a fresh roster of $count students." >&2
                break ;;
            *)
                err "Please answer A or B." ;;
        esac
    done

    printf '%s\n' "$sessions"
}

# Rewrite a single "key": number line in place, leaving the rest of the JSON
# byte-for-byte untouched - no reformatting, no reordering.
#
# -i.bak is the portable form: GNU sed accepts a zero-length suffix, BSD/macOS
# sed does not, so a suffix is written and then deleted.
patch_json_number() {
    local key="$1" value="$2" file="$3"
    sed -i.bak "s/\(\"$key\"[[:space:]]*:[[:space:]]*\)[0-9][0-9]*/\1$value/" "$file"
    rm -f "$file.bak"
}

# Optional retune of the alert thresholds in the deployed config.json.
update_thresholds() {
    local config="$1"
    local warning failure

    echo
    info "Current alert thresholds:"
    grep -E '"(warning|failure)"' "$config" | sed 's/^/    /'

    if ! confirm "Update the attendance alert thresholds?"; then
        info "Keeping the thresholds as deployed."
        return 0
    fi

    while true; do
        read -r -p "  Warning threshold % [default $DEFAULT_WARNING]: " warning
        [ -z "$warning" ] && warning=$DEFAULT_WARNING
        is_percent "$warning" && break
        err "Enter a whole number between 0 and 100."
    done

    while true; do
        read -r -p "  Failure threshold % [default $DEFAULT_FAILURE]: " failure
        [ -z "$failure" ] && failure=$DEFAULT_FAILURE
        if ! is_percent "$failure"; then
            err "Enter a whole number between 0 and 100."
        elif [ "$failure" -ge "$warning" ]; then
            # Failure must be the stricter of the two, otherwise the app's
            # WARNING band would be empty and no student could ever land in it.
            err "Failure ($failure) must be below warning ($warning)."
        else
            break
        fi
    done

    patch_json_number warning "$warning" "$config"
    patch_json_number failure "$failure" "$config"

    # sed wrote the file through a temporary copy, so re-assert the lockdown.
    chmod 600 "$config"

    ok "Thresholds updated:"
    grep -E '"(warning|failure)"' "$config" | sed 's/^/    /'
}

deploy_project() {
    banner "FEATURE 1 - Deploy the application"

    preflight_checks || return 1

    local project
    project="$(read_project_name)" || return 1

    if [ -d "$project" ]; then
        echo
        warn "$project/ already exists and holds a roster and logs of its own."
        if ! confirm "Overwrite it? Everything inside will be lost."; then
            err "Deployment aborted - the existing project was left untouched."
            return 1
        fi
        rm -rf "$project"
        info "Removed the previous $project/."
    fi

    # From here until the project is complete, Ctrl+C / Ctrl+Z must archive
    # rather than abandon. Record the name first so the handler can find it.
    PROJECT_IN_PROGRESS="$project"
    arm_interrupt_trap

    echo
    info "Building $project/ ..."
    info "(Ctrl+C or Ctrl+Z from here on will archive the partial project.)"

    # Structure the Python app expects: the script at the project root, its
    # inputs under Helpers/, and an empty reports/ it will fill on first run.
    mkdir -p "$project/Helpers" "$project/reports"
    ok "Created $project/, $project/Helpers/, $project/reports/"

    # attendance_checker.py and config.json always deploy unmodified.
    cp "$TEMPLATE_DIR/attendance_checker.py" "$project/attendance_checker.py"
    cp "$TEMPLATE_DIR/config.json" "$project/Helpers/config.json"
    ok "Deployed attendance_checker.py and Helpers/config.json"

    # The roster is the one file the operator gets to shape.
    local total_sessions
    total_sessions="$(build_roster "$project/Helpers/assets.csv")" || return 1

    # Keep the config honest about how many sessions the roster has seen.
    patch_json_number total_sessions "$total_sessions" "$project/Helpers/config.json"
    ok "Set total_sessions=$total_sessions to match the roster."

    # --- Permissions -----------------------------------------------
    echo
    info "Applying permissions..."
    # The app is launched directly, so it needs the execute bit.
    chmod +x "$project/attendance_checker.py"
    # config.json holds the pass/fail thresholds. Owner read/write only keeps
    # other accounts on this machine from reading or editing grading rules.
    chmod 600 "$project/Helpers/config.json"
    ok "chmod +x  attendance_checker.py   -> $(ls -l "$project/attendance_checker.py" | cut -d' ' -f1)"
    ok "chmod 600 Helpers/config.json     -> $(ls -l "$project/Helpers/config.json" | cut -d' ' -f1)"

    # --- Thresholds ------------------------------------------------
    update_thresholds "$project/Helpers/config.json"

    echo
    info "Deployed structure:"
    find "$project" -print | sort | sed 's/^/    /'

    ok "Deployment of $project/ is complete."

    # The project is whole, so there is no longer a partial build to rescue.
    # Disarm before running: Ctrl+C now belongs to the marking session.
    disarm_interrupt_trap

    # --- Verification ----------------------------------------------
    echo
    info "Verifying the deployment by running the application."
    info "A successful start proves the structure, roster and config agree."
    run_project "$project"
}

# ------------------------------------------------------------------
# Feature 2 - Run
# ------------------------------------------------------------------

# Launch the app from inside the project. The cd happens in a subshell so the
# agent itself stays put in SCRIPT_DIR afterwards.
run_project() {
    local project="$1"

    banner "FEATURE 2 - Running $project"
    info "Handing the terminal to attendance_checker.py - mark each student."
    echo

    ( cd "$project" && python3 attendance_checker.py )
    local rc=$?

    echo
    case "$rc" in
        0)   ok "The marking session finished normally." ;;
        130) warn "The marking session was interrupted (Ctrl+C). Students"
             warn "marked before the interrupt were still saved." ;;
        *)   err "attendance_checker.py exited with status $rc." ;;
    esac

    info "Logs now in $project/reports/ can be archived with feature 3."
    return 0
}

run_feature() {
    local project
    project="$(read_existing_project)" || return 1
    run_project "$project"
}

# ------------------------------------------------------------------
# Feature 3 - Archive the logs
# ------------------------------------------------------------------

# Copy one log into its own archive directory under a timestamped name.
# Returns 0 if it archived something, 1 if the log did not exist.
archive_one_log() {
    local project="$1" name="$2" stamp="$3"
    local source="$project/reports/$name.log"
    local dest_dir="$project/archives/$name"
    local dest="$dest_dir/${name}_${stamp}.log"

    if [ ! -f "$source" ]; then
        return 1
    fi

    mkdir -p "$dest_dir"
    cp "$source" "$dest"
    ok "$name.log -> $dest"
    return 0
}

archive_logs() {
    banner "FEATURE 3 - Archive the log files"

    local project
    project="$(read_existing_project)" || return 1

    # One timestamp for the whole run, so both logs from the same session carry
    # the same name and can be read as a pair later.
    local stamp
    stamp="$(date +%Y%m%d_%H%M%S)"
    info "Archiving logs from $project/reports/ (timestamp $stamp)"
    echo

    local archived=0

    # A missing log is normal, not an error: attendance_checker.py only writes
    # absent.log when at least one student was marked absent.
    archive_one_log "$project" "attendance" "$stamp" \
        && archived=$(( archived + 1 )) \
        || warn "No reports/attendance.log yet - run the app first (feature 2)."

    archive_one_log "$project" "absent" "$stamp" \
        && archived=$(( archived + 1 )) \
        || warn "No reports/absent.log - nobody has been marked absent."

    echo
    if [ "$archived" -eq 0 ]; then
        warn "Nothing was archived. $project/reports/ holds no logs."
        return 0
    fi

    ok "Archived $archived log file(s)."
    info "Archive tree:"
    find "$project/archives" -print | sort | sed 's/^/    /'
}

# ------------------------------------------------------------------
# Menu
# ------------------------------------------------------------------

show_menu() {
    echo
    echo "=============================================================="
    echo " Attendance Tracker - Deployment Agent"
    echo "=============================================================="
    echo "  1) Deploy the application  (build, secure and verify a project)"
    echo "  2) Run the application     (mark a session in a deployed project)"
    echo "  3) Archive the log files   (timestamped copies under archives/)"
    echo "  4) Exit"
    echo "--------------------------------------------------------------"
}

dispatch() {
    case "$1" in
        1 | deploy)  deploy_project ;;
        2 | run)     run_feature ;;
        3 | archive) archive_logs ;;
        *)
            err "Unknown feature: $1"
            err "Expected 1/deploy, 2/run or 3/archive."
            return 1 ;;
    esac
}

main() {
    # A feature name on the command line skips the menu and runs once.
    if [ "$#" -gt 0 ]; then
        dispatch "$1"
        exit $?
    fi

    local choice
    while true; do
        show_menu
        read -r -p "  Select a feature [1-4]: " choice || { echo; break; }
        case "$choice" in
            4 | q | quit | exit)
                echo
                info "Goodbye."
                break ;;
            '')
                err "Please choose 1, 2, 3 or 4." ;;
            *)
                dispatch "$choice" ;;
        esac
    done
}

main "$@"
