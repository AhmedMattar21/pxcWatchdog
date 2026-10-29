# pxcWatchdog

A systemd timer + script that restarts a Percona XtraDB Cluster (Galera) node
that is stuck in `Joining: receiving State Transfer`.

It is meant for the **site 2 node only** of a 2+1 cluster whose inter-site link
drops often. When the link comes back, that node sometimes stays in `Joining`
forever while `mysql.service` is still `active`. The watchdog detects this and
restarts the node, with guardrails so it never makes things worse.

## What it does

Every 15 minutes (`pxc-watchdog.timer`):

1. If `mysql.service` is not `active` (stopped, or `activating` during a long
   SST after a restart), or mysqld cannot be queried → do nothing.
2. Read `wsrep_local_state_comment`. If it does not start with `Joining` → do nothing.
3. Sample the bytes received on established sockets on local ports 4444 (SST)
   and 4568 (IST), wait 3 minutes, re-check the state, sample again.
   - The node left `Joining` during the wait → do nothing.
   - A transfer connection received more bytes → transfer in progress, do nothing.
   - No bytes arrived, but the SST helper (`wsrep_sst_*` started by mysqld, and
     its children) used ≥ 5 s of CPU → the SST is working locally (e.g.
     `xtrabackup --prepare` after the network part finished), do nothing.
   - Otherwise (no connection, or an open connection with no progress) → **stuck**.
4. When stuck:
   - If no site 1 node accepts TCP on 4567 → the link is still down, do nothing.
   - If 4 restarts already happened in the last 24 h → log at `crit` and exit 2
     (the service shows as failed). Manual intervention is needed.
   - Otherwise: `systemctl stop mysql` (SIGKILL via `systemctl kill` if the stop
     takes longer than 300 s), then `systemctl start --no-block mysql`.

It never bootstraps, never sets `pc.bootstrap`, and never acts on a node that is
non-Primary but not Joining. A node stuck as non-Primary is left alone on purpose.

Exit codes: `0` nothing to do / transfer in progress / restart issued,
`1` error (configuration, failed restart), `2` restart cap reached.

## Requirements

bash ≥ 4.4, `mysql` client, `ss` (iproute2), systemd, `flock`, `logger`,
`timeout`, `pgrep` (procps). All ship with RHEL 8+/Ubuntu 18.04+ PXC servers.

## Install (site 2 node only)

```bash
sudo install -m 0755 pxc-watchdog.sh /usr/local/sbin/pxc-watchdog.sh
sudo install -m 0644 pxc-watchdog.service pxc-watchdog.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

### Configure

The settings are at the top of `/usr/local/sbin/pxc-watchdog.sh`. At minimum,
set `DONOR_IPS` to the site 1 node addresses. You can edit the script, or
override any setting in `/etc/default/pxc-watchdog`. The service loads that
file if it exists, and it survives script upgrades:

```bash
sudo tee /etc/default/pxc-watchdog >/dev/null <<'EOF'
DONOR_IPS="10.0.1.11 10.0.1.12"
SERVICE_NAME=mysql
EOF
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `SERVICE_NAME` | `mysql` | systemd unit running mysqld |
| `DONOR_IPS` | `10.0.1.11 10.0.1.12` | site 1 nodes (space separated) |
| `GCOMM_PORT` | `4567` | port probed on site 1 nodes |
| `TRANSFER_PORTS` | `4444 4568` | local SST/IST ports sampled with `ss` |
| `WAIT_SECONDS` | `180` | time between the two samples |
| `MAX_RESTARTS` / `RESTART_WINDOW_SECONDS` | `4` / `86400` | restart cap |
| `STOP_TIMEOUT` / `KILL_WAIT_SECONDS` | `300` / `60` | stop timeout before SIGKILL, wait after it |
| `SST_MIN_CPU_SECONDS` | `5` | CPU the SST helper must use in the window to count as "working" |
| `MYSQL_DEFAULTS_FILE` | `/etc/pxc-watchdog/my.cnf` | client credentials |
| `STATE_DIR` | `/var/lib/pxc-watchdog` | restart history (persists across reboots) |
| `LOCK_FILE` | `/run/lock/pxc-watchdog.lock` | `flock` lock |
| `WATCHDOG_UNIT` | `pxc-watchdog.service` | unit whose `TimeoutStartSec` the run-time check reads |
| `DRY_RUN` | `0` | `1` = log only, change nothing |

The script's worst-case run time must fit in `TimeoutStartSec` of
`pxc-watchdog.service` (15 min). Otherwise systemd could kill it between
`stop` and `start` and leave mysql down. The worst case is
`2*MYSQL_TIMEOUT + WAIT_SECONDS + TCP_TIMEOUT * (number of DONOR_IPS) +
STOP_TIMEOUT + 10 + KILL_WAIT_SECONDS + 30`, which is 630 s with the defaults.
When run by the timer, the script checks this at startup. If the worst case
does not fit, it logs an `err` and exits 1 without touching anything, so raise
`TimeoutStartSec` (`systemctl edit pxc-watchdog.service`) when you raise the
timeouts. Runs by hand are not limited.

### MySQL user (USAGE only)

`SHOW GLOBAL STATUS` needs no privileges, so the user gets nothing beyond
`USAGE`. Create it on a **Synced site 1 node**. It replicates to site 2 like
any other DDL:

```sql
CREATE USER 'pxc_watchdog'@'localhost' IDENTIFIED BY 'change-me';
GRANT USAGE ON *.* TO 'pxc_watchdog'@'localhost';
```

