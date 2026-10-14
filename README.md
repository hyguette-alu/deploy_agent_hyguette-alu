# deploy_agent — Student Attendance Tracker deployment agent

A single shell script, `deploy_agent.sh`, that deploys, runs and archives the
logs of the Student Attendance Tracker (`attendance_checker.py`).

Setting an environment up by hand is slow and easy to get wrong — one typo in a
directory name and the application cannot find its roster. This agent turns the
whole setup into one reproducible command: the same structure, the same
permissions and a config that always agrees with the roster, every time.

## Repository layout

```
deploy_agent_hyguette-alu/
├── deploy_agent.sh          # the agent: deploy, run, archive + signal handling
├── templates/               # the three source files, unmodified
│   ├── attendance_checker.py
│   ├── assets.csv
│   └── config.json
├── README.md
└── .gitignore               # deployed projects and .zip archives are build output
```

## Requirements

- `bash`
- `python3` — runs the application
- `zip` — archives an interrupted deployment

The agent checks for all three before it creates anything.

## How to run it and select a feature

```bash
chmod +x deploy_agent.sh
./deploy_agent.sh
```

With no arguments the agent shows an **interactive menu** and loops until you
choose Exit:

| Option | Feature | What it does |
| --- | --- | --- |
| 1 | Deploy | Builds `attendance_tracker_{name}/`, populates it, sets permissions, offers a threshold update, then verifies by running the app |
| 2 | Run | Executes `attendance_checker.py` inside an already deployed project |
| 3 | Archive | Copies the generated logs into timestamped files under `archives/` |
| 4 | Exit | Leaves the agent |

A feature name can also be passed as an argument to run it once and exit —
handy for scripting and for demos:

```bash
./deploy_agent.sh deploy     # or: 1
./deploy_agent.sh run        # or: 2
./deploy_agent.sh archive    # or: 3
```

Projects are always created next to `deploy_agent.sh`, regardless of the
directory you invoke it from.

## Feature 1 — Deploy

1. **Pre-flight checks.** Confirms `python3` and `zip` are installed (reporting
   the version `python3 --version` gives back), that all three templates are
   present *and readable*, and that the working directory is writable. If
   anything is missing the agent reports it and stops *before* creating any
   directory.
2. **Names the project.** Prompts for a suffix and builds
   `attendance_tracker_{suffix}/`. The suffix is restricted to letters, digits,
   hyphens and underscores so it cannot break the path.
   If the directory already exists the agent refuses to silently overwrite it:
   it warns, asks for confirmation, and aborts with a clear error if you decline.
3. **Creates the structure** the application expects:

   ```
   attendance_tracker_{name}/
   ├── attendance_checker.py    # chmod +x
   ├── Helpers/
   │   ├── assets.csv           # the class roster
   │   └── config.json          # chmod 600
   └── reports/                 # starts empty; the app writes its logs here
   ```

4. **Populates it.** `attendance_checker.py` and `config.json` are always
   deployed unmodified from `templates/`. The roster is built from your choice
   of the two options below.
5. **Sets permissions** and prints what it applied.
   Every filesystem step — `mkdir`, both `cp`s, the roster write and both
   `chmod`s — is checked. If one fails (a denied write being the usual cause)
   the agent names the step that failed, shows the reason the command gave,
   removes the partial directory and aborts, rather than carrying on and
   producing a project that looks deployed but is broken. A `chmod 600` that
   fails is treated as fatal too: a config left world-readable is a security
   failure, not a cosmetic one.
6. **Offers to update the alert thresholds.**
7. **Verifies the deployment** by running the application (Feature 2). A
   successful start proves the structure, roster and config all agree.

### Roster options and `total_sessions`

`config.json`'s `total_sessions` counts every session *including today's*, so
it must always be one more than the prior sessions recorded in the roster. The
application warns on every student whose counts disagree with it, so the agent
sets the value to match whichever roster you build — no extra prompt needed:

| Option | Roster | Prior sessions per student | `total_sessions` |
| --- | --- | --- | --- |
| **A** — copy from the template | first *N* rows of `templates/assets.csv`, plus the header | 4 (`Attendance Count` + `Absence Count`) | **5** |
| **B** — generate a fresh roster | *N* rows built in the script from its own name/email arrays, counts starting at `0,0` | 0 | **1** |

Either way the agent asks how many students you want and refuses a count larger
than what is available (10 in the template, 12 generated names).

### Permissions

| File | Mode | Why |
| --- | --- | --- |
| `attendance_checker.py` | `chmod +x` | it is launched directly, so it needs the execute bit |
| `Helpers/config.json` | `chmod 600` | it holds the pass/fail thresholds — owner read/write only keeps other accounts on the machine from reading or editing grading rules |

The agent prints the resulting mode strings (`-rwxr-xr-x`, `-rw-------`) so you
can confirm them at a glance.

### How the threshold update works

After setting permissions the agent prints the current thresholds and asks
whether you want to change them. Decline and the deployed defaults stand.
Accept and it reads two values with `read`, each offering a default:

