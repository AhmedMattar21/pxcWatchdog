#!/usr/bin/env bash
#
# pxc-watchdog.sh - restart a Percona XtraDB Cluster node stuck in "Joining".
#
# Runs every 15 minutes from pxc-watchdog.timer, on the site 2 node only.
# If wsrep_local_state_comment is "Joining..." and no bytes arrive on the
# SST/IST ports (4444/4568) for WAIT_SECONDS, it restarts mysql. It restarts
# only if a site 1 node is reachable, and at most MAX_RESTARTS times in 24h.
# It never bootstraps and never touches pc.bootstrap.
#
# Exit codes: 0 nothing to do / transfer in progress / restart issued,
#             1 error, 2 node stuck but restart cap reached.

set -uo pipefail

# --- Settings (can be overridden in /etc/default/pxc-watchdog) -------------
SERVICE_NAME="${SERVICE_NAME:-mysql}"
DONOR_IPS="${DONOR_IPS:-10.0.1.11 10.0.1.12}"   # site 1 nodes, space separated
GCOMM_PORT="${GCOMM_PORT:-4567}"
WAIT_SECONDS="${WAIT_SECONDS:-180}"
MAX_RESTARTS="${MAX_RESTARTS:-4}"               # per rolling 24 hours
STOP_TIMEOUT="${STOP_TIMEOUT:-300}"             # then SIGKILL
MYSQL_DEFAULTS_FILE="${MYSQL_DEFAULTS_FILE:-/etc/pxc-watchdog/my.cnf}"
STATE_DIR="${STATE_DIR:-/var/lib/pxc-watchdog}"
LOCK_FILE="${LOCK_FILE:-/run/lock/pxc-watchdog.lock}"
DRY_RUN="${DRY_RUN:-0}"                         # 1 = log only, change nothing
# ---------------------------------------------------------------------------

HISTORY_FILE="$STATE_DIR/restarts"

log() {
    logger -t pxc-watchdog -p "daemon.$1" -- "$2"
    if [[ -t 2 ]]; then
        echo "$1: $2" >&2
    fi
}

# Prints wsrep_local_state_comment; fails if mysqld cannot be queried.
wsrep_state() {
    timeout 30 mysql --defaults-extra-file="$MYSQL_DEFAULTS_FILE" --connect-timeout=10 -N -B \
        -e "SHOW GLOBAL STATUS LIKE 'wsrep_local_state_comment'" | cut -f2
}

# Prints "<local> <peer> <bytes_received>" for each established connection on
# local ports 4444 (SST) and 4568 (IST). ss prints each socket on one line and
# its counters on the next; bytes_received is omitted while it is still 0.
transfer_sample() {
    ss -tinH state established '( sport = :4444 or sport = :4568 )' | awk '
        /^[^ \t]/ { if (key != "") print key, bytes; key = $(NF - 1) " " $NF; bytes = 0; next }
        { for (i = 1; i <= NF; i++) if ($i ~ /^bytes_received:/) bytes = substr($i, 16) }
        END { if (key != "") print key, bytes }
    ' | sort
}

# Prints the first site 1 node that accepts TCP on GCOMM_PORT.
reachable_site1_node() {
    local ip
    for ip in $DONOR_IPS; do
        if timeout 5 bash -c "exec 3<>/dev/tcp/$ip/$GCOMM_PORT" 2>/dev/null; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# Prints the restart timestamps from the last 24 hours.
recent_restarts() {
    local now
    now=$(date +%s)
    awk -v cutoff=$(( now - 86400 )) '$1 > cutoff' "$HISTORY_FILE" 2>/dev/null
}

main() {
    local state before after donor count

    if [[ ! -r $MYSQL_DEFAULTS_FILE ]]; then
        log err "cannot read credentials file $MYSQL_DEFAULTS_FILE"
        return 1
    fi

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log info "another run is still active; skipping"
        return 0
    fi

    if ! state=$(wsrep_state); then
        log warning "cannot query mysqld; nothing to do"
        return 0
    fi
    if [[ $state != Joining* ]]; then
        log info "state is '$state'; nothing to do"
        return 0
    fi

    before=$(transfer_sample)
    log notice "state is '$state'; checking transfer progress for ${WAIT_SECONDS}s"
    sleep "$WAIT_SECONDS"

    if ! state=$(wsrep_state); then
        log warning "cannot query mysqld; nothing to do"
        return 0
    fi
    if [[ $state != Joining* ]]; then
        log notice "state changed to '$state'; nothing to do"
        return 0
    fi
    after=$(transfer_sample)

    # bytes_received on a connection only grows, so a different sample means
    # data arrived or a new connection opened. An open connection whose count
    # did not move (e.g. a full Recv-Q) is not progress.
    if [[ -n $after && $after != "$before" ]]; then
        log notice "state transfer in progress (${after//$'\n'/, }); nothing to do"
        return 0
    fi
    if [[ -z $after ]]; then
        log warning "node stuck in '$state': no connection on ports 4444/4568"
    else
        log warning "node stuck in '$state': no bytes received in ${WAIT_SECONDS}s (${after//$'\n'/, })"
    fi

    if ! donor=$(reachable_site1_node); then
        log warning "no site 1 node ($DONOR_IPS) reachable on TCP $GCOMM_PORT; link is down, not restarting"
        return 0
    fi

    count=$(recent_restarts | wc -l)
    if (( count >= MAX_RESTARTS )); then
        log crit "RESTART CAP REACHED: $count restarts in the last 24h; NOT restarting $SERVICE_NAME. Manual intervention required."
        return 2
    fi

    if [[ $DRY_RUN == 1 ]]; then
        log notice "DRY_RUN: would restart $SERVICE_NAME ($donor is reachable)"
        return 0
    fi

    # Record the restart first, so it counts against the cap even if we crash.
    mkdir -p "$STATE_DIR"
    if ! { recent_restarts; date +%s; } >"$HISTORY_FILE.new" || ! mv -f "$HISTORY_FILE.new" "$HISTORY_FILE"; then
        log err "cannot write $HISTORY_FILE; not restarting without a working cap"
        return 1
    fi

    log warning "restarting $SERVICE_NAME ($donor is reachable; restart $(( count + 1 )) of $MAX_RESTARTS in 24h)"
    if ! timeout "$STOP_TIMEOUT" systemctl stop "$SERVICE_NAME"; then
        # timeout only kills the systemctl client: kill mysqld, then wait for
        # the stop job to finish.
        log err "stop did not finish in ${STOP_TIMEOUT}s; sending SIGKILL"
        systemctl kill -s SIGKILL "$SERVICE_NAME"
        if ! timeout 60 systemctl stop "$SERVICE_NAME"; then
            log crit "$SERVICE_NAME did not stop; not starting it. Manual intervention required."
            return 1
        fi
    fi
    # --no-block: the rejoin (IST/SST) can take a long time; don't wait for it.
    if ! systemctl start --no-block "$SERVICE_NAME"; then
        log crit "could not start $SERVICE_NAME. Manual intervention required."
        return 1
    fi
    log warning "$SERVICE_NAME start queued; the node will rejoin in the background"
}

main "$@"
