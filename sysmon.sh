#!/usr/bin/env bash
# =====================================================================
#   UNIX-BASED SYSTEM MONITORING AND PROCESS MANAGEMENT SYSTEM
# ---------------------------------------------------------------------
#   File     : sysmon.sh
#   Language : Bash shell script
#   UI       : whiptail (text-based menu boxes)
#   Run      : bash sysmon.sh
#   Needs    : Linux (e.g. Ubuntu on WSL), bash, whiptail, procps
#
#   Sections in this file
#     1. Settings
#     2. Helper functions      (boxes, bars, input checks)
#     3. Monitoring functions  (CPU, RAM, disk, processes)
#     4. Process control       (pause, resume, stop, kill, renice)
#     5. Screens               (one function per menu option)
#     6. Start-up checks and main menu loop
# =====================================================================

# --- Must be run with bash (not sh / dash) ---------------------------
if [ -z "${BASH_VERSION:-}" ]; then
    echo "Please run this program with bash:   bash sysmon.sh"
    exit 1
fi


# =====================================================================
# 1. SETTINGS
# =====================================================================
APP_TITLE="UNIX System Monitor and Process Manager"
WARN_LIMIT=90                       # usage % at or above this = HIGH
MID_LIMIT=70                        # usage % at or above this = yellow bar
REPORT_NAME="sysmon_report.txt"     # file created by "Export report"
SCRIPT_PID=$$                       # PID of this program
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP_FILE=""                         # temporary file for text screens
DEMO_PIDS=()                        # test processes started by this program
PROTECTED_PIDS=" "                  # PIDs that must never be paused/killed
LAST_ALERT=""                       # which resources were HIGH last time
LAST_CHOICE="1"                     # last selected main-menu item
STOPPED_COUNT=0                     # test processes stopped on exit
ANSWER=""                           # result of input_box
PID_ANSWER=""                       # result of ask_pid / pick_process
CHOICE=""                           # result of menu_box
H=20; W=76; LIST_H=8                # box sizes (recalculated on every screen)

# Colour themes for whiptail (NEWT_COLORS variable)
ERROR_THEME='window=white,red border=white,red title=yellow,red textbox=white,red button=black,lightgray actbutton=white,blue compactbutton=white,red'
ALERT_THEME="root=white,red $ERROR_THEME"


# =====================================================================
# 2. HELPER FUNCTIONS
# =====================================================================

# Work out box sizes from the current terminal size
calc_size() {
    local lines="" cols=""
    read -r lines cols < <(stty size < /dev/tty 2>/dev/null)
    [[ $lines =~ ^[0-9]+$ ]] || lines=$(tput lines 2>/dev/null)
    [[ $cols  =~ ^[0-9]+$ ]] || cols=$(tput cols 2>/dev/null)
    [[ $lines =~ ^[0-9]+$ ]] || lines=24
    [[ $cols  =~ ^[0-9]+$ ]] || cols=80
    H=$(( lines - 3 ));  (( H > 34 ))  && H=34;  (( H < 16 )) && H=16
    W=$(( cols - 6 ));   (( W > 100 )) && W=100; (( W < 64 )) && W=64
    LIST_H=$(( H - 13 )); (( LIST_H < 3 )) && LIST_H=3
}

