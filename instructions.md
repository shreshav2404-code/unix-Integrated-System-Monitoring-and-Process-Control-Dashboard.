# UNIX-Based System Monitoring and Process Management System

**Full title:** Design and Implementation of a UNIX-Based System Monitoring and Process Management System Using Shell Scripting

A menu-driven Bash program, with a whiptail box UI, that lets you:

- **Monitor** CPU, RAM and disk usage (shown as percentages, text bars and coloured progress bars)
- **Manage** processes: list, search, pause, resume, terminate, force kill, change priority
- **Learn** process states (Running, Sleeping, Stopped, Zombie), the process tree, and job control (`jobs`, `bg`, `fg`)

Everything is in **one file: `sysmon.sh`**.

---

## 1. Files

| File | What it is |
|---|---|
| `sysmon.sh` | The whole program. Run this. |
| `instructions.md` | This guide. |
| `sysmon_report.txt` | Created when you use **Export report to file** (option 13). It is saved next to `sysmon.sh`, or in your home folder if that folder can't be written. The program shows where it saved it. |

---

## 2. What you need

| Need | Why |
|---|---|
| **Linux** (Ubuntu recommended) | The program uses Linux commands and `/proc`. It does **not** run in Windows CMD or PowerShell. |
| **bash** | The shell that runs the script (already installed on Ubuntu). |
| **whiptail** | Draws the menu boxes (usually already installed on Ubuntu). |
| **procps, coreutils, util-linux** | Provide `ps`, `top`, `free`, `df`, `kill`, `pgrep`, `renice` (already installed on Ubuntu). |
| A terminal at least **70 × 20** characters | So the boxes fit. |

---

## 3. Setup on Windows (using WSL + Ubuntu)

You only need to do this once.

1. Open **PowerShell as Administrator** (Start menu → type *PowerShell* → right-click → *Run as administrator*).
2. Install Ubuntu:
   ```bash
   wsl --install -d Ubuntu
   ```
3. Restart the PC if it asks you to.
4. Open **Ubuntu** from the Start menu. The first time, it asks you to create a **username** and **password**. Remember the password, because `sudo` asks for it.
5. Your Windows drives appear inside Ubuntu under `/mnt`:
   - `C:\` → `/mnt/c`
   - `D:\` → `/mnt/d`

   So the project folder `D:\unix` is `/mnt/d/unix`.

## 3b. Setup on a Linux PC (college lab or Ubuntu desktop)

Copy `sysmon.sh` into any folder (for example your home folder). Nothing else is needed.

---

## 4. Install whiptail (only if it is missing)

Check first:
```bash
whiptail --version
```
If you see `command not found`, install it:
```bash
sudo apt update && sudo apt install -y whiptail
```
Optional, for a nicer process tree (option 10):
```bash
sudo apt install -y psmisc
```

---

## 5. Fix Windows line endings (important if you edited the file in Windows)

Windows editors can save lines ending in `CRLF`. Bash then fails with errors like:
```
$'\r': command not found
syntax error near unexpected token `$'{\r''
```
Fix it with:
```bash
sed -i 's/\r$//' sysmon.sh
```
Or in VS Code, click **CRLF** at the bottom-right of the window, choose **LF**, then save.

---

## 6. Run the program

```bash
cd /mnt/d/unix
```
```bash
bash sysmon.sh
```

Optional: make it runnable as `./sysmon.sh`:
```bash
chmod +x sysmon.sh
```
```bash
./sysmon.sh
```

To control **other users' or system processes** (for example to kill a process owned by root), run it as administrator:
```bash
sudo bash sysmon.sh
```

---

## 7. Keys

| Key | Action |
|---|---|
| ↑ / ↓ | Move up and down in a menu |
| Enter | Select or press the highlighted button |
| Tab | Move between the list and the buttons |
| Esc | Go back or cancel |
| PgUp / PgDn | Scroll long text |

The **mouse does not work** in whiptail boxes, so use the keyboard. Typing a number does **not** jump to that menu item. Use the arrow keys.

