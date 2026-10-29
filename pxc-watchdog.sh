#!/usr/bin/env bash
#
# pxc-watchdog.sh - restart a Percona XtraDB Cluster node stuck in "Joining".
#
# Runs on the site 2 node only, from pxc-watchdog.timer. When the inter-site
# link returns, the node sometimes stays in "Joining: receiving State Transfer"
# forever. This script detects that (no bytes arriving on the SST/IST ports and
# no local SST work) and restarts the local mysql unit.
#
# It never bootstraps, never touches pc.bootstrap and never acts on a node
# that is not Joining. The only action it takes is stop + start of the local
# unit, and only when a site 1 node is reachable and the restart cap allows it.
#
# Exit codes:
#   0  nothing to do, transfer in progress, or restart issued
#   1  error (bad configuration, restart failed)
#   2  node stuck but restart cap reached: manual intervention needed

set -uo pipefail

# ---------------------------------------------------------------------------
# Settings. Each one can be overridden from the environment, e.g. through
# /etc/default/pxc-watchdog (loaded by pxc-watchdog.service).
# ---------------------------------------------------------------------------

# systemd unit that runs mysqld.
SERVICE_NAME="${SERVICE_NAME:-mysql}"
# Site 1 nodes, space separated. At least one must accept TCP on GCOMM_PORT
# before a restart is attempted.
DONOR_IPS="${DONOR_IPS:-10.0.1.11 10.0.1.12}"
GCOMM_PORT="${GCOMM_PORT:-4567}"
# Local ports the donor connects to: SST (4444) and IST (4568).
TRANSFER_PORTS="${TRANSFER_PORTS:-4444 4568}"
# Seconds between the two progress samples.
WAIT_SECONDS="${WAIT_SECONDS:-180}"
# At most MAX_RESTARTS restarts per rolling RESTART_WINDOW_SECONDS.
MAX_RESTARTS="${MAX_RESTARTS:-4}"
RESTART_WINDOW_SECONDS="${RESTART_WINDOW_SECONDS:-86400}"
# Seconds "systemctl stop" may take before mysqld is SIGKILLed, and seconds to
# wait for the unit to go down after that. Killing mysqld during IST usually
# turns the next join into a full SST, so keep STOP_TIMEOUT generous.
STOP_TIMEOUT="${STOP_TIMEOUT:-300}"
KILL_WAIT_SECONDS="${KILL_WAIT_SECONDS:-60}"
# Timeouts for the TCP reachability probe and for the mysql client.
TCP_TIMEOUT="${TCP_TIMEOUT:-5}"
MYSQL_TIMEOUT="${MYSQL_TIMEOUT:-20}"
# Client options file with [client] user/password/socket (chmod 600).
MYSQL_DEFAULTS_FILE="${MYSQL_DEFAULTS_FILE:-/etc/pxc-watchdog/my.cnf}"
# SST helper processes (wsrep_sst_xtrabackup-v2 and its children). Only
# matches that descend from the unit's mysqld count. If that process tree uses
# at least SST_MIN_CPU_SECONDS of CPU during the wait, the SST is still working
# locally (e.g. xtrabackup --prepare after the network part finished) and the
# node is not considered stuck.
SST_PROC_PATTERN="${SST_PROC_PATTERN:-(^|/)wsrep_sst_}"
SST_MIN_CPU_SECONDS="${SST_MIN_CPU_SECONDS:-5}"
# Persistent state (restart history) and the lock that prevents overlap.
STATE_DIR="${STATE_DIR:-/var/lib/pxc-watchdog}"
LOCK_FILE="${LOCK_FILE:-/run/lock/pxc-watchdog.lock}"
# journal tag (journalctl -t pxc-watchdog).
LOG_TAG="${LOG_TAG:-pxc-watchdog}"
# The unit that runs this script. Under systemd, the script refuses to run if
# its worst-case run time does not fit in that unit's TimeoutStartSec: being
# killed between stop and start would leave mysql down.
WATCHDOG_UNIT="${WATCHDOG_UNIT:-pxc-watchdog.service}"
# 1 = log what would be done, change nothing.
DRY_RUN="${DRY_RUN:-0}"