# Height needed for a box that shows text $1 (+ $2 extra lines, default 7)
box_h() {
    local n
    n=$(printf '%s\n' "$1" | awk -v w=$(( W - 4 )) '
        { len = length($0); n += (len > w) ? int((len - 1) / w) + 1 : 1 }
        END { print n + 0 }')
    n=$(( n + ${2:-7} ))
    (( n > H )) && n=$H
    echo "$n"
}

# Simple message box
msg() {
    whiptail --title "$1" --scrolltext --msgbox "$2" "$(box_h "$2")" "$W"
}

# Red error / warning box
err() {
    NEWT_COLORS=$ERROR_THEME whiptail --title "$1" --scrolltext --msgbox "$2" "$(box_h "$2")" "$W"
}

# Yes/No question. Returns 0 for Yes. Pass "no" as $3 to make No the default.
ask_yes_no() {
    if [[ ${3:-} == no ]]; then
        whiptail --title "$1" --defaultno --yesno "$2" "$(box_h "$2")" "$W"
    else
        whiptail --title "$1" --yesno "$2" "$(box_h "$2")" "$W"
    fi
}

# Text input box. The typed text is stored in ANSWER.
input_box() {
    ANSWER=$(whiptail --title "$1" --inputbox "$2" "$(box_h "$2" 9)" "$W" "${3:-}" 3>&1 1>&2 2>&3)
}

# Menu box:  menu_box TITLE TEXT TAG ITEM [TAG ITEM ...]   -> chosen tag in CHOICE
menu_box() {
    local title=$1 text=$2 th lh h
    shift 2
    th=$(box_h "$text" 0)
    lh=$(( $# / 2 ))
    h=$(( th + lh + 8 ))
    if (( h > H )); then
        lh=$(( H - th - 8 )); (( lh < 3 )) && lh=3
        h=$H
    fi
    CHOICE=$(whiptail --title "$title" --ok-button "Select" --cancel-button "Back" \
             --menu "$text" "$h" "$W" "$lh" "$@" 3>&1 1>&2 2>&3)
}

# Show the contents of TMP_FILE in a scrollable box
show_file() {
    whiptail --title "$1" --scrolltext --textbox "$TMP_FILE" "$H" "$W"
}

# Text bar:  make_bar 62 20   ->   [############--------]  62%
make_bar() {
    local pct=${1:-0} width=${2:-20} filled full empty
    [[ $pct =~ ^[0-9]+$ ]] || pct=0
    (( pct > 100 )) && pct=100
    filled=$(( pct * width / 100 ))
    printf -v full  '%*s' "$filled" '';               full=${full// /#}
    printf -v empty '%*s' $(( width - filled )) '';   empty=${empty// /-}
    printf '[%s%s] %3d%%' "$full" "$empty" "$pct"
}

# Prints "  << HIGH!" when a percentage is at or above WARN_LIMIT
high_tag() {
    if (( ${1:-0} >= WARN_LIMIT )); then printf '  << HIGH!'; fi
}

# Colour of a progress bar: green (normal), yellow (medium), red (high)
gauge_theme() {
    if   (( $1 >= WARN_LIMIT )); then echo 'fullscale=white,red emptyscale=black,lightgray'
    elif (( $1 >= MID_LIMIT ));  then echo 'fullscale=black,yellow emptyscale=black,lightgray'
    else                              echo 'fullscale=white,green emptyscale=black,lightgray'
    fi
}

# Animated progress bar that fills up to a percentage
show_gauge() {   # $1 = title, $2 = text, $3 = percent
    local title=$1 text=$2 pct=$3 i
    {
        for (( i = 0; i < pct; i += 5 )); do echo "$i"; sleep 0.04; done
        echo "$pct"
        sleep 1.5
    } | NEWT_COLORS=$(gauge_theme "$pct") whiptail --title "$title" --gauge "$text" 8 "$W" 0
    flush_keys
}

# Throw away keys pressed while no box was waiting for input
# (otherwise a stray Enter would close the next box by itself)
flush_keys() {
    while read -r -s -t 0.01 -n 1 _ < /dev/tty; do :; done 2>/dev/null
}

# Keep only digits (used for percentages); anything else becomes 0
to_int() {
    if [[ $1 =~ ^[0-9]+$ ]]; then echo "$1"; else echo 0; fi
}

# Is the text a valid PID (1 to 7 digits, no leading zero)?
is_pid_format() {
    [[ $1 =~ ^[1-9][0-9]{0,6}$ ]]
}

# Does a process with this PID exist?
process_exists() {
    ps -p "$1" -o pid= > /dev/null 2>&1
}

# Status letters of a process, e.g. "S", "R+", "T", "Z"
proc_state() {
    ps -o stat= -p "$1" 2>/dev/null | tr -d ' '
}

# Name of a process
proc_name() {
    local name=""
    read -r name < <(ps -o comm= -p "$1" 2>/dev/null)
    echo "$name"
}

# Process has ended (does not exist, or is a zombie = already finished)
process_gone() {
    ! process_exists "$1" || [[ $(proc_state "$1") == Z* ]]
}

# Is this process a direct child of this program?
is_our_child() {
    [[ $(ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ') == "$SCRIPT_PID" ]]
}

# Ask the user for a PID and check it. The PID is stored in PID_ANSWER.
ask_pid() {   # $1 = title, $2 = question
    local title=$1 pid
    input_box "$title" "$2" || return 1
    read -r pid <<< "$ANSWER"        # remove spaces at the start/end only
    if [[ -z $pid ]]; then
        err "$title" "You did not type anything. Please enter a PID (a number such as 1234)."
        return 1
    fi
    if ! is_pid_format "$pid"; then
        err "$title" "'$pid' is not a valid PID.
A PID is a whole number such as 1234 (no letters, spaces or leading zeros)."
        return 1
    fi
    if ! process_exists "$pid"; then
        err "$title" "No process with PID $pid exists.
Use 'Show running processes' or 'Search for a process' to find the right PID."
        return 1
    fi
    PID_ANSWER=$pid
}

# Collect this program and all its parent processes (they must never be killed)
find_protected_pids() {
    local p=$SCRIPT_PID next
    PROTECTED_PIDS=" 1 "
    while [[ -n $p ]] && (( p > 1 )); do
        PROTECTED_PIDS+="$p "
        next=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
        [[ $next == "$p" ]] && break
        p=$next
    done
}

# Returns 0 (true) if the process must NOT be paused / terminated / killed
is_protected() {
    local name
    # this program, the terminal that started it, and PID 1
    [[ $PROTECTED_PIDS == *" $1 "* ]] && return 0
    # core system and desktop (screen) processes
    name=$(proc_name "$1")
    case $name in
        init|systemd*|Xorg|Xwayland|gnome-shell|gnome-session*|gdm*|lightdm|sddm|kwin_*|plasmashell|dbus-daemon|dbus-broker*)
            return 0 ;;
    esac
    # kernel threads (they use no user memory, VSZ = 0) ignore signals
    if [[ $(ps -o vsz= -p "$1" 2>/dev/null | tr -d ' ') == 0 && $(proc_state "$1") != Z* ]]; then
        return 0
    fi
    return 1
}

# Show a message and return 1 if the process is protected
guard_protected() {   # $1 = PID, $2 = name
    if is_protected "$1"; then
        err "Not Allowed" "Process $1 ($2) is protected.

It is a core system process (like init/systemd, PID 1), a kernel thread,
part of the desktop/display (like gnome-shell or Xorg), this monitoring
program itself, or the terminal that started it.
Stopping it could crash the system, freeze the screen or close your terminal."
        return 1
    fi
    return 0
}


# =====================================================================
# 3. MONITORING FUNCTIONS
# =====================================================================

# CPU usage in % measured over a short time (default 0.5 s), using /proc/stat
cpu_usage() {
    local interval=${1:-0.5}
    local u1 n1 s1 i1 w1 q1 sq1 st1 u2 n2 s2 i2 w2 q2 sq2 st2 total idle
    read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
    sleep "$interval"
    read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
    total=$(( (u2 + n2 + s2 + i2 + w2 + q2 + sq2 + st2) - (u1 + n1 + s1 + i1 + w1 + q1 + sq1 + st1) ))
    idle=$(( (i2 + w2) - (i1 + w1) ))
    if (( total <= 0 )); then
        echo 0
    else
        echo $(( (100 * (total - idle) + total / 2) / total ))
    fi
}

# RAM usage in % (used = total - available), using /proc/meminfo
ram_usage() {
    awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
         END { if (t > 0) printf "%d\n", (t - a) * 100 / t + 0.5; else print 0 }' /proc/meminfo
}

# Disk usage in % of the root filesystem "/"
# (Use% is found as the first field that looks like "NN%", because a
#  filesystem name can contain spaces, e.g. "C:\Program Files\Docker")
disk_usage() {
    df -P / 2>/dev/null | awk 'NR == 2 {
        for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+%$/) { gsub("%", "", $i); print $i + 0; exit }
        print 0 }'
}

# Table of real (mounted) filesystems, marking the ones that are almost full
disk_table() {
    local out
    out=$(df -hP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null)
    [[ -n $out ]] || out=$(df -hP 2>/dev/null)
    echo "$out" | awk -v lim="$WARN_LIMIT" '
        NR == 1 { print; next }
        { u = 0
          for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+%$/) { u = $i; break }
          gsub("%", "", u)
          if (u + 0 >= lim) print $0 "   << HIGH!"; else print }'
}

# Time since the computer started, e.g. "0d 3h 25m"
uptime_text() {
    local s
    read -r s _ < /proc/uptime
    s=${s%.*}
    printf '%dd %dh %dm' $(( s / 86400 )) $(( s % 86400 / 3600 )) $(( s % 3600 / 60 ))
}

# Name of the operating system, e.g. "Ubuntu 22.04.4 LTS"
os_name() {
    ( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}" ) || uname -s
}

# Meaning of the FIRST status letter of a process
state_meaning() {
    case "${1:0:1}" in
        R) echo "Running (using the CPU or ready to run)" ;;
        S) echo "Sleeping (waiting for something, e.g. input or a timer)" ;;
        D) echo "Uninterruptible sleep (usually waiting for the disk)" ;;
        T) echo "Stopped (paused by a signal such as SIGSTOP or Ctrl+Z)" ;;
        t) echo "Stopped by a debugger (tracing)" ;;
        Z) echo "Zombie (finished, but its parent has not collected it yet)" ;;
        I) echo "Idle kernel thread" ;;
        X) echo "Dead (should never be seen)" ;;
        *) echo "Unknown" ;;
    esac
}

# Short name of a status letter
state_name() {
    case "$1" in
        R) echo "Running" ;;
        S) echo "Sleeping" ;;
        D) echo "Disk sleep (uninterruptible)" ;;
        T) echo "Stopped (paused)" ;;
        t) echo "Stopped by debugger" ;;
        Z) echo "Zombie" ;;
        I) echo "Idle (kernel thread)" ;;
        X) echo "Dead" ;;
        *) echo "Other" ;;
    esac
}

