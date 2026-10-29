#!/usr/bin/env bash
#
# Test harness for pxc-watchdog.sh. Runs the real script with fake mysql, ss,
# systemctl and logger (tests/mocks) first on PATH. Site 1 reachability uses
# real TCP: a local python3 listener stands in for a reachable node and port 1
# on 127.0.0.1 for an unreachable one.
#
# Usage: tests/run-tests.sh

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../pxc-watchdog.sh"
WORK=$(mktemp -d)
LISTENER=

cleanup() {
    [[ -n $LISTENER ]] && kill "$LISTENER" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

command -v python3 >/dev/null || { echo "python3 is required for the test listener" >&2; exit 1; }

python3 -c '
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(16)
print(s.getsockname()[1], flush=True)
while True:
    s.accept()[0].close()
' >"$WORK/port" &
LISTENER=$!
for _ in {1..50}; do
    [[ -s $WORK/port ]] && break
    sleep 0.1
done
OPEN_PORT=$(cat "$WORK/port")
CLOSED_PORT=1

JOINING="Joining: receiving State Transfer"
SERVICE=mysql

# --- fixtures ---------------------------------------------------------------

new_case() {
    MOCK_DIR=$(mktemp -d "$WORK/case.XXXXXX")
    export MOCK_DIR
    echo "[client]" >"$MOCK_DIR/my.cnf"
    chmod 600 "$MOCK_DIR/my.cnf"
    : >"$MOCK_DIR/log"
    : >"$MOCK_DIR/systemctl.calls"
    ERRORS=()
}

# states STATE... : what successive mysql calls report ("DOWN" = cannot connect).
states() {
    printf '%s\n' "$@" >"$MOCK_DIR/states"
}

# ss_conn SAMPLE LOCAL PEER BYTES [RECVQ] : add an ESTAB socket to ss call SAMPLE.
ss_conn() {
    printf '%-7s0      %s %s\n\t cubic wscale:7,7 rto:204 rtt:0.4/0.2 mss:1448 bytes_sent:512 bytes_acked:513 bytes_received:%s segs_out:40 segs_in:90\n' \
        "${5:-0}" "$2" "$3" "$4" >>"$MOCK_DIR/ss.$1"
}

# history SECONDS_AGO... : pre-populate the restart history.
history() {
    local ago now
    now=$(date +%s)
    mkdir -p "$MOCK_DIR/state"
    for ago in "$@"; do
        echo $(( now - ago ))
    done >"$MOCK_DIR/state/restarts"
}

# run_watchdog [VAR=value...] : run the script; sets RC.
run_watchdog() {
    env PATH="$HERE/mocks:$PATH" \
        MYSQL_DEFAULTS_FILE="$MOCK_DIR/my.cnf" \
        STATE_DIR="$MOCK_DIR/state" \
        LOCK_FILE="$MOCK_DIR/lock" \
        DONOR_IPS="127.0.0.1" \
        GCOMM_PORT="$OPEN_PORT" \
        WAIT_SECONDS=1 \
        "$@" bash "$SCRIPT" </dev/null >"$MOCK_DIR/out" 2>&1
    RC=$?
}

# --- assertions -------------------------------------------------------------

fail() {
    ERRORS+=("$*")
}

expect_rc() {
    [[ $RC == "$1" ]] || fail "exit code $RC, expected $1"
}

# A stop (possibly repeated after SIGKILL) followed by start --no-block.
expect_restart() {
    local calls
    calls=$(grep -Ex "(stop|start --no-block) $SERVICE" "$MOCK_DIR/systemctl.calls" | paste -sd ';') || true
    [[ $calls =~ ^(stop\ $SERVICE\;)+start\ --no-block\ $SERVICE$ ]] || fail "expected stop then start, got '$calls'"
}

expect_no_restart() {
    local calls
    calls=$(paste -sd ';' "$MOCK_DIR/systemctl.calls")
    [[ -z $calls ]] || fail "unexpected systemctl call(s): $calls"
}

expect_log() {
    grep -Eq -- "$1" "$MOCK_DIR/log" || fail "log does not match /$1/"
}

expect_history_lines() {
    local n=0
    [[ -f $MOCK_DIR/state/restarts ]] && n=$(wc -l <"$MOCK_DIR/state/restarts")
    [[ $n == "$1" ]] || fail "restart history has $n entries, expected $1"
}

expect_calls() {   # expect_calls mysql|ss N
    local n
    n=$(cat "$MOCK_DIR/$1.calls" 2>/dev/null || echo 0)
    [[ $n == "$2" ]] || fail "$1 called $n time(s), expected $2"
}

# --- cases ------------------------------------------------------------------

case_synced() {
    states "Synced"
    run_watchdog
    expect_rc 0
    expect_no_restart
    expect_calls mysql 1
    expect_calls ss 0
    expect_log "^info state is 'Synced'; nothing to do"
    grep -q '^--defaults-extra-file=' "$MOCK_DIR/mysql.args" || fail "--defaults-extra-file is not the first mysql option"
}

case_bytes_increasing() {
    states "$JOINING"
    ss_conn 1 10.0.2.21:4568 10.0.1.11:40112 1000000
    ss_conn 2 10.0.2.21:4568 10.0.1.11:40112 9000000
    run_watchdog
    expect_rc 0
    expect_no_restart
    expect_log "state transfer in progress"
    grep -q 'state established ( sport = :4444 or sport = :4568 )' "$MOCK_DIR/ss.args" || fail "unexpected ss filter"
}

case_estab_no_progress() {
    states "$JOINING"
    ss_conn 1 10.0.2.21:4568 10.0.1.11:40112 52000000 6291456
    ss_conn 2 10.0.2.21:4568 10.0.1.11:40112 52000000 6291456
    run_watchdog
    expect_rc 0
    expect_restart
    expect_history_lines 1
    expect_log "no bytes received in 1s"
}

case_no_connection() {
    states "$JOINING"
    run_watchdog
    expect_rc 0
    expect_restart
    expect_history_lines 1
    expect_log "no connection on ports 4444/4568"
}

case_site1_unreachable() {
    states "$JOINING"
    run_watchdog GCOMM_PORT="$CLOSED_PORT" DONOR_IPS="127.0.0.1 127.0.0.2"
    expect_rc 0
    expect_no_restart
    expect_history_lines 0
    expect_log "no site 1 node .* reachable"
}

case_cap_reached() {
    states "$JOINING"
    history 600 3600 7200 80000
    run_watchdog
    expect_rc 2
    expect_no_restart
    expect_history_lines 4
    expect_log "^crit RESTART CAP REACHED"
}

case_synced_during_wait() {
    states "$JOINING" "Synced"
    run_watchdog
    expect_rc 0
    expect_no_restart
    expect_calls ss 1
    expect_log "state changed to 'Synced'"
}

case_cap_reached_site1_unreachable() {
    states "$JOINING"
    history 600 3600 7200 80000
    run_watchdog GCOMM_PORT="$CLOSED_PORT"
    expect_rc 0
    expect_no_restart
    ! grep -q '^crit' "$MOCK_DIR/log" || fail "unexpected crit message while site 1 is unreachable"
}

case_old_restarts_ignored() {
    states "$JOINING"
    history 600 3600 7200 90000 100000   # only 3 inside the last 24h
    run_watchdog
    expect_rc 0
    expect_restart
    expect_history_lines 4                # 3 recent + this one; old ones pruned
}

case_dry_run() {
    states "$JOINING"
    run_watchdog DRY_RUN=1
    expect_rc 0
    expect_no_restart
    expect_history_lines 0
    expect_log "^notice DRY_RUN: would restart mysql"
}

case_stop_hangs() {
    states "$JOINING"
    run_watchdog MOCK_STOP_HANG=1 STOP_TIMEOUT=1
    expect_rc 0
    expect_restart
    grep -qx "kill -s SIGKILL $SERVICE" "$MOCK_DIR/systemctl.calls" || fail "expected systemctl kill -s SIGKILL"
    expect_log "stop did not finish in 1s; sending SIGKILL"
}

case_stop_fails() {
    states "$JOINING"
    run_watchdog MOCK_STOP_FAIL=1
    expect_rc 1
    expect_log "^err systemctl stop mysql failed \\(exit 5\\); sending SIGKILL"
    expect_log "^crit mysql did not stop; not starting it"
    ! grep -q '^start' "$MOCK_DIR/systemctl.calls" || fail "start must not run after a failed stop"
    ! grep -q 'did not finish' "$MOCK_DIR/log" || fail "a failed stop was reported as a timeout"
}

case_ss_fails() {
    states "$JOINING"
    run_watchdog MOCK_SS_FAIL=1
    expect_rc 1
    expect_no_restart
    expect_log "^err ss failed; cannot check transfer progress"
}

case_mysqld_down() {
    states DOWN
    run_watchdog
    expect_rc 0
    expect_no_restart
    expect_log "cannot query mysqld"
}

case_new_connection() {
    states "$JOINING"
    ss_conn 1 10.0.2.21:4444 10.0.1.11:40112 300
    ss_conn 2 10.0.2.21:4444 10.0.1.12:51234 40   # old one closed, new donor
    run_watchdog
    expect_rc 0
    expect_no_restart
}

case_custom_service_name() {
    SERVICE=mysqld
    states "$JOINING"
    run_watchdog SERVICE_NAME=mysqld
    expect_rc 0
    expect_restart
    SERVICE=mysql
}

case_lock_held() {
    states "$JOINING"
    exec 8>"$MOCK_DIR/lock"
    flock 8
    run_watchdog
    exec 8>&-
    expect_rc 0
    expect_no_restart
    expect_calls mysql 0
    expect_log "another run is still active"
}

case_lock_dir_missing() {
    states "$JOINING"
    run_watchdog LOCK_FILE="$MOCK_DIR/no-such-dir/lock"
    expect_rc 1
    expect_no_restart
    expect_calls mysql 0
    expect_log "^err cannot open lock file"
}

case_missing_credentials() {
    states "$JOINING"
    rm "$MOCK_DIR/my.cnf"
    run_watchdog
    expect_rc 1
    expect_no_restart
    expect_log "^err cannot read credentials file"
}

# --- runner -----------------------------------------------------------------

PASS=0
FAIL=0
run_case() {
    local name=$1 description=$2
    new_case
    "$name"
    if (( ${#ERRORS[@]} )); then
        FAIL=$(( FAIL + 1 ))
        printf 'FAIL  %s\n' "$description"
        printf '      - %s\n' "${ERRORS[@]}"
        sed 's/^/      | /' "$MOCK_DIR/log"
    else
        PASS=$(( PASS + 1 ))
        printf 'PASS  %s\n' "$description"
    fi
}

run_case case_synced                        "node Synced -> exits, no restart"
run_case case_bytes_increasing              "Joining, bytes increasing -> no restart"
run_case case_estab_no_progress             "Joining, ESTAB connection, no byte change -> restart"
run_case case_no_connection                 "Joining, no connection -> restart"
run_case case_site1_unreachable             "Joining, site 1 unreachable -> no restart"
run_case case_cap_reached                   "restart cap reached -> no restart, exit 2"
run_case case_synced_during_wait            "Synced during the wait -> no restart"
run_case case_cap_reached_site1_unreachable "cap reached but site 1 unreachable -> exit 0, no crit"
run_case case_old_restarts_ignored          "restarts older than 24h do not count"
run_case case_dry_run                       "DRY_RUN=1 -> logs, no restart, no history"
run_case case_stop_hangs                    "stop hangs -> SIGKILL, then start"
run_case case_stop_fails                    "stop fails at once -> reported as failure, not started"
run_case case_ss_fails                      "ss fails -> exit 1, no restart"
run_case case_mysqld_down                   "mysqld not queryable -> no restart"
run_case case_new_connection                "connection replaced by new one -> no restart"
run_case case_custom_service_name           "SERVICE_NAME=mysqld is honoured"
run_case case_lock_held                     "lock held by another run -> skip"
run_case case_lock_dir_missing              "lock file cannot be opened -> exit 1"
run_case case_missing_credentials           "missing credentials file -> exit 1"

echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