# ---------------------------------------------------------------------------

HISTORY_FILE="$STATE_DIR/restarts"

log() {
    local prio=$1
    shift
    logger -t "$LOG_TAG" -p "daemon.$prio" -- "$*"
    if [[ -t 2 ]]; then
        printf '%s: %s\n' "$prio" "$*" >&2
    fi
}

die() {
    log err "$*"
    exit 1
}

dry_run() {
    [[ $DRY_RUN == 1 ]]
}

check_config() {
    local name port mode
    for name in GCOMM_PORT WAIT_SECONDS MAX_RESTARTS RESTART_WINDOW_SECONDS \
        STOP_TIMEOUT KILL_WAIT_SECONDS TCP_TIMEOUT MYSQL_TIMEOUT SST_MIN_CPU_SECONDS; do
        [[ ${!name} =~ ^[0-9]+$ ]] || die "config: $name must be a non-negative integer, got '${!name}'"
    done
    for port in $TRANSFER_PORTS; do
        [[ $port =~ ^[0-9]+$ ]] || die "config: bad port '$port' in TRANSFER_PORTS"
    done
    [[ -n ${TRANSFER_PORTS// /} ]] || die "config: TRANSFER_PORTS is empty"
    [[ -n ${DONOR_IPS// /} ]] || die "config: DONOR_IPS is empty"
    [[ -r $MYSQL_DEFAULTS_FILE ]] || die "credentials file $MYSQL_DEFAULTS_FILE is missing or unreadable"
    mode=$(stat -c %a "$MYSQL_DEFAULTS_FILE" 2>/dev/null) || mode=600
    if (( 8#$mode & 8#077 )); then
        log warning "$MYSQL_DEFAULTS_FILE has mode $mode; it should be 600"
    fi
    check_run_budget
}

# Worst-case run time in seconds: two mysql queries, the wait, a TCP probe to
# every site 1 node, a stop that times out (+10s kill grace), the wait after
# SIGKILL, and 30s for everything else.
run_budget() {
    local -a donors
    read -r -a donors <<<"$DONOR_IPS"
    echo $(( 2 * MYSQL_TIMEOUT + WAIT_SECONDS + ${#donors[@]} * TCP_TIMEOUT \
        + STOP_TIMEOUT + 10 + KILL_WAIT_SECONDS + 30 ))
}

# Converts a systemd time span as printed by "systemctl show" ("15min",
# "1h 2min 3s", "1min 30.500000s", "0") to whole seconds. Prints "infinity"
# for infinity. Fails on anything else.
timespan_seconds() {
    local span=$1 total=0 n
    if [[ $span == infinity || $span == 0 ]]; then
        echo "$span"
        return 0
    fi
    [[ $span =~ [0-9] ]] || return 1
    while [[ $span =~ ^\ *([0-9]+)(\.[0-9]+)?(y|M|w|d|h|min|s|ms|us|μs)(\ .*)?$ ]]; do
        n=${BASH_REMATCH[1]}
        span=${BASH_REMATCH[4]}
        case ${BASH_REMATCH[3]} in
            y) n=$(( n * 31557600 )) ;;
            M) n=$(( n * 2629800 )) ;;
            w) n=$(( n * 604800 )) ;;
            d) n=$(( n * 86400 )) ;;
            h) n=$(( n * 3600 )) ;;
            min) n=$(( n * 60 )) ;;
            s) ;;
            *) n=0 ;;
        esac
        total=$(( total + n ))
    done
    [[ -z ${span// /} ]] || return 1
    echo "$total"
}

# Under systemd, refuses to run if the worst case does not fit in the unit's
# TimeoutStartSec. Run by hand, nothing kills the script, so there is no limit.
check_run_budget() {
    local out limit budget
    [[ -n ${INVOCATION_ID:-} ]] || return 0
    out=$(systemctl show --property=TimeoutStartUSec "$WATCHDOG_UNIT" 2>/dev/null)
    if ! limit=$(timespan_seconds "${out#TimeoutStartUSec=}"); then
        log warning "cannot read TimeoutStartSec of $WATCHDOG_UNIT (got '$out'); skipping the run-time check"
        return 0
    fi
    # 0 disables the timeout, like infinity.
    [[ $limit != infinity && $limit != 0 ]] || return 0
    budget=$(run_budget)
    if (( budget > limit )); then
        die "config: worst-case run time is ${budget}s (2*MYSQL_TIMEOUT + WAIT_SECONDS + TCP_TIMEOUT per site 1 node + STOP_TIMEOUT + 10 + KILL_WAIT_SECONDS + 30) but $WATCHDOG_UNIT has TimeoutStartSec=${limit}s; systemd could kill this script between stop and start and leave $SERVICE_NAME down. Raise TimeoutStartSec or lower the timeouts."
    fi
}

# Prints wsrep_local_state_comment. Fails if mysqld cannot be queried.
wsrep_state() {
    local out
    if ! out=$(timeout "$MYSQL_TIMEOUT" mysql --defaults-extra-file="$MYSQL_DEFAULTS_FILE" \
            --connect-timeout=10 -N -B \
            -e "SHOW GLOBAL STATUS LIKE 'wsrep_local_state_comment'" 2>&1); then
        log warning "cannot query mysqld: ${out//$'\n'/ }"
        return 1
    fi
    awk -F'\t' '$1 == "wsrep_local_state_comment" { print $2 }' <<<"$out"
}

# Prints one line per established connection on the transfer ports:
# "<local addr:port> <peer addr:port> <bytes_received>".
transfer_sample() {
    local port filter="" out
    for port in $TRANSFER_PORTS; do
        filter+="${filter:+ or }sport = :$port"
    done
    if ! out=$(ss -tinH state established "( $filter )"); then
        log err "ss failed; cannot sample transfer connections"
        return 1
    fi
    # ss prints a socket line followed by an indented info line. bytes_received
    # is omitted while it is still 0.
    awk '
        /^[^ \t]/ { if (key != "") print key, bytes; key = $(NF - 1) " " $NF; bytes = 0; next }
        { for (i = 1; i <= NF; i++) if ($i ~ /^bytes_received:/) bytes = substr($i, 16) }
        END { if (key != "") print key, bytes }
    ' <<<"$out"
}

transfer_summary() {
    awk 'NF { n++; b += $3 } END { printf "%d transfer connection(s), %d bytes received", n, b }' <<<"$1"
}

# Succeeds if, between two transfer samples, a connection received more bytes
# or a new connection appeared that has received data. Connections are compared
# individually so a socket closing between samples cannot hide or fake progress.
transfer_progressed() {
    local -A before=()
    local local_addr peer bytes prev
    while read -r local_addr peer bytes; do
        [[ -n $local_addr ]] && before["$local_addr $peer"]=$bytes
    done <<<"$1"
    while read -r local_addr peer bytes; do
        [[ -n $local_addr ]] || continue
        prev=${before["$local_addr $peer"]:-0}
        if (( bytes > prev )); then
            return 0
        fi
    done <<<"$2"
    return 1
}

# Succeeds if process $1 descends from process $2 (and is not $2 itself).
descends_from() {
    local pid=$1 ancestor=$2 stat depth
    local -a fields
    for (( depth = 0; depth < 64; depth++ )); do
        { read -r stat <"/proc/$pid/stat"; } 2>/dev/null || return 1
        # After "pid (comm) ", fields[1] is field 4: the parent PID.
        read -r -a fields <<<"${stat##*) }"
        pid=${fields[1]}
        [[ $pid == "$ancestor" ]] && return 0
        (( pid > 1 )) || return 1
    done
    return 1
}

# Prints the CPU ticks used by the SST helper process tree, including reaped
# children (cutime/cstime), so the total keeps growing while pipeline stages
# come and go. Only helpers started by the unit's mysqld count, so an admin's
# "vim /usr/bin/wsrep_sst_common" is ignored. Prints nothing if no SST helper
# is running.
sst_cpu_ticks() {
    local -a queue=() fields
    local -A seen=()
    local out main_pid pids pid child stat total=0 found=0
    out=$(systemctl show --property=MainPID "$SERVICE_NAME" 2>/dev/null)
    main_pid=${out#MainPID=}
    [[ $main_pid =~ ^[0-9]+$ ]] && (( main_pid > 0 )) || return 0
    pids=$(pgrep -f -- "$SST_PROC_PATTERN") || return 0
    for pid in $pids; do
        if descends_from "$pid" "$main_pid"; then
            queue+=("$pid")
        fi
    done
    while (( ${#queue[@]} )); do
        pid=${queue[0]}
        queue=("${queue[@]:1}")
        [[ -z ${seen[$pid]:-} ]] || continue
        seen[$pid]=1
        { read -r stat <"/proc/$pid/stat"; } 2>/dev/null || continue
        # Drop "pid (comm) " (comm may contain spaces); fields[0] is then field 3,
        # so utime/stime/cutime/cstime (fields 14-17) are fields[11..14].
        read -r -a fields <<<"${stat##*) }"
        total=$(( total + fields[11] + fields[12] + fields[13] + fields[14] ))
        found=1
        for child in $(pgrep -P "$pid"); do
            queue+=("$child")
        done
    done
    if (( found )); then
        echo "$total"
    fi
}

# Prints the first site 1 node that accepts a TCP connection on GCOMM_PORT.
reachable_donor() {
    local ip
    for ip in $DONOR_IPS; do
        # shellcheck disable=SC2016 # $1/$2 are expanded by the inner bash
        if timeout "$TCP_TIMEOUT" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$ip" "$GCOMM_PORT" 2>/dev/null; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# Prints the restart timestamps (epoch seconds) inside the rolling window.
recent_restarts() {
    local now
    now=$(date +%s)
    [[ -r $HISTORY_FILE ]] || return 0
    awk -v cutoff=$(( now - RESTART_WINDOW_SECONDS )) '$1 ~ /^[0-9]+$/ && $1 > cutoff' "$HISTORY_FILE"
}

# Appends "now" to the restart history, dropping entries outside the window.
record_restart() {
    local tmp
    mkdir -p "$STATE_DIR" || return 1
    tmp=$(mktemp "$STATE_DIR/restarts.XXXXXX") || return 1
    if { recent_restarts; date +%s; } >"$tmp" && mv -f "$tmp" "$HISTORY_FILE"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Waits until the unit is no longer running or stopping.
wait_until_stopped() {
    local i
    for (( i = 0; i <= KILL_WAIT_SECONDS; i++ )); do
        case $(systemctl is-active "$SERVICE_NAME") in
            active | activating | deactivating | reloading | refreshing) sleep 1 ;;
            *) return 0 ;;
        esac
    done
    return 1
}

restart_service() {
    local rc
    if dry_run; then
        log notice "DRY_RUN: would run 'systemctl stop $SERVICE_NAME' (SIGKILL after ${STOP_TIMEOUT}s), then 'systemctl start --no-block $SERVICE_NAME'"
        return 0
    fi

    # Count the restart before touching the unit, so a crash mid-restart still
    # counts against the cap. Without a working history there is no cap.
    record_restart || die "cannot write $HISTORY_FILE; refusing to restart without a working restart cap"

    log warning "stopping $SERVICE_NAME (timeout ${STOP_TIMEOUT}s)"
    timeout -k 10 "$STOP_TIMEOUT" systemctl stop "$SERVICE_NAME"
    rc=$?
    if (( rc == 124 || rc == 137 )); then
        # timeout only killed the systemctl client; the stop job and mysqld are
        # still there. Kill mysqld so the stop job can complete.
        log err "'systemctl stop $SERVICE_NAME' did not finish in ${STOP_TIMEOUT}s; sending SIGKILL"
        systemctl kill --signal=SIGKILL "$SERVICE_NAME" || log err "systemctl kill $SERVICE_NAME failed"
    elif (( rc != 0 )); then
        log err "'systemctl stop $SERVICE_NAME' failed with exit code $rc"
    fi

    if ! wait_until_stopped; then
        log crit "$SERVICE_NAME is still running after stop/kill; not starting it. Manual intervention required."
        return 1
    fi

    systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1
    if ! systemctl start --no-block "$SERVICE_NAME"; then
        log crit "'systemctl start --no-block $SERVICE_NAME' failed. Manual intervention required."
        return 1
    fi
    log warning "start of $SERVICE_NAME queued; the node will rejoin (IST or SST) in the background"
}

main() {
    local unit_state state reason donor count summary
    local net_before net_after cpu_before cpu_after cpu_min_ticks

    check_config

    exec 9>"$LOCK_FILE" || die "cannot open lock file $LOCK_FILE"
    if ! flock -n 9; then
        log info "another pxc-watchdog run holds $LOCK_FILE; skipping"
        return 0
    fi

    # A unit that is activating (e.g. a long SST after a restart), stopping or
    # stopped is not ours to judge.
    unit_state=$(systemctl is-active "$SERVICE_NAME")
    if [[ $unit_state != active ]]; then
        log info "$SERVICE_NAME is '$unit_state'; nothing to do"
        return 0
    fi

    # If mysqld cannot be queried we know nothing; never restart on that basis.
    state=$(wsrep_state) || return 0
    if [[ $state != Joining* ]]; then
        log info "wsrep_local_state_comment='$state'; nothing to do"
        return 0
    fi

    net_before=$(transfer_sample) || return 1
    cpu_before=$(sst_cpu_ticks)
    summary=$(transfer_summary "$net_before")
    log notice "node is '$state' ($summary); re-checking in ${WAIT_SECONDS}s"
    sleep "$WAIT_SECONDS"

    state=$(wsrep_state) || return 0
    if [[ $state != Joining* ]]; then
        log notice "state changed to '$state' during the wait; no action"
        return 0
    fi
    net_after=$(transfer_sample) || return 1
    cpu_after=$(sst_cpu_ticks)

    summary=$(transfer_summary "$net_after")
    if transfer_progressed "$net_before" "$net_after"; then
        log notice "state transfer in progress ($summary); no action"
        return 0
    fi
    cpu_min_ticks=$(( SST_MIN_CPU_SECONDS * $(getconf CLK_TCK) ))
    if [[ -n $cpu_before && -n $cpu_after ]] && (( cpu_after - cpu_before >= cpu_min_ticks )); then
        log notice "no network progress, but the SST helper used $(( cpu_after - cpu_before )) CPU ticks in ${WAIT_SECONDS}s; SST is working locally; no action"
        return 0
    fi

    if [[ -z $net_after ]]; then
        reason="no transfer connection on ports $TRANSFER_PORTS"
    else
        reason="transfer connection open but no bytes received in ${WAIT_SECONDS}s ($summary)"
    fi
    log warning "node stuck in '$state': $reason"

    # Reachability first: while the link is down a restart would not help, so
    # there is nothing to alert on yet, even with the cap reached.
    if ! donor=$(reachable_donor); then
        log warning "no site 1 node ($DONOR_IPS) reachable on TCP $GCOMM_PORT; inter-site link is probably down, a restart would not help; no action"
        return 0
    fi

    count=$(recent_restarts | wc -l)
    if (( count >= MAX_RESTARTS )); then
        log crit "RESTART CAP REACHED: node stuck in '$state' but $count restarts already in the last $(( RESTART_WINDOW_SECONDS / 3600 ))h (max $MAX_RESTARTS); NOT restarting $SERVICE_NAME. Manual intervention required."
        return 2
    fi

    log warning "site 1 node $donor reachable on TCP $GCOMM_PORT; restarting $SERVICE_NAME (restart $(( count + 1 )) of $MAX_RESTARTS in the window)"
    restart_service || return 1
}

main "$@"