# Meaning of the extra letters after the first one (e.g. "Ss+" -> s and +)
state_flags() {
    local s=${1:1} out="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c=${s:i:1}
        case $c in
            '<') out+="< = high priority, " ;;
            N)   out+="N = low priority, " ;;
            s)   out+="s = session leader, " ;;
            l)   out+="l = multi-threaded, " ;;
            +)   out+="+ = in the foreground group, " ;;
            L)   out+="L = has memory pages locked, " ;;
        esac
    done
    echo "${out%, }"
}

# Count of processes in each state
state_counts_text() {
    local n s
    ps -eo stat= | cut -c1 | sort | uniq -c | while read -r n s; do
        printf '  %-3s %-30s %6d\n' "$s" "$(state_name "$s")" "$n"
    done
    printf '  %-34s %6d\n' "Total processes" "$(ps -e --no-headers | wc -l)"
}

# Full description of one process
process_details() {
    local pid=$1 stat="" ppid="" user="" cpu="" mem="" ni="" etime="" name="" cmd flags
    read -r stat ppid user cpu mem ni etime name < <(ps -o stat=,ppid=,user:32=,%cpu=,%mem=,ni=,etime=,comm= -p "$pid" 2>/dev/null)
    cmd=$(ps -o args= -p "$pid" 2>/dev/null)
    flags=$(state_flags "$stat")
    echo "PROCESS DETAILS   (command: ps -o stat,ppid,user,%cpu,%mem,ni,etime,comm -p $pid)"
    echo "======================================================================"
    echo "PID            : $pid"
    echo "Name           : $name"
    echo "Full command   : ${cmd:0:200}"
    echo "Status         : $stat"
    echo "   Meaning     : $(state_meaning "$stat")"
    [[ -n $flags ]] && echo "   Extra flags : $flags"
    echo "Parent PID     : $ppid  ($(proc_name "$ppid"))"
    echo "Owner (user)   : $user"
    echo "CPU used       : $cpu %   (average since the process started)"
    echo "RAM used       : $mem %"
    echo "Nice value     : $ni   (-20 = highest priority ... 19 = lowest)"
    echo "Running for    : $etime   ([days-]hours:minutes:seconds)"
}

# Header line for process pick lists (same layout as the list rows)
list_header() {
    printf '%7s %6s %6s  %-5s %s' "PID" "CPU%" "MEM%" "STAT" "NAME"
}