**Don't press keys while a progress bar is filling.** The program throws those key presses away, so they won't affect the next box.

---

## 8. Workflow: how the program works

### 8.1 Start-up

```
bash sysmon.sh
     │
     ▼
Start-up checks ──► Is it Linux? Is whiptail installed? Are ps/top/free/df/pgrep/renice there?
     │              Is it running directly in a terminal (no redirection)?
     │              Is the terminal big enough (70 x 20)?
     │              (if any check fails: print what is wrong, then exit)
     ▼
Create a temporary file, set the exit trap, remember the protected PIDs
(PID 1, this program, and all its parent processes: the shell and terminal that started it)
Also protected by name or type: systemd*, dbus-daemon/dbus-broker, desktop/display
processes (Xorg, Xwayland, gnome-shell, gdm, ...) and kernel threads
     │
     ▼
MAIN MENU LOOP
```

### 8.2 Main menu loop

```
┌──────────────────────────────────────────────────────────────┐
│ 1. Measure usage:  CPU (/proc/stat)  RAM (/proc/meminfo)     │
│                    DISK (df /)                               │
│ 2. If any usage ≥ 90%  ──► RED ALERT box                     │
│       "Biggest CPU/RAM user: <name> (PID x) ...              │
│        Do you want to manage this process now?"              │
│       ──Manage it──► Manage-process screen, then step 1      │
│       ──Ignore─────► step 3                                  │
│    (only DISK ≥ 90%: a red warning with just an OK button)   │
│    (shown once; it appears again after usage drops below 90% │
│     or when you start "Full CPU load" again)                 │
│ 3. Draw the menu with % bars at the top                      │
│ 4. Wait for the user to choose an option                     │
│ 5. Run that option's screen (a function in the script)       │
│ 6. Go back to step 1  (so the % values refresh)              │
└──────────────────────────────────────────────────────────────┘
        │ Exit / Esc
        ▼
Confirm ──► delete temp file ──► stop any test processes ──► goodbye
```

### 8.3 How monitoring and process management are linked

```
 MONITORING (find the problem)            PROCESS MANAGEMENT (fix it)
 ─────────────────────────────            ──────────────────────────
 Main menu % bars / red alert  ─────┐
 6  Top 5 heavy processes      ─────┼──►  8  Manage a process
 7  Search for a process       ─────┤         1 Pause        kill -STOP
 11 Start test process         ─────┘         2 Resume       kill -CONT
                                              3 Terminate    kill -TERM
                                              4 Force kill   kill -KILL
                                              5 Change priority  renice
                                              6 Refresh status
```
Each of these opens the Manage screen with the PID already filled in:
- choosing a process in option 6 or 7 and pressing **Manage** (or **Yes** after a PID search)
- answering **Yes** after starting a CPU-heavy or sleeping test process in option 11
- pressing **Manage it** in the red alert

### 8.4 Manage-process flow (option 8)

```
Enter PID ──► check: is it empty? a number? does the process exist?
                │ (show an error box if not)
                ▼
Has it ended, or is it a ZOMBIE? ──► explain (a zombie can't be killed;
                │                   kill its PARENT instead) and go back
                ▼
Show: name, user, status (with its meaning), CPU%, RAM%, nice value
                │
                ▼
Choose an action ──► Pause / Terminate / Force kill / Change priority:
                          │   is the process protected? (PID 1, systemd, dbus, desktop
                          │   processes, kernel threads, this program, its parent shells)
                          │ yes → "Not Allowed" box
                          ▼ no
                     "Are you sure?" (Yes/No; Force kill starts on No)
                     (Change priority asks for a nice value instead; Resume asks nothing)
                          ▼
                     send the signal ──► permission error? → explain + suggest sudo
                          ▼
                     check and show the new status (e.g. R → T after Pause)
                          ▼
                     back to the Manage screen (status refreshed);
                     if the process has ended: back to the screen you came from
```

---

## 9. Menu options and the UNIX commands behind them

