#!/bin/bash
# Three features, picked from an interactive menu (or passed as an argument):
#   1. deploy  - build attendance_tracker_{name}/, populate it, secure it,
#                optionally retune the alert thresholds, then verify by running
#   2. run     - execute the app inside an already deployed project
#   3. archive - copy reports/*.log into timestamped files under archives/
#
# Usage:  ./deploy_agent.sh            # interactive menu
#         ./deploy_agent.sh deploy     # jump straight to one feature
#         ./deploy_agent.sh run
#         ./deploy_agent.sh archive

set -u

# ------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
cd "$SCRIPT_DIR" || exit 1

DEFAULT_WARNING=75
DEFAULT_FAILURE=50

# Sample roster 
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

PROJECT_IN_PROGRESS=""
PROJECT_NAME=""
ROSTER_SESSIONS=""

# ------------------------------------------------------------------
#                   Small output helpers 
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

step() {
    local what="$1"
    shift
    if "$@"; then
        return 0
    fi
    echo
    err "Could not $what."
    err "Check that you own $SCRIPT_DIR and have write permission there."
    return 1
}

abort_partial_deploy() {
    local project="$1"
    if [ -d "$project" ]; then
        if rm -rf "$project" 2>/dev/null; then
            info "Removed the incomplete $project/."
        else
            warn "Could not remove $project/ - please delete it by hand."
        fi
    fi
    disarm_interrupt_trap
    err "Deployment aborted. Nothing was left half-built."
}

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

disarm_interrupt_trap() {
    trap - INT TSTP
    PROJECT_IN_PROGRESS=""
}
read_project_name() {
    local input
    PROJECT_NAME=""
    while true; do
        read -r -p "  Project name suffix (attendance_tracker_<name>): " input
        if [ -z "$input" ]; then
            err "The name cannot be empty." ; continue
        fi
        case "$input" in
            *[!A-Za-z0-9_-]*)
                err "Use letters, digits, hyphens or underscores only."
                continue ;;
        esac
        break
    done
    PROJECT_NAME="attendance_tracker_$input"
}

read_existing_project() {
    read_project_name || return 1

    if [ ! -d "$PROJECT_NAME" ]; then
        err "No such project: $SCRIPT_DIR/$PROJECT_NAME"
        err "Deploy it first with feature 1."
        return 1
    fi
}

# ------------------------------------------------------------------
# Feature 1 - Deploy
# ------------------------------------------------------------------
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

    local template
    for template in attendance_checker.py assets.csv config.json; do
        if [ ! -f "$TEMPLATE_DIR/$template" ]; then
            err "Missing template: $TEMPLATE_DIR/$template"
            missing=1
        elif [ ! -r "$TEMPLATE_DIR/$template" ]; then
            err "Cannot read template (permission denied): templates/$template"
            missing=1
        else
            ok "template found - templates/$template"
        fi
    done
    if [ -w "$SCRIPT_DIR" ]; then
        ok "write permission confirmed - $SCRIPT_DIR"
    else
        err "No write permission in $SCRIPT_DIR - cannot create a project there."
        missing=1
    fi

    if [ "$missing" -ne 0 ]; then
        err "Pre-flight failed. Fix the above and try again."
        return 1
    fi
    ok "All pre-flight checks passed."
}

build_roster() {
    local roster="$1"
    local choice count

    ROSTER_SESSIONS=""

    echo
    info "How should the class roster be built?"
    info "  A) Copy students from templates/assets.csv"
    info "  B) Generate a fresh roster (all counts start at 0)"

    while true; do
        read -r -p "  Choose A or B: " choice
        case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
            a)
                local available
                available=$(( $(grep -c '[^[:space:]]' "$TEMPLATE_DIR/assets.csv") - 1 ))
                info "The template has $available students."

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

                if ! head -n "$(( count + 1 ))" "$TEMPLATE_DIR/assets.csv" > "$roster"; then
                    err "Could not write the roster to $roster."
                    return 1
                fi
                ROSTER_SESSIONS=5
                ok "Copied $count students from the template roster."
                break ;;
            b)
                local available=${#SAMPLE_NAMES[@]}
                info "This agent can generate up to $available students."

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
                if ! printf 'Email,Names,Attendance Count,Absence Count\n' > "$roster"; then
                    err "Could not write the roster to $roster."
                    return 1
                fi
                local i=0
                while [ "$i" -lt "$count" ]; do
                    printf '%s,%s,0,0\n' \
                        "${SAMPLE_EMAILS[$i]}" "${SAMPLE_NAMES[$i]}" >> "$roster"
                    i=$(( i + 1 ))
                done
                ROSTER_SESSIONS=1
                ok "Generated a fresh roster of $count students."
                break ;;
            *)
                err "Please answer A or B." ;;
        esac
    done
}