# Show processes from a file (lines: PID CPU MEM STAT NAME) as a menu.
# The chosen PID is stored in PID_ANSWER.  Returns 2 if the list is empty.
pick_process() {   # $1 = title, $2 = text above the list, $3 = file
    local title=$1 text=$2 file=$3 pid cpu mem stat name th lh h
    # The column header is the first row of the list, so it lines up with the rows
    local -a items=("hdr" "$(list_header)")
    while read -r pid cpu mem stat name; do
        [[ -z $pid ]] && continue
        items+=("$pid" "$(printf '%7s %6s %6s  %-5s %s' "$pid" "$cpu" "$mem" "$stat" "$name")")
    done < "$file"
    (( ${#items[@]} == 2 )) && return 2
    th=$(box_h "$text" 0)
    lh=$(( ${#items[@]} / 2 ))
    h=$(( th + lh + 8 ))
    if (( h > H )); then
        lh=$(( H - th - 8 )); (( lh < 3 )) && lh=3
        h=$H
    fi
    while true; do
        PID_ANSWER=$(whiptail --title "$title" --notags --default-item "${items[2]}" \
                     --ok-button "Manage" --cancel-button "Back" \
                     --menu "$text" "$h" "$W" "$lh" "${items[@]}" 3>&1 1>&2 2>&3) || return 1
        [[ $PID_ANSWER != hdr ]] && return 0     # header row chosen: just show the list again
    done
}


# =====================================================================
# 4. PROCESS CONTROL
# =====================================================================

# Send a signal to a process and show a clear message if it fails
send_signal() {   # $1 = PID, $2 = signal name (STOP, CONT, TERM, KILL)
    local out
    # LC_ALL=C gives English error messages, so the check below always works
    if out=$(export LC_ALL=C; kill -s "$2" "$1" 2>&1); then
        return 0
    fi
    if [[ $out == *"not permitted"* ]]; then
        err "Permission Denied" "You are not allowed to send SIG$2 to process $1.
It belongs to another user or to the system.

Tip: run the program as administrator:   sudo bash sysmon.sh"
    else
        err "Error" "Could not send SIG$2 to process $1:
$out"
    fi
    return 1
}

# Remove finished test processes from the list and clean up their zombies
reap_demo() {
    local pid
    local -a keep=()
    for pid in "${DEMO_PIDS[@]}"; do
        if is_our_child "$pid"; then
            if [[ $(proc_state "$pid") == Z* ]]; then
                wait "$pid" 2>/dev/null
            else
                keep+=("$pid")
            fi
        fi
    done
    DEMO_PIDS=("${keep[@]}")
}

# Wait up to $2 tenths of a second for a process to end
wait_until_gone() {   # $1 = PID, $2 = tenths of a second
    local i
    for (( i = 0; i < $2; i++ )); do
        reap_demo
        process_gone "$1" && return 0
        sleep 0.1
    done
    reap_demo
    process_gone "$1"
}

do_pause() {   # $1 = PID, $2 = name
    local pid=$1 name=$2 st
    guard_protected "$pid" "$name" || return
    if [[ $(proc_state "$pid") == T* ]]; then
        msg "Pause" "Process $pid ($name) is already paused (status T)."
        return
    fi
    ask_yes_no "Pause Process" "Pause process $pid ($name)?

It will stop running (and stop using the CPU) until you resume it.
Command:  kill -STOP $pid" || return
    send_signal "$pid" STOP || return
    sleep 0.3
    st=$(proc_state "$pid")
    if [[ $st != T* ]]; then
        err "Pause" "SIGSTOP was sent, but process $pid ($name) did not pause.
Current status: ${st:-ended} = $(state_meaning "$st")
(A process waiting for the disk, status D, pauses only when the disk answers.)"
        return
    fi
    msg "Pause" "Process $pid ($name) is now PAUSED.

New status : $st = $(state_meaning "$st")

Choose 'Resume' to let it continue."
}

do_resume() {   # $1 = PID, $2 = name
    local pid=$1 name=$2 st
    if [[ $(proc_state "$pid") != T* ]]; then
        msg "Resume" "Process $pid ($name) is not paused, so there is nothing to resume.
Current status: $(proc_state "$pid")"
        return
    fi
    send_signal "$pid" CONT || return
    sleep 0.3
    st=$(proc_state "$pid")
    msg "Resume" "Process $pid ($name) is RUNNING again.
Command used: kill -CONT $pid

New status : $st = $(state_meaning "$st")"
}

do_terminate() {   # $1 = PID, $2 = name.  Returns 10 if the process ended.
    local pid=$1 name=$2 was_paused=0 note=""
    guard_protected "$pid" "$name" || return
    ask_yes_no "Terminate Process" "Terminate process $pid ($name)?

This sends SIGTERM, which politely asks the process to close
(it gets a chance to save its work first).
Command:  kill -TERM $pid" || return
    [[ $(proc_state "$pid") == T* ]] && was_paused=1
    send_signal "$pid" TERM || return
    # A paused process cannot react to SIGTERM until it is resumed
    (( was_paused )) && kill -s CONT "$pid" 2>/dev/null
    if wait_until_gone "$pid" 30; then
        msg "Terminate Process" "Process $pid ($name) has ended (terminated by SIGTERM)."
        return 10
    fi
    (( was_paused )) && note="
Note: it was paused, so SIGCONT was also sent - it is RUNNING again now."
    msg "Terminate Process" "Process $pid ($name) is still running after 3 seconds.
It may be ignoring SIGTERM, or it may still be closing.$note
Use 'Force kill' (SIGKILL) to end it immediately."
}

do_kill() {   # $1 = PID, $2 = name.  Returns 10 if the process ended.
    local pid=$1 name=$2
    guard_protected "$pid" "$name" || return
    ask_yes_no "Force Kill" "FORCE KILL process $pid ($name)?

SIGKILL ends the process immediately. It cannot save its work
and it cannot ignore this signal.
Command:  kill -KILL $pid" no || return
    send_signal "$pid" KILL || return
    if wait_until_gone "$pid" 20; then
        msg "Force Kill" "Process $pid ($name) has been killed."
        return 10
    fi
    msg "Force Kill" "Process $pid ($name) has not ended yet (status $(proc_state "$pid")).
It may be waiting for the disk (status D). Check again in a moment."
}

do_renice() {   # $1 = PID, $2 = name
    local pid=$1 name=$2 cur new out
    guard_protected "$pid" "$name" || return
    cur=$(ps -o ni= -p "$pid" 2>/dev/null | tr -d ' ')
    input_box "Change Priority" "Current nice value of process $pid ($name): $cur

Nice values go from -20 (highest priority) to 19 (lowest priority).
Normal users can only LOWER the priority (use a bigger number).
Only the administrator (sudo) can raise it.

Enter the new nice value (-20 to 19):" "10" || return
    read -r new <<< "$ANSWER"        # remove spaces at the start/end only
    if ! [[ $new =~ ^-?(0|[1-9][0-9]?)$ ]] || (( new < -20 || new > 19 )); then
        err "Change Priority" "'$new' is not valid. Enter a whole number from -20 to 19."
        return
    fi
    # LC_ALL=C gives English error messages, so the checks below always work
    if out=$(LC_ALL=C renice -n "$new" -p "$pid" 2>&1); then
        msg "Change Priority" "Done.  Command used:  renice -n $new -p $pid

Process $pid ($name) now has nice value: $(ps -o ni= -p "$pid" 2>/dev/null | tr -d ' ')"
    else
        local why="Normal users cannot raise priority (use a smaller nice value).
Run as administrator for that:   sudo bash sysmon.sh"
        [[ $out == *"not permitted"* ]] && why="Process $pid belongs to another user or to the system.
Only the administrator can change it:   sudo bash sysmon.sh"
        [[ $out == *"No such process"* ]] && why="Process $pid has ended."
        err "Change Priority" "renice failed:
$out

$why"
    fi
}

# Explain why a process can no longer be managed. Returns 0 if it has ended.
explain_if_gone() {   # $1 = PID
    local ppid
    if ! process_exists "$1"; then
        msg "Manage a Process" "Process $1 is not running any more (it has ended)."
        return 0
    fi
    if [[ $(proc_state "$1") == Z* ]]; then
        ppid=$(ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ')
        msg "Manage a Process" "Process $1 is a ZOMBIE (status Z). It has already finished,
so it cannot be paused, terminated or killed.

To remove it, terminate or kill its PARENT:
PID $ppid ($(proc_name "$ppid")). init then adopts the zombie and removes it."
        return 0
    fi
    return 1
}

# Manage one process: pause, resume, terminate, force kill, change priority
manage_process() {   # $1 = PID (optional; asked if empty)
    local pid=${1:-} stat cpu mem ni user name info rc
    if [[ -z $pid ]]; then
        calc_size
        ask_pid "Manage a Process" "Enter the PID of the process you want to manage:

(Find PIDs with 'Show running processes', 'Top 5 heavy processes'
or 'Search for a process'.)" || return
        pid=$PID_ANSWER
    fi
    while true; do
        calc_size
        reap_demo
        explain_if_gone "$pid" && return
        stat=""; cpu=""; mem=""; ni=""; user=""; name=""
        read -r stat cpu mem ni user name < <(ps -o stat=,%cpu=,%mem=,ni=,user:32=,comm= -p "$pid" 2>/dev/null)
        [[ -z $stat ]] && return
        info="PID: $pid     Name: $name     User: $user
Status: $stat = $(state_meaning "$stat")
CPU (average since start): $cpu%     RAM: $mem%     Nice: $ni"
        if is_protected "$pid"; then
            info+="
(PROTECTED: system process or part of this program - viewing only.)"
        fi
        menu_box "Manage Process $pid" "$info" \
            "1" "Pause            (kill -STOP $pid)" \
            "2" "Resume           (kill -CONT $pid)" \
            "3" "Terminate        (kill -TERM $pid)  asks it to close" \
            "4" "Force kill       (kill -KILL $pid)  ends it at once" \
            "5" "Change priority  (renice)" \
            "6" "Refresh status" || return
        rc=0
        case $CHOICE in
            1) do_pause "$pid" "$name" ;;
            2) do_resume "$pid" "$name" ;;
            3) do_terminate "$pid" "$name"; rc=$? ;;
            4) do_kill "$pid" "$name"; rc=$? ;;
            5) do_renice "$pid" "$name" ;;
            6) ;;
        esac
        (( rc == 10 )) && return
    done
}


# =====================================================================
# 5. SCREENS  (one function per menu option)
# =====================================================================

# --- Option 1: show running processes --------------------------------
screen_processes() {
    {
        echo "RUNNING PROCESSES (sorted by CPU usage)      Total: $(ps -e --no-headers | wc -l) processes"
        echo "Command: ps -eo pid,ppid,user,%cpu,%mem,stat,etime,comm --sort=-%cpu"
        echo "STAT: R=Running S=Sleeping D=Disk wait T=Stopped Z=Zombie I=Idle"
        echo "Use the arrow keys / PgUp / PgDn to scroll."
        echo
        ps -eo pid,ppid,user,%cpu,%mem,stat,etime,comm --sort=-%cpu
    } > "$TMP_FILE"
    show_file "Running Processes"
}

# --- Option 2: CPU usage ------------------------------------------------
screen_cpu() {
    local cpu cores model l1 l5 l15
    cpu=$(to_int "$(cpu_usage 1)")
    show_gauge "CPU Usage" "CPU is ${cpu}% busy (measured over 1 second)" "$cpu"
    cores=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
    model=$(awk -F: '/model name/ { sub(/^ +/, "", $2); print $2; exit }' /proc/cpuinfo)
    read -r l1 l5 l15 _ < /proc/loadavg
    {
        echo "CPU USAGE"
        echo "========="
        echo "Usage now     : $(make_bar "$cpu" 30)$(high_tag "$cpu")"
        echo "CPU model     : ${model:-unknown}"
        echo "CPU cores     : $cores"
        echo "Load average  : $l1 (1 min)   $l5 (5 min)   $l15 (15 min)"
        echo "                A load above $cores means processes are waiting for the CPU."
        echo
        echo "--- Summary from: top -bn1 ---"
        top -bn1 2>/dev/null | head -n 5
        echo
        echo "--- Top 5 processes by CPU: ps -eo ... --sort=-%cpu ---"
        ps -eo pid,user,%cpu,%mem,stat,comm --sort=-%cpu | head -n 6
    } > "$TMP_FILE"
    show_file "CPU Usage"
}

# --- Option 3: RAM usage ------------------------------------------------
screen_ram() {
    local ram
    ram=$(to_int "$(ram_usage)")
    show_gauge "RAM Usage" "RAM in use: ${ram}%" "$ram"
    {
        echo "RAM (MEMORY) USAGE"
        echo "=================="
        echo "Usage now : $(make_bar "$ram" 30)$(high_tag "$ram")"
        awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
             /^SwapTotal:/ { st = $2 } /^SwapFree:/ { sf = $2 }
             END {
               printf "Total RAM : %.2f GB\n", t / 1048576
               printf "Used RAM  : %.2f GB\n", (t - a) / 1048576
               printf "Available : %.2f GB\n", a / 1048576
               if (st > 0) printf "Swap used : %.2f GB of %.2f GB\n", (st - sf) / 1048576, st / 1048576
               else        print  "Swap      : none"
             }' /proc/meminfo
        echo
        echo "--- free -h ---"
        free -h
        echo
        echo "--- Top 5 processes by RAM: ps -eo ... --sort=-%mem ---"
        ps -eo pid,user,%cpu,%mem,rss,stat,comm --sort=-%mem | head -n 6
        echo "(RSS = real memory used by the process, in KB)"
    } > "$TMP_FILE"
    show_file "RAM Usage"
}

# --- Option 4: disk usage -----------------------------------------------
screen_disk() {
    local disk
    disk=$(to_int "$(disk_usage)")
    show_gauge "Disk Usage" "Root filesystem (/) is ${disk}% full" "$disk"
    {
        echo "DISK USAGE"
        echo "=========="
        echo "Root filesystem (/) : $(make_bar "$disk" 30)$(high_tag "$disk")"
        echo
        echo "--- All mounted filesystems: df -h ---"
        disk_table
        echo
        echo "Size = total space   Used = space taken   Avail = free space   Use% = how full"
        echo "(On WSL, /mnt/c and /mnt/d are your Windows C: and D: drives.)"
    } > "$TMP_FILE"
    show_file "Disk Usage"
}

# --- Option 5: live CPU meter -------------------------------------------
screen_live_cpu() {
    local secs=10 i p r
    {
        for (( i = 1; i <= secs; i++ )); do
            p=$(cpu_usage 1)
            r=$(ram_usage)
            echo "XXX"
            echo "$p"
            echo "Live CPU usage: ${p}%        RAM: ${r}%"
            echo "Second $i of $secs - the bar moves as the CPU load changes"
            echo "XXX"
        done
        sleep 0.5
    } | NEWT_COLORS='fullscale=white,blue emptyscale=black,lightgray' \
        whiptail --title "Live CPU Meter (10 seconds)" --gauge "Measuring CPU usage...
Please wait" 9 "$W" 0
    flush_keys
}

# --- Option 6: top 5 heavy processes ------------------------------------
screen_top() {
    calc_size
    {
        ps -eo pid=,%cpu=,%mem=,stat=,comm= --sort=-%cpu | awk '$5 != "ps"' | head -n 5
        ps -eo pid=,%cpu=,%mem=,stat=,comm= --sort=-%mem | awk '$5 != "ps"' | head -n 5
    } | awk '!seen[$1]++' > "$TMP_FILE"
    pick_process "Top 5 Heavy Processes" "Top 5 by CPU, then top 5 by RAM (each process shown once).
CPU% is the average since each process started.
Select a process and press Manage to pause, resume or terminate it." "$TMP_FILE" || return
    manage_process "$PID_ANSWER"
}

# --- Option 7: search for a process -------------------------------------
search_by_name() {
    local name pattern pids count rc
    input_box "Search by Name" "Enter the process name (or part of it):

Examples: sleep, bash, yes, python, firefox" || return
    read -r name <<< "$ANSWER"       # remove spaces at the start/end only
    if [[ -z $name ]]; then
        err "Search by Name" "You did not type a name."
        return
    fi
    if ! [[ $name =~ ^[A-Za-z0-9._+-]+$ ]]; then
        err "Search by Name" "Please use only letters, numbers, dot (.), dash (-), plus (+) or underscore (_).
No spaces."
        return
    fi
    name=${name:0:15}    # Linux keeps only the first 15 characters of a process name
    pattern=$(printf '%s' "$name" | sed 's/[.+]/\\&/g')
    pids=$(pgrep -i -- "$pattern" 2>/dev/null | paste -sd, -)
    if [[ -z $pids ]]; then
        msg "Search by Name" "No running process matches '$name'.
(Command used: pgrep -i $name)"
        return
    fi
    ps -o pid=,%cpu=,%mem=,stat=,comm= -p "$pids" --sort=-%cpu 2>/dev/null | head -n 50 > "$TMP_FILE"
    count=$(wc -l < "$TMP_FILE")
    pick_process "Search: $name" "Found $count process(es) matching '$name'   (command: pgrep -i $name)
Select one and press Manage, or press Back." "$TMP_FILE"
    rc=$?
    if (( rc == 2 )); then
        msg "Search by Name" "The matching processes have already ended."
        return
    fi
    (( rc == 0 )) && manage_process "$PID_ANSWER"
}

search_by_pid() {
    ask_pid "Search by PID" "Enter the PID to look up (for example 1234):" || return
    local pid=$PID_ANSWER
    process_details "$pid" > "$TMP_FILE"
    show_file "Process $pid"
    if process_exists "$pid" && ask_yes_no "Search by PID" "Do you want to manage process $pid now?
(pause / resume / terminate / kill / change priority)"; then
        manage_process "$pid"
    fi
}

screen_search() {
    calc_size
    menu_box "Search for a Process" "How do you want to search?" \
        "1" "By name   (example: sleep, bash, firefox)" \
        "2" "By PID    (example: 1234)" || return
    case $CHOICE in
        1) search_by_name ;;
        2) search_by_pid ;;
    esac
}

