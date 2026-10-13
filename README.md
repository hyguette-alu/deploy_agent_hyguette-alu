# deploy_agent — Student Attendance Tracker deployment agent

A single shell script, `deploy_agent.sh`, that deploys, runs and archives the
logs of the Student Attendance Tracker (`attendance_checker.py`).

> **Status:** repository skeleton. The script structure, menu and templates are
> in place; the feature bodies are being implemented next.

## Repository layout

```
deploy_agent_hyguette-alu/
├── deploy_agent.sh          # the agent: deploy, run, archive + signal handling
├── templates/               # unmodified source files
│   ├── attendance_checker.py
│   ├── assets.csv
│   └── config.json
└── README.md
```

## Running the agent

```bash
chmod +x deploy_agent.sh
./deploy_agent.sh
```

Features are selected from an interactive menu:

| Option | Feature | What it does |
| --- | --- | --- |
| 1 | Deploy | Builds `attendance_tracker_{name}/`, populates it, sets permissions, offers a threshold update, then verifies by running the app |
| 2 | Run | Executes `attendance_checker.py` inside an already deployed project |
| 3 | Archive | Copies the generated logs into timestamped files under `archives/` |
| 4 | Exit | Leaves the agent |

A feature name can also be passed as an argument to skip the menu:

```bash
./deploy_agent.sh deploy
./deploy_agent.sh run
./deploy_agent.sh archive
```

## Deployed project structure

```
attendance_tracker_{name}/
├── attendance_checker.py    # chmod +x
├── Helpers/
│   ├── assets.csv           # the class roster
│   └── config.json          # chmod 600 - grading-sensitive thresholds
└── reports/                 # starts empty; the app writes its logs here
```

## To be documented

- [ ] Roster options A (copy from template) and B (generate fresh), and how
      each one fixes `total_sessions` in `config.json`
- [ ] How the threshold update works (`read` + `sed` in place)
- [ ] How log archiving works (per-log directories + timestamped filenames)
- [ ] How to test the Ctrl+C / Ctrl+Z path and what the `.zip` contains
- [ ] How the deployed structure was tested
- [ ] Link to the run-through video

## Video

_To be added._
