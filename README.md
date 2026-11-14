# UNIX Integrated System Monitoring and Process Control Dashboard

**Design and Implementation of a UNIX-Based System Monitoring and Process Management System Using Shell Scripting**

A menu-driven **Bash** program with a **whiptail** box interface. It lets you **monitor** CPU, RAM and disk usage and **manage** running processes from one screen, all in a single shell script.

```
┌──────────── UNIX System Monitor and Process Manager ────────────┐
│ CPU  [##############------]  70%                                │
│ RAM  [###################-]  95%  << HIGH!                      │
│ DISK [####----------------]  21%                                │
│ Uptime: 0d 3h 12m    Test processes running: 1                  │
│                                                                 │
│        1   Show running processes                               │
│        2   CPU usage                                            │
│        3   RAM usage                                            │
│        4   Disk usage                                           │
│        5   Live CPU meter (10 seconds)                          │
│        6   Top 5 heavy processes                                │
│        7   Search for a process                                 │
│        8   Manage a process (pause / resume / kill)             │
│        ...                                                      │
│                                                                 │
│              <Select>                     <Exit>                │
└─────────────────────────────────────────────────────────────────┘
```

---

## Features

**Monitoring**
- CPU, RAM and disk usage as percentages, shown at the top of the main menu
- Animated progress bars: green below 70%, yellow from 70%, red from 90%
- Live CPU meter that updates every second
- **Red alert** when CPU, RAM or disk reaches 90%, offering to manage the process that uses the most

**Process management**
- List, search (by name or PID) and see the top 5 heavy processes
- **Pause** (`SIGSTOP`), **resume** (`SIGCONT`), **terminate** (`SIGTERM`), **force kill** (`SIGKILL`)
- **Change priority** (`renice`)
- Process status with its meaning (R, S, D, T, Z, I), state counts, zombie list
- Process tree (`pstree`)
- Live `jobs` / `bg` / `fg` job-control demo
- Export a full report to `sysmon_report.txt`

**Safety**
- Checks every input (empty, letters, spaces, PIDs that don't exist)
- Asks before pausing, terminating or killing anything
- Protects PID 1, systemd, kernel threads, the desktop, and the program and terminal themselves
- Explains permission errors and zombies instead of failing silently
- Built-in **test processes** (CPU-heavy, sleeping, zombie, full CPU load), so the demo never touches real programs

---

## Quick start

**Needs:** Linux (Ubuntu recommended) with `bash` and `whiptail`. On Windows, use **WSL** (Ubuntu). It does not run in CMD or PowerShell.

```bash
git clone "https://github.com/shreshav2404-code/unix-Integrated-System-Monitoring-and-Process-Control-Dashboard..git" sysmon
```
```bash
cd sysmon
```
```bash
bash sysmon.sh
```

If whiptail is missing:
```bash
sudo apt update && sudo apt install -y whiptail
```

**Keys:** arrows to move, Enter to select, Tab to reach the buttons, Esc to go back. The mouse doesn't work in whiptail boxes.

Full setup (including installing WSL on Windows), workflow diagrams, a step-by-step **viva demo script** and troubleshooting are in **[instructions.md](instructions.md)**.

---

## Menu options

| # | Option | UNIX commands used |
|---|---|---|
| 1 | Show running processes | `ps -eo ... --sort=-%cpu` |
| 2 | CPU usage | `/proc/stat`, `top -bn1`, `nproc`, `/proc/loadavg` |
| 3 | RAM usage | `/proc/meminfo`, `free -h` |
| 4 | Disk usage | `df -h` |
| 5 | Live CPU meter | `/proc/stat` every second |
| 6 | Top 5 heavy processes | `ps --sort=-%cpu`, `ps --sort=-%mem` |
| 7 | Search for a process | `pgrep -i`, `ps -p` |
| 8 | Manage a process | `kill -STOP / -CONT / -TERM / -KILL`, `renice` |
| 9 | Process status | `ps -o stat`, `uniq -c` |
| 10 | Process tree | `pstree -p` |
| 11 | Start test process | `yes > /dev/null &`, `sleep 600 &` |
| 12 | Jobs demo | `set -m`, `jobs`, `bg`, `fg` |
| 13 | Export report to file | all of the above |
| 14 | Help | |
| 0 | Exit | `trap ... EXIT` (stops test processes) |

---

## Project files

| File | Description |
|---|---|
| [`sysmon.sh`](sysmon.sh) | The whole program, a single Bash script |
| [`instructions.md`](instructions.md) | Setup, run steps, workflow diagrams, viva demo, troubleshooting |
| [`.gitattributes`](.gitattributes) | Keeps Linux line endings so the script works after cloning on Windows |

---

## Technologies

- **Bash** shell scripting
- **whiptail** (newt) for the text-based UI
- **procps** (`ps`, `top`, `free`, `pgrep`), **coreutils**, **util-linux** (`renice`), **psmisc** (`pstree`)
- Linux **/proc** filesystem (`/proc/stat`, `/proc/meminfo`, `/proc/loadavg`)