# --- Option 9: process status -------------------------------------------
status_one() {
    ask_pid "Process Status" "Enter the PID of the process to check:" || return
    process_details "$PID_ANSWER" > "$TMP_FILE"
    show_file "Status of Process $PID_ANSWER"
}

status_counts() {
    {
        echo "NUMBER OF PROCESSES IN EACH STATE"
        echo "Command: ps -eo stat | cut -c1 | sort | uniq -c"
        echo
        state_counts_text
    } > "$TMP_FILE"
    show_file "Process States"
}

status_zombies() {
    local zombies pid ppid stat name
    zombies=$(ps -eo pid=,ppid=,stat=,comm= | awk '$3 ~ /^Z/')
    {
        echo "ZOMBIE PROCESSES   (status Z)"
        echo "Command: ps -eo pid,ppid,stat,comm | awk '\$3 ~ /^Z/'"
        echo
        if [[ -z $zombies ]]; then
            echo "There are no zombie processes right now."
            echo
            echo "Tip: create one with  'Start test process' -> 'Zombie process demo'."
        else
            printf '%7s %7s  %-6s %-16s %s\n' "PID" "PPID" "STAT" "NAME" "PARENT NAME"
            while read -r pid ppid stat name; do
                printf '%7s %7s  %-6s %-16s %s\n' "$pid" "$ppid" "$stat" "$name" "$(proc_name "$ppid")"
            done <<< "$zombies"
            echo
            echo "A zombie has already finished, so it cannot be killed."
            echo "To remove it, stop or kill its PARENT (the PPID column)."
            echo "The zombie is then adopted by init, which cleans it up."
        fi
    } > "$TMP_FILE"
    show_file "Zombie Processes"
}