### Credentials file

```bash
sudo install -d -m 0700 /etc/pxc-watchdog
sudo tee /etc/pxc-watchdog/my.cnf >/dev/null <<'EOF'
[client]
user=pxc_watchdog
password=change-me
# RHEL: /var/lib/mysql/mysql.sock   Ubuntu/Debian: /var/run/mysqld/mysqld.sock
socket=/var/lib/mysql/mysql.sock
EOF
sudo chown root:root /etc/pxc-watchdog/my.cnf
sudo chmod 600 /etc/pxc-watchdog/my.cnf
```

The password is passed with `--defaults-extra-file` and never appears on a
command line. The script logs a warning if the file is readable by group or other.

Check it:

```bash
sudo mysql --defaults-extra-file=/etc/pxc-watchdog/my.cnf -e "SHOW GLOBAL STATUS LIKE 'wsrep_local_state_comment'"
```

## Test with DRY_RUN=1

Run it by hand before enabling the timer. With `DRY_RUN=1` it goes through all
checks, logs what it would do, and does not stop or start anything or write the
restart history:

```bash
sudo DRY_RUN=1 /usr/local/sbin/pxc-watchdog.sh
# shorter wait while experimenting:
sudo DRY_RUN=1 WAIT_SECONDS=20 /usr/local/sbin/pxc-watchdog.sh
echo "exit code: $?"
```

When run from a terminal, log lines are also printed to stderr.

To dry-run through systemd for a while, add `DRY_RUN=1` to
`/etc/default/pxc-watchdog`, enable the timer, and remove the line once the
logs look right.

## Enable the timer

```bash
sudo systemctl enable --now pxc-watchdog.timer
systemctl list-timers pxc-watchdog.timer
```

The first run happens 15 minutes after boot, or right away if the machine has
been up longer than that. After that, it runs 15 minutes after each previous
run finishes. A manual run and a timer run never overlap because of `flock`.

## Logs

Everything goes to the journal with the tag `pxc-watchdog`:

```bash
journalctl -t pxc-watchdog                    # all messages
journalctl -t pxc-watchdog -f                 # follow
journalctl -t pxc-watchdog --since "-1 day"   # last 24 h
journalctl -t pxc-watchdog -p warning         # stuck detections, restarts, errors
journalctl -t pxc-watchdog -p crit            # restart cap reached / restart failed
journalctl -u pxc-watchdog.service            # unit runs and exit codes
systemctl status pxc-watchdog.service         # "failed" after an exit code 2
cat /var/lib/pxc-watchdog/restarts            # restart timestamps (epoch)
```

Typical messages:

| Priority | Message | Meaning |
| --- | --- | --- |
| info | `wsrep_local_state_comment='Synced'; nothing to do` | healthy |
| notice | `node is 'Joining…'; re-checking in 180s` | sampling started |
| notice | `state transfer in progress (…)` | bytes are flowing, left alone |
| warning | `node stuck in 'Joining…': …` | stuck, checks before restart follow |
| warning | `no site 1 node … reachable on TCP 4567` | link still down, no restart |
| warning | `restarting mysql (restart N of 4 …)` | restart issued |
| crit | `RESTART CAP REACHED …` | stuck, link up, but no restarts left |
| err | `config: worst-case run time is …` | timeouts do not fit `TimeoutStartSec`; nothing done |

To get alerted on exit code 2, add an `OnFailure=` unit to
`pxc-watchdog.service` or watch for `-p crit` messages from `pxc-watchdog`.

To reset the restart cap after fixing the problem by hand:
`sudo rm /var/lib/pxc-watchdog/restarts`.

## Limitations

- **4567 reachable does not mean the donor can reach us.** For SST/IST the donor
  connects *to* this node on 4444/4568. If only that direction is blocked
  (firewall/NAT), every restart ends stuck again. The cap limits this to 4
  restarts a day. Check inbound 4444/4568 from site 1 if you see repeated restarts.
- **SIGKILL during IST** usually turns the next join into a full SST over the WAN.
  That is why `STOP_TIMEOUT` defaults to a generous 300 s.
- An SST helper that is busy but not making progress (burning CPU in a loop)
  counts as progress, and the watchdog will not restart it. Only `wsrep_sst_*`
  processes started by the unit's mysqld are counted.
- The run-time check needs systemd ≥ 232 (`INVOCATION_ID`). On older systemd
  it is skipped, so keep `TimeoutStartSec` in step with the timeouts by hand.

## Tests

`tests/run-tests.sh` runs the real script against fake `mysql`, `ss`,
`systemctl`, `logger` and `pgrep` binaries (`tests/mocks/`) placed first on
`PATH`, with `WAIT_SECONDS=1`. Site 1 reachability uses real TCP to a local
`python3` listener (python3 is needed for the tests only). Nothing on the host
is touched.

```bash
tests/run-tests.sh
```

Covered cases: Synced; Joining with bytes increasing; ESTAB connection with no
byte change; no connection; site 1 unreachable; restart cap reached (exit 2);
cap reached while site 1 is unreachable (exit 0, no `crit`); Synced during the
wait; cap window rolling over; DRY_RUN; stop hangs → SIGKILL; mysqld not
queryable; unit activating; connection replaced by a new one; custom
`SERVICE_NAME`; busy vs idle SST helper; busy `wsrep_sst_` process outside
mysqld ignored; worst-case run time above / equal to `TimeoutStartSec`,
`infinity`, `0`, and runs by hand; lock held; missing credentials.