| # | Option | What you see | Commands / sources used |
|---|---|---|---|
| 1 | Show running processes | All processes sorted by CPU, with PID, PPID, user, CPU%, MEM%, status, run time | `ps -eo ... --sort=-%cpu` |
| 2 | CPU usage | Animated % bar, CPU model, cores, load average, `top` summary, top 5 CPU users | `/proc/stat`, `nproc`, `/proc/loadavg`, `top -bn1`, `ps` |
| 3 | RAM usage | % bar, total, used and available RAM, swap, `free -h`, top 5 RAM users | `/proc/meminfo`, `free -h`, `ps --sort=-%mem` |
| 4 | Disk usage | % bar for `/`, every mounted filesystem, marks HIGH ones | `df -P /`, `df -h` |
| 5 | Live CPU meter | A bar that updates every second for 10 seconds | `/proc/stat` sampled each second |
| 6 | Top 5 heavy processes | Top 5 by CPU plus top 5 by RAM. Pick one to manage it. | `ps --sort=-%cpu`, `ps --sort=-%mem` |
| 7 | Search for a process | By name (case-insensitive; Linux keeps only the first 15 characters of a name) or by PID. Pick one to manage it. | `pgrep -i`, `ps -p` |
| 8 | Manage a process | Pause, resume, terminate, force kill, change priority | `kill -STOP/-CONT/-TERM/-KILL`, `renice` |
| 9 | Process status | Status of one PID with its meaning, count of processes in each state, zombie list, letter legend | `ps -o stat`, `uniq -c` |
| 10 | Process tree | Which process started which | `pstree -p` (or `ps --forest`) |
| 11 | Start test process | Safe processes for the demo: CPU-heavy, sleeping, zombie, full CPU load | `yes > /dev/null &`, `sleep 600 &` |
| 12 | Jobs demo | Live terminal demo of job control | `set -m`, `jobs`, `kill -STOP %1`, `bg`, `fg` |
| 13 | Export report | Saves a full snapshot to `sysmon_report.txt` and shows it | all of the above |
| 14 | Help | Keys, options, quick demo | |
| 0 | Exit | Confirms, then stops test processes and exits | `trap ... EXIT` |

**Colours:** the animated progress bars in options 2, 3 and 4 are **green** below 70%, **yellow** from 70% to 89%, and **red** at 90% or more. The Live CPU meter (option 5) bar is always blue. The main-menu and report bars are text bars (`[####----]`), and a value at 90% or more is marked `<< HIGH!`. Error and alert boxes are red.

**CPU% of a single process** (lists, Manage screen) comes from `ps`. It is the **average since that process started**, so after you pause a busy process it falls only slowly. The main-menu CPU %, the Live CPU meter and the red alert's "biggest CPU user" show CPU usage **right now**.

---

## 10. Demo script for the viva (about 5 minutes)

Follow these steps in order. Each step shows one concept.