status_legend() {
    cat > "$TMP_FILE" <<'EOF'
WHAT DO THE STATUS LETTERS MEAN?   (STAT column of ps)

First letter = the main state
  R   Running        using the CPU, or ready and waiting for its turn
  S   Sleeping       waiting for something (keyboard, network, timer)
  D   Disk sleep     waiting for the disk; cannot be interrupted
  T   Stopped        paused by SIGSTOP or Ctrl+Z (resume with SIGCONT)
  t   Traced         stopped by a debugger
  Z   Zombie         finished, but the parent has not collected it
  I   Idle           an idle kernel thread

Extra letters (may follow the first letter)
  <   high priority          N   low priority (nice > 0)
  s   session leader         l   multi-threaded
  +   in the foreground      L   has memory pages locked

Life cycle of a process
  created --> R (ready/running) <--> S or D (waiting)
                 |    ^
       SIGSTOP   v    |  SIGCONT
                 T (stopped)
  R --> process ends --> Z (zombie) --> parent collects it --> gone

Signals used by this program
  SIGSTOP (19)  pause         kill -STOP <pid>
  SIGCONT (18)  resume        kill -CONT <pid>
  SIGTERM (15)  ask to close  kill -TERM <pid>   (can be ignored)
  SIGKILL  (9)  force close   kill -KILL <pid>   (cannot be ignored)
EOF
    show_file "Status Letters"
}

screen_status() {
    while true; do
        calc_size
        menu_box "Process Status" "Every process has a status (state). Choose an option:" \
            "1" "Check the status of one process (by PID)" \
            "2" "Count processes in each state" \
            "3" "List zombie processes" \
            "4" "What do the status letters mean?" || return
        case $CHOICE in
            1) status_one ;;
            2) status_counts ;;
            3) status_zombies ;;
            4) status_legend ;;
        esac
    done
}

# --- Option 10: process tree --------------------------------------------
screen_tree() {
    {
        echo "PROCESS TREE   (shows which process started which)"
        echo "This program is PID $SCRIPT_PID.   Format: name(PID)"
        echo
        if command -v pstree > /dev/null 2>&1; then
            echo "Command: pstree -p"
            echo
            pstree -p 2>/dev/null
        else
            echo "Command: ps -eo pid,ppid,stat,comm --forest"
            echo
            ps -eo pid,ppid,stat,comm --forest
        fi
    } > "$TMP_FILE"
    show_file "Process Tree"
}

# --- Option 11: start test processes (for the demo) ---------------------
demo_list() {   # (call reap_demo first, in the main shell)
    local pid out=""
    for pid in "${DEMO_PIDS[@]}"; do
        out+="$pid $(proc_name "$pid") ($(proc_state "$pid")),  "
    done
    [[ -z $out ]] && out="none"
    echo "${out%,  }"
}

started_msg() {   # $1 = PID, $2 = text
    if ask_yes_no "Test Process Started" "Started test process  PID $1  ($(proc_name "$1")).
$2

Do you want to manage it now?  (pause / resume / kill)"; then
        manage_process "$1"
    fi
}

stop_demos() {   # $1 = "quiet" to skip the message
    local pid n=0
    for pid in "${DEMO_PIDS[@]}"; do
        if is_our_child "$pid"; then
            kill -s KILL "$pid" 2>/dev/null && n=$(( n + 1 ))
        fi
    done
    for pid in "${DEMO_PIDS[@]}"; do
        wait "$pid" 2>/dev/null
    done
    DEMO_PIDS=()
    STOPPED_COUNT=$n
    [[ ${1:-} == quiet ]] || msg "Test Processes" "Stopped $n test process(es)."
}

screen_test() {
    local pid zpid n i
    while true; do
        calc_size
        reap_demo
        menu_box "Start Test Process (for demo)" "Safe test processes you can monitor, pause, resume and kill.
Running test processes: $(demo_list)" \
            "1" "CPU-heavy process    (yes > /dev/null)" \
            "2" "Sleeping process     (sleep 600)" \
            "3" "Zombie process demo" \
            "4" "Full CPU load        (one busy process per core)" \
            "5" "Stop ALL test processes" || return
        case $CHOICE in
            1)
                yes > /dev/null 2>&1 &
                pid=$!
                DEMO_PIDS+=("$pid")
                sleep 0.3
                started_msg "$pid" "It is CPU-heavy: it uses about 100% of one CPU core.
Status should be R (Running)."
                ;;
            2)
                sleep 600 > /dev/null 2>&1 &
                pid=$!
                DEMO_PIDS+=("$pid")
                sleep 0.3
                started_msg "$pid" "It only sleeps (waits) for 10 minutes and uses no CPU.
Status should be S (Sleeping)."
                ;;
            3)
                # The child "sleep 1" ends after 1 second, but its parent
                # (which became "sleep 600" through exec) never collects it,
                # so the child stays as a ZOMBIE.
                bash -c 'sleep 1 & exec sleep 600' > /dev/null 2>&1 &
                pid=$!
                DEMO_PIDS+=("$pid")
                sleep 1.5
                zpid=$(ps -o pid= --ppid "$pid" 2>/dev/null | tr -d ' ')
                msg "Zombie Process Demo" "Parent process : PID $pid (sleep 600)
Zombie child   : PID ${zpid:-?} (status $(proc_state "${zpid:-0}"))

The child finished after 1 second, but its parent never collected
its exit status, so it stays in the process table as a ZOMBIE (Z).

Try:  'Process status' -> 'List zombie processes'.
To clean it up, kill the PARENT ($pid). init then adopts the
zombie and removes it."
                ;;
            4)
                n=$(nproc 2>/dev/null || echo 1)
                ask_yes_no "Full CPU Load" "This starts $n busy process(es), one per CPU core,
so the CPU goes to almost 100%.

Your computer may feel slow until you stop them
(option 5 here, or they stop automatically when you exit).

Continue?" no || continue
                for (( i = 0; i < n; i++ )); do
                    yes > /dev/null 2>&1 &
                    DEMO_PIDS+=("$!")
                done
                LAST_ALERT=""      # show the red warning again for this new load
                msg "Full CPU Load" "Started $n busy process(es).