patch_json_number() {
    local key="$1" value="$2" file="$3"
    sed -i.bak "s/\(\"$key\"[[:space:]]*:[[:space:]]*\)[0-9][0-9]*/\1$value/" "$file"
    rm -f "$file.bak"
}

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

            err "Failure ($failure) must be below warning ($warning)."
        else
            break
        fi
    done

    patch_json_number warning "$warning" "$config"
    patch_json_number failure "$failure" "$config"
    chmod 600 "$config"

    ok "Thresholds updated:"
    grep -E '"(warning|failure)"' "$config" | sed 's/^/    /'
}

deploy_project() {
    banner "FEATURE 1 - Deploy the application"

    preflight_checks || return 1

    read_project_name || return 1
    local project="$PROJECT_NAME"

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

    PROJECT_IN_PROGRESS="$project"
    arm_interrupt_trap

    echo
    info "Building $project/ ..."
    info "(Ctrl+C or Ctrl+Z from here on will archive the partial project.)"

    step "create the project directories" \
        mkdir -p "$project/Helpers" "$project/reports" \
        || { abort_partial_deploy "$project"; return 1; }
    ok "Created $project/, $project/Helpers/, $project/reports/"

    step "copy attendance_checker.py into $project/" \
        cp "$TEMPLATE_DIR/attendance_checker.py" "$project/attendance_checker.py" \
        || { abort_partial_deploy "$project"; return 1; }
    step "copy config.json into $project/Helpers/" \
        cp "$TEMPLATE_DIR/config.json" "$project/Helpers/config.json" \
        || { abort_partial_deploy "$project"; return 1; }
    ok "Deployed attendance_checker.py and Helpers/config.json"

    build_roster "$project/Helpers/assets.csv" \
        || { abort_partial_deploy "$project"; return 1; }

    patch_json_number total_sessions "$ROSTER_SESSIONS" "$project/Helpers/config.json"
    ok "Set total_sessions=$ROSTER_SESSIONS to match the roster."

    # --- Permissions -----------------------------------------------
    echo
    info "Applying permissions..."
    step "make attendance_checker.py executable" \
        chmod +x "$project/attendance_checker.py" \
        || { abort_partial_deploy "$project"; return 1; }

    step "restrict Helpers/config.json to owner read/write" \
        chmod 600 "$project/Helpers/config.json" \
        || { abort_partial_deploy "$project"; return 1; }
    ok "chmod +x  attendance_checker.py   -> $(ls -l "$project/attendance_checker.py" | cut -d' ' -f1)"
    ok "chmod 600 Helpers/config.json     -> $(ls -l "$project/Helpers/config.json" | cut -d' ' -f1)"

    update_thresholds "$project/Helpers/config.json"

    echo
    info "Deployed structure:"
    find "$project" -print | sort | sed 's/^/    /'

    ok "Deployment of $project/ is complete."

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
    read_existing_project || return 1
    run_project "$PROJECT_NAME"
}

# ------------------------------------------------------------------
# Feature 3 - Archive the logs
# ------------------------------------------------------------------

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

    read_existing_project || return 1
    local project="$PROJECT_NAME"

    local stamp
    stamp="$(date +%Y%m%d_%H%M%S)"
    info "Archiving logs from $project/reports/ (timestamp $stamp)"
    echo

    local archived=0

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
    echo "  1) Deploy the application"
    echo "  2) Run the application"
    echo "  3) Archive the log files"
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