- **Back** means press **Esc**, or press Tab until the **Back** button is highlighted (the first Tab goes to **Select**/**Manage**) and then press Enter.
- **Yes** on a box that starts on **No** (Force kill, Full CPU load): press Tab to move to **Yes**, then Enter.

| Step | Do this | Point out |
|---|---|---|
| 1 | Run `bash sysmon.sh` | The main menu shows CPU, RAM and DISK as % bars. |
| 2 | **2 CPU usage** | Animated bar, cores, load average, `top` output. |
| 3 | **3 RAM usage**, then **4 Disk usage** | Total, used and free values. `df` shows all drives. |
| 4 | **11** → **1 CPU-heavy process** → **No** → **Back** to the main menu | A safe test process (`yes`) is now running. Note its PID. |
| 5 | **5 Live CPU meter** | The CPU bar is higher because of the test process. |
| 6 | **6 Top 5 heavy processes** | `yes` is at the top with about 100% CPU. Select it → **Manage**. |
| 7 | **1 Pause** → Yes | Status changes **R → T** (stopped). The CPU% on this screen is an average since the process started, so it falls only slowly. The live CPU % drops at once (see the main menu or option 5). |
| 8 | **2 Resume** | Status goes back to **R**. |
| 9 | **5 Change priority** → the box already shows `10`, so just press Enter (to type another value, first delete the old one with Backspace) → OK | The nice value changes to 10 (lower priority). |
| 10 | **4 Force kill** → Tab to **Yes** → Enter → OK | The process is gone. You are back on the Top 5 / main menu. |
| 11 | **11** → **3 Zombie process demo** → OK → **Back**, then **9** → **3 List zombie processes** → OK → **Back** to the main menu | A **Z** process and its parent. Explain zombies. (If you try to manage the zombie, the program explains that you must kill its parent.) |
| 12 | **11** → **4 Full CPU load** → Tab to **Yes** → Enter → OK → **Back** to the main menu → in the red alert press **Ignore** | A **red alert** names the process using the most CPU right now. (**Manage it** would open its Manage screen; then **Back**.) After **Ignore**, the main menu shows CPU **HIGH**. |
| 13 | **11** → **5 Stop ALL test processes** → Yes → OK → **Back** | Cleans up. |
| 14 | **12 Jobs demo** | `jobs`, `kill -STOP %1`, `bg`, `fg` running live. |
| 15 | **10 Process tree** | Find this program: it is shown as `bash(PID)`, with its PID printed at the top of the screen. Above it is the shell you started it from. |
| 16 | **13 Export report to file** → OK | Shows the saved report file. |
| 17 | **8 Manage a process** → enter `1` → **4 Force kill** → OK → **Back** to the main menu | **Not Allowed**: PID 1 is protected (the box appears at once, with no Yes/No question). Shows the safety checks. |
| 18 | **0 Exit** | Confirms and cleans up. |

---

## 11. Things examiners may ask (short answers)

- **Why not use `fg`/`bg` from the main menu?**
  `jobs`, `bg` and `fg` only work on jobs started by the *same shell*. The script runs in its own shell, so it cannot see jobs from your terminal. Option 12 starts its own jobs with job control on (`set -m`) to show them working. For any other process the program uses signals by PID (`kill -STOP` / `kill -CONT`), which work from anywhere.
- **SIGTERM vs SIGKILL?**
  SIGTERM (15) politely asks the process to close; it can clean up or ignore it. SIGKILL (9) is handled by the kernel, so the process cannot ignore it and is ended immediately.
- **How is CPU % calculated?**
  The program reads `/proc/stat` twice, a short time apart. CPU % = (busy time ÷ total time) between the two readings × 100.
- **How is RAM % calculated?**
  From `/proc/meminfo`: (MemTotal − MemAvailable) ÷ MemTotal × 100.
- **What is a zombie?**
  A process that has finished, but whose parent has not yet read its exit status with `wait()`. It uses no CPU or RAM, only a slot in the process table. Killing its parent lets `init` adopt it and remove it.
- **What is a nice value?**
  A number from −20 (highest priority) to 19 (lowest priority). Normal users can only make it bigger; only root can lower it.

---

## 12. Troubleshooting

| Problem | Fix |
|---|---|
| `$'\r': command not found` | Windows line endings. Run `sed -i 's/\r$//' sysmon.sh` |
| `ERROR: 'whiptail' is not installed` | `sudo apt update && sudo apt install -y whiptail` |
| `Your terminal window is too small` | Make the window bigger (at least 70 × 20) or maximise it |
| `Permission Denied` when killing a process | It belongs to another user or to root. Run `sudo bash sysmon.sh` |
| `renice failed` | Normal users can only lower the priority (bigger number) of **their own** processes. To raise priority, or to change another user's process, use sudo. |
| `Could not write the report to: ...` | Neither the program's folder nor your home folder could be written. An old report made with sudo is normally removed automatically; if not, run the `sudo rm ...` command shown in the box. |
| `ERROR: please run this program directly in a terminal, without redirecting its input or output` | You started it with a redirection or through a pipe (for example `2>/dev/null`, `> file`, or piping it into `tee`). Run it plainly: `bash sysmon.sh` |
| Red alert does not appear again | It is shown once per high-usage event. It appears again after usage drops below 90%, or when you start **Full CPU load** again. |
| Boxes look broken or the text is cut off | Maximise the terminal window and choose the option again |
| `bash: sysmon.sh: No such file or directory` | You are in the wrong folder. Run `cd /mnt/d/unix` first. |
| `Permission denied` when running `./sysmon.sh` | Run `chmod +x sysmon.sh`, or use `bash sysmon.sh` |
| `Please run this program with bash` (you ran `sh sysmon.sh`) | Use `bash sysmon.sh`. The program needs bash, not sh. |
| Process tree looks plain | Install `psmisc` for `pstree`: `sudo apt install -y psmisc` |
| Few processes shown on WSL | Normal. WSL runs only a few Linux processes. Start test processes (option 11) for the demo. |

---

## 13. Code structure (inside `sysmon.sh`)

| Section | Contents | Main functions |
|---|---|---|
| 1. Settings | Title, 90% warning limit, report file name, colour themes | |
| 2. Helpers | Message, error, yes/no, input and menu boxes; % bars; PID checks; protected-PID check | `msg`, `err`, `ask_yes_no`, `input_box`, `menu_box`, `make_bar`, `ask_pid`, `is_protected` |
| 3. Monitoring | CPU, RAM and disk %, disk table, uptime, process-state meanings, process details | `cpu_usage`, `ram_usage`, `disk_usage`, `disk_table`, `state_meaning`, `process_details` |
| 4. Process control | Send signals with error handling; pause, resume, terminate, kill, renice; zombie/ended check; manage screen | `send_signal`, `do_pause`, `do_resume`, `do_terminate`, `do_kill`, `do_renice`, `explain_if_gone`, `manage_process` |
| 5. Screens | One function per menu option, plus the high-usage alert | `screen_processes` … `screen_help`, `check_alerts` |
| 6. Main | Start-up checks, exit clean-up, main menu loop | `startup_checks`, `on_exit`, `main_menu` |

---

## 14. Safety features

- **Input checks:** empty input, letters instead of numbers, spaces inside a number, leading zeros, PIDs that don't exist, and names with special characters are all rejected with a clear message.
- **Confirmation** before pausing, terminating or killing a process, and before stopping all test processes. Force kill defaults to **No**.
- **Protected processes:** these can never be paused, terminated, killed or reniced. Pausing the desktop would freeze the whole screen.
  - PID 1 (init/systemd) and every `systemd…` process (for example systemd-journald)
  - the message bus (`dbus-daemon`, `dbus-broker`)
  - kernel threads
  - desktop/display processes (Xorg, Xwayland, gnome-shell, gnome-session, gdm, lightdm, sddm, kwin, plasmashell)
  - this program and all its parent processes (the shell and terminal that started it)
- **Results are checked:** after Pause the program checks that the status really became **T**, and after Terminate or Force kill it checks that the process really ended.
- **Zombies are explained:** a zombie can't be killed, so the program tells you to kill its parent instead of failing silently.
- **Permission errors** are explained, with a hint to use `sudo`.
- **Paused + SIGTERM:** if you terminate a paused process, the program also sends SIGCONT so the process can act on SIGTERM.
- **Clean exit:** on Exit, Ctrl+C or terminal close, all test processes are stopped and the temporary file is deleted.

---

## 15. Limitations and future scope

**Limitations**
- Linux only (uses `/proc` and GNU `ps`/`df` options).
- Keyboard only (no mouse in whiptail).
- Values refresh when you return to the main menu. Only the Live CPU meter updates continuously.
- `%CPU` in `ps` (process lists, Manage screen) is the average over the process's whole lifetime. The main CPU % from `/proc/stat` is "right now".
- The Live CPU meter's colour cannot change while it runs (a whiptail limit), so it is always blue.

**Future scope**
- Automatic logging every few minutes with `cron`, plus usage graphs from the log.
- Email or desktop notification when usage stays high.
- Per-user resource summary.
- Network usage monitoring (`/proc/net/dev`).
- Monitoring remote machines over SSH.