Press Back to go to the main menu: CPU should show HIGH and a
red warning window should appear (it may take 1-2 seconds)."
                ;;
            5)
                if (( ${#DEMO_PIDS[@]} == 0 )); then
                    msg "Test Processes" "No test processes are running."
                    continue
                fi
                ask_yes_no "Stop Test Processes" "Kill all running test processes now?
$(demo_list)" || continue
                stop_demos
                ;;
        esac
    done
}

# --- Option 12: jobs / bg / fg demo -------------------------------------
screen_jobs() {
    local demo
    # The demo runs in a separate bash shell with job control turned ON,
    # because jobs/bg/fg only work on jobs started by the same shell.
    demo=$(cat <<'EOF'
set -m
trap 'kill %1 %2 2>/dev/null' EXIT
Y=$'\e[1;33m'; G=$'\e[1;32m'; N=$'\e[0m'
cmd()  { printf '\n%s$ %s%s\n' "$Y" "$1" "$N"; sleep 0.6; }
note() { printf '%s  -> %s%s\n' "$G" "$1" "$N"; sleep 0.8; }

echo "=============================================================="
echo "   JOBS DEMO:   jobs  |  kill -STOP  |  bg  |  fg  |  kill"
echo "=============================================================="
echo "jobs, bg and fg only work on jobs started by the SAME shell,"
echo "so this demo shell starts its own two jobs and controls them."

cmd "sleep 300 &";    sleep 300 &
cmd "sleep 12 &";     sleep 12 &
cmd "jobs -l";        jobs -l
note "Two background jobs: [1] and [2]. Both are Running."

cmd "kill -STOP %1";  kill -STOP %1; sleep 0.5
cmd "jobs -l";        jobs -l
note "Job [1] is now Stopped (paused) - the same as pressing Ctrl+Z."

cmd "bg %1";          bg %1; sleep 0.5
cmd "jobs -l";        jobs -l
note "bg resumed job [1] in the BACKGROUND. It is Running again."

cmd "fg %2"
note "fg brings job [2] to the FOREGROUND. The shell now waits until"
note "it finishes (a few seconds; press Ctrl+C to end it early)..."
fg %2
note "Job [2] has finished, so the shell is free again."

cmd "jobs -l";        jobs -l
cmd "kill %1";        kill %1; sleep 0.5
cmd "jobs -l";        jobs -l
note "Job [1] was terminated. No jobs are left - demo complete."
EOF
)
    clear
    bash -c "$demo"
    echo
    flush_keys
    read -rp "Press Enter to go back to the menu... " _
}

# --- Option 13: export report -------------------------------------------
screen_report() {
    local file="$SCRIPT_DIR/$REPORT_NAME" cpu ram disk
    # An old report made with sudo belongs to root: remove it so a new one can be written
    [[ -e $file && ! -w $file ]] && rm -f "$file" 2>/dev/null
    # If the program's folder still cannot be written, use the home folder instead
    if [[ -e $file && ! -w $file ]] || [[ ! -e $file && ! -w $SCRIPT_DIR ]]; then
        file="$HOME/$REPORT_NAME"
    fi
    cpu=$(to_int "$(cpu_usage 1)")
    ram=$(to_int "$(ram_usage)")
    disk=$(to_int "$(disk_usage)")
    if ! { {
        echo "======================================================================"
        echo "                     SYSTEM MONITORING REPORT"
        echo "======================================================================"
        echo "Generated on : $(date '+%d-%m-%Y %H:%M:%S')"
        echo "Hostname     : $(hostname)"
        echo "User         : $(whoami)"
        echo "OS           : $(os_name)"
        echo "Kernel       : $(uname -r)"
        echo "Uptime       : $(uptime_text)"
        echo "CPU cores    : $(nproc 2>/dev/null)"
        echo
        echo "---------------------------- USAGE SUMMARY ---------------------------"
        echo "CPU  : $(make_bar "$cpu" 30)$(high_tag "$cpu")"
        echo "RAM  : $(make_bar "$ram" 30)$(high_tag "$ram")"
        echo "DISK : $(make_bar "$disk" 30)$(high_tag "$disk")   (root filesystem /)"
        echo "Load average (1, 5, 15 min) : $(cut -d' ' -f1-3 /proc/loadavg)"
        echo
        echo "----------------------------- MEMORY (free -h) -----------------------"
        free -h
        echo
        echo "------------------------------ DISK (df -h) --------------------------"
        disk_table
        echo
        echo "---------------------------- PROCESS STATES --------------------------"
        state_counts_text
        echo
        echo "------------------------ TOP 10 PROCESSES BY CPU ---------------------"
        ps -eo pid,user,%cpu,%mem,stat,etime,comm --sort=-%cpu | head -n 11
        echo
        echo "------------------------ TOP 10 PROCESSES BY RAM ---------------------"
        ps -eo pid,user,%cpu,%mem,rss,stat,comm --sort=-%mem | head -n 11
        echo
        echo "============================ END OF REPORT ==========================="
    } > "$file"; } 2>/dev/null; then
        err "Export Report" "Could not write the report to:
$file

You may not have permission to write there.
If an old report was created with sudo, delete it first:
    sudo rm \"$file\""
        return
    fi
    # When run with sudo, give the report back to the real user
    [[ -n ${SUDO_USER:-} ]] && chown "$SUDO_USER:" "$file" 2>/dev/null
    cp "$file" "$TMP_FILE"
    msg "Export Report" "Report saved to:
$file

Press OK to view it."
    show_file "Report: $REPORT_NAME"
}

# --- Option 14: help ----------------------------------------------------
screen_help() {
    cat > "$TMP_FILE" <<EOF
HOW TO USE THIS PROGRAM
=======================
Keys:  Up/Down arrows = move     Enter = select     Tab = go to buttons
       Esc = go back             PgUp/PgDn = scroll long text
The mouse does not work in these boxes - use the keyboard.

Typing numbers does not jump in these menus; use the arrow keys.

The top of the main menu shows CPU, RAM and DISK usage.
It refreshes every time you come back to the main menu.
At ${WARN_LIMIT}% or more a value is marked HIGH and a red warning appears.
For CPU or RAM it names the process using the most and offers
'Manage it' (open the Manage screen) or 'Ignore'.
The warning is shown once; it appears again after usage drops
below ${WARN_LIMIT}%, or when you start 'Full CPU load' again.

MENU OPTIONS
 1  Show running processes   all processes with PID, CPU%, RAM%, status
 2  CPU usage                % bar, cores, load average, top CPU users
 3  RAM usage                % bar, total/used/free RAM, top RAM users
 4  Disk usage               % bar for /, size of every filesystem
 5  Live CPU meter           bar that updates every second for 10 s
 6  Top 5 heavy processes    pick one to manage it
 7  Search for a process     by name (pgrep) or by PID
 8  Manage a process         pause, resume, terminate, force kill, renice
 9  Process status           status of a PID, counts, zombies, legend
10  Process tree             parent -> child processes (pstree)
11  Start test process       safe processes to use in the demo
12  Jobs demo                jobs / bg / fg with job control
13  Export report            saves $REPORT_NAME
14  Help                     this screen
 0  Exit                     test processes are stopped automatically

QUICK DEMO
 11 -> 1 (CPU-heavy) -> Yes (manage it) -> 1 Pause -> Yes  (status T)
                                        -> 2 Resume         (status R)
                                        -> 4 Force kill -> Tab to Yes -> Enter
 (The Force kill question starts on No, so Enter alone cancels it.)
EOF
    show_file "Help"
}

# --- High-usage alert (checked every time the main menu is shown) -------
# Returns 0 only if the user managed a process (then usage is measured again).
check_alerts() {   # $1 = cpu %, $2 = ram %, $3 = disk %
    local cpu=$1 ram=$2 disk=$3 high="" text what col pid="" val="" name="" when=""
    (( cpu  >= WARN_LIMIT )) && high+="CPU "
    (( ram  >= WARN_LIMIT )) && high+="RAM "
    (( disk >= WARN_LIMIT )) && high+="DISK "
    if [[ -z $high ]]; then
        LAST_ALERT=""
        return 1
    fi
    [[ $high == "$LAST_ALERT" ]] && return 1    # already warned about this
    LAST_ALERT=$high

    text="WARNING: usage is at or above ${WARN_LIMIT}%!
"
    [[ $high == *CPU*  ]] && text+="
  CPU  is at ${cpu}%"
    [[ $high == *RAM*  ]] && text+="
  RAM  is at ${ram}%"
    [[ $high == *DISK* ]] && text+="
  DISK is at ${disk}%  (delete or move big files to free space)"

    if   [[ $high == *CPU* ]]; then what=CPU; col=%cpu
    elif [[ $high == *RAM* ]]; then what=RAM; col=%mem
    else
        flush_keys
        NEWT_COLORS=$ALERT_THEME whiptail --title " HIGH USAGE ALERT " --msgbox "$text" "$(box_h "$text")" "$W"
        return 1
    fi
    if [[ $what == CPU ]]; then
        # The 2nd screen of top shows CPU% over the last 0.5 s ("right now"),
        # while ps shows an average since each process started.
        # HOME is changed so a personal top config cannot change the columns.
        read -r pid val name < <(HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent \
            top -b -n 2 -d 0.5 -w 512 2>/dev/null |
            awk '/^ *PID / { n++; next } n == 2 && NF >= 12 && $12 != "top" && $9 + 0 > 0 { print $1, $9, $12; exit }')
        [[ -n $pid ]] && when=" right now"
    fi
    if [[ -z $pid ]]; then
        read -r pid val name < <(ps -eo "pid=,${col}=,comm=" --sort="-${col}" | awk '$3 != "ps"' | head -n 1)
    fi
    text+="

Biggest $what user: $name (PID $pid) using ${val}% $what$when.

Do you want to manage this process now?"
    flush_keys
    if NEWT_COLORS=$ALERT_THEME whiptail --title " HIGH USAGE ALERT " \
           --yes-button "Manage it" --no-button "Ignore" \
           --yesno "$text" "$(box_h "$text")" "$W"; then
        if [[ -n $pid ]]; then
            manage_process "$pid"
            return 0
        fi
    fi
    return 1
}


# =====================================================================
# 6. START-UP CHECKS AND MAIN MENU LOOP
# =====================================================================

startup_checks() {
    local missing="" cmd lines cols
    if [[ $(uname -s) != Linux || ! -r /proc/stat ]]; then
        echo "ERROR: This program needs Linux (for example Ubuntu on WSL)."
        exit 1
    fi
    if ! command -v whiptail > /dev/null 2>&1; then
        echo "ERROR: 'whiptail' is not installed."
        echo "Install it with:"
        echo "    sudo apt update && sudo apt install -y whiptail"
        exit 1
    fi
    for cmd in ps top free df pgrep renice awk sed nproc stty; do
        command -v "$cmd" > /dev/null 2>&1 || missing+="$cmd "
    done
    if [[ -n $missing ]]; then
        echo "ERROR: these commands are missing: $missing"
        echo "Install them with:"
        echo "    sudo apt update && sudo apt install -y procps coreutils util-linux gawk sed"
        exit 1
    fi
    if [[ ! -t 0 || ! -t 1 || ! -t 2 ]]; then
        echo "ERROR: please run this program directly in a terminal, without"
        echo "redirecting its input or output:   bash sysmon.sh"
        exit 1
    fi
    read -r lines cols < <(stty size 2>/dev/null)
    if [[ $lines =~ ^[0-9]+$ && $cols =~ ^[0-9]+$ ]] && (( lines < 20 || cols < 70 )); then
        echo "Your terminal window is too small (${cols} x ${lines})."
        echo "Please make it at least 70 columns x 20 lines and run again."
        exit 1
    fi
}

on_exit() {
    trap '' INT TERM HUP          # a second signal must not stop the clean-up
    [[ -n $TMP_FILE ]] && rm -f "$TMP_FILE"
    stop_demos quiet
    clear
    echo "Thank you for using the $APP_TITLE."
    if (( STOPPED_COUNT > 0 )); then
        echo "Stopped $STOPPED_COUNT test process(es) that were still running."
    fi
}

main_menu() {
    local cpu ram disk text backtitle
    backtitle="UNIX-Based System Monitoring and Process Management System   |   Host: $(hostname)   |   User: $(whoami)"
    while true; do
        calc_size
        reap_demo
        cpu=$(to_int "$(cpu_usage 0.4)")
        ram=$(to_int "$(ram_usage)")
        disk=$(to_int "$(disk_usage)")
        # If the user managed a process from the alert, measure again first
        if check_alerts "$cpu" "$ram" "$disk"; then
            continue
        fi
        calc_size
        reap_demo
        flush_keys

        text="CPU  $(make_bar "$cpu" 20)$(high_tag "$cpu")
RAM  $(make_bar "$ram" 20)$(high_tag "$ram")
DISK $(make_bar "$disk" 20)$(high_tag "$disk")
Uptime: $(uptime_text)    Test processes running: ${#DEMO_PIDS[@]}"

        CHOICE=$(whiptail --title "$APP_TITLE" --backtitle "$backtitle" \
                 --ok-button "Select" --cancel-button "Exit" --default-item "$LAST_CHOICE" \
                 --menu "$text" "$H" "$W" "$LIST_H" \
                 "1"  "Show running processes" \
                 "2"  "CPU usage" \
                 "3"  "RAM usage" \
                 "4"  "Disk usage" \
                 "5"  "Live CPU meter (10 seconds)" \
                 "6"  "Top 5 heavy processes" \
                 "7"  "Search for a process" \
                 "8"  "Manage a process (pause / resume / kill)" \
                 "9"  "Process status" \
                 "10" "Process tree" \
                 "11" "Start test process (for demo)" \
                 "12" "Jobs demo (jobs / bg / fg)" \
                 "13" "Export report to file" \
                 "14" "Help" \
                 "0"  "Exit" 3>&1 1>&2 2>&3) || CHOICE=0

        if [[ $CHOICE == 0 ]]; then
            if ask_yes_no "Exit" "Do you want to exit the System Monitor?
(Any test processes still running will be stopped.)"; then
                return
            fi
            continue
        fi
        LAST_CHOICE=$CHOICE

        case $CHOICE in
            1)  screen_processes ;;
            2)  screen_cpu ;;
            3)  screen_ram ;;
            4)  screen_disk ;;
            5)  screen_live_cpu ;;
            6)  screen_top ;;
            7)  screen_search ;;
            8)  manage_process ;;
            9)  screen_status ;;
            10) screen_tree ;;
            11) screen_test ;;
            12) screen_jobs ;;
            13) screen_report ;;
            14) screen_help ;;
        esac
    done
}

# ----------------------------- PROGRAM START -----------------------------
startup_checks
TMP_FILE=$(mktemp "${TMPDIR:-/tmp}/sysmon.XXXXXX") || { echo "ERROR: cannot create a temporary file."; exit 1; }
trap on_exit EXIT
trap 'exit 130' INT TERM HUP
find_protected_pids
calc_size
main_menu
exit 0