- `warning` (default **75**) — below this, a student is flagged `WARNING`
- `failure` (default **50**) — below this, a student is flagged `URGENT`

Both must be whole numbers from 0 to 100, and `failure` must be **below**
`warning` — otherwise the `WARNING` band would be empty and no student could
ever land in it. Invalid input is rejected and re-prompted.

The edit is then made in place with `sed`, one line at a time:

```bash
sed -i.bak "s/\(\"warning\"[[:space:]]*:[[:space:]]*\)[0-9][0-9]*/\1$value/" config.json
```

The pattern captures the key and its punctuation and replaces **only the
digits**, so the file is never reformatted or reordered — a diff against the
template shows the two numbers changed and nothing else. The `.bak` suffix is
the portable form of `sed -i` (macOS/BSD `sed` rejects a zero-length suffix);
the backup is deleted immediately after. Because `sed` writes through a
temporary file, the agent re-applies `chmod 600` afterwards.

The same helper sets `total_sessions`, which is why that line keeps its
original formatting too.

## Feature 2 — Run

Prompts for an existing project, `cd`s into it (inside a subshell, so the agent
itself stays put) and runs:

```bash
python3 attendance_checker.py
```

The application is interactive — it hands you the terminal and asks you to mark
each student `[P]resent` or `[A]bsent`, updates the counts in `assets.csv`, and
writes the session into `reports/`. The agent reports how the session ended,
including a clean message if you interrupted the marking partway through
(exit 130), where the students already marked are still saved.

## Feature 3 — Archive the log files

Prompts for an existing project, takes **one** timestamp for the whole run and
copies each log into its own directory:

```
attendance_tracker_{name}/
└── archives/
    ├── attendance/
    │   └── attendance_20260927_143022.log
    └── absent/
        └── absent_20260927_143022.log
```

The filename carries `YYYYMMDD_HHMMSS`, so every archived copy is unique and
traceable, and both logs from the same session share a timestamp and can be read
as a pair. Running the feature twice simply produces two distinct files.

A missing log is normal, not an error: `attendance_checker.py` only creates
`absent.log` once somebody has actually been marked absent. The agent reports
each log it archived, notes any that did not exist, and carries on:

```
  [OK] attendance.log -> attendance_tracker_demo/archives/attendance/attendance_20261013_155240.log
  [!]  No reports/absent.log - nobody has been marked absent.

  [OK] Archived 1 log file(s).
```

## Signal handling — Ctrl+C and Ctrl+Z

While Feature 1 is building a project, `SIGINT` (Ctrl+C) and `SIGTSTP` (Ctrl+Z)
are trapped. The rule is: never leave a half-made project on disk, but never
throw away what was built either. On either signal the agent:

1. prints a clear message explaining that the deployment was interrupted,
2. zips whatever of `attendance_tracker_{name}/` exists into
   `attendance_tracker_{name}_archive.zip`,
3. removes the incomplete directory, and
4. exits cleanly (130 for Ctrl+C, 148 for Ctrl+Z).

If the signal arrives before anything was created, it says so and exits without
writing an empty archive.

The trap covers the build only. It is disarmed before the verification run, so
Ctrl+C during a marking session belongs to `attendance_checker.py` — the
application saves the students already marked and exits on its own terms.

One design detail matters here: the interactive prompts store their answers in
globals rather than echoing values back through `$(...)`. Command substitution
runs in a subshell, and bash defers the parent's traps until a subshell
finishes — so a Ctrl+C arriving while you sat at the roster prompt would have
been swallowed instead of triggering the archive. Keeping the reads in the main
shell keeps the handler responsive at every prompt of the deployment.

### How to test it

```bash
./deploy_agent.sh deploy
# answer the project-name prompt, e.g.  demo
# then press Ctrl+C (or Ctrl+Z) at the "How should the class roster be built?" prompt
```

Expected output:

```
==============================================================
 DEPLOYMENT INTERRUPTED (SIGINT)
==============================================================
  The deployment was stopped before it finished, so the project
  is incomplete and cannot be trusted to run.
  Archiving whatever was built so far...
  [OK] Saved: .../attendance_tracker_demo_archive.zip
  [OK] Removed the incomplete directory: attendance_tracker_demo/
```

Then confirm the directory is gone and inspect the archive:

```bash
ls -d attendance_tracker_demo        # No such file or directory
unzip -l attendance_tracker_demo_archive.zip
```

It contains exactly what had been built at the moment of the interrupt — the
directory skeleton and the files copied so far, with the roster still missing
because the interrupt landed before it was written:

```
attendance_tracker_demo/
attendance_tracker_demo/attendance_checker.py
attendance_tracker_demo/Helpers/
attendance_tracker_demo/Helpers/config.json
attendance_tracker_demo/reports/
```

Interrupt at a later prompt and the archive contains correspondingly more.

## Video
Here is the link to my demo
(https://youtu.be/k3Ose79uC5w)
