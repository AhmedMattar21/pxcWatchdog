# pxcWatchdog

A systemd timer + script that restarts a Percona XtraDB Cluster (Galera) node
that is stuck in `Joining: receiving State Transfer`.

It is meant for the **site 2 node only** of a 2+1 cluster whose inter-site link
drops often. When the link comes back, that node sometimes stays in `Joining`
forever while `mysql.service` is still `active`. The watchdog detects this and
restarts the node, with guardrails so it never makes things worse.

## What it does

[FLOWCHART.md](FLOWCHART.md) shows every branch and exit code as a diagram.

Every 15 minutes (`pxc-watchdog.timer`):

1. Read `wsrep_local_state_comment` with `mysql` (`SHOW GLOBAL STATUS`). If
   mysqld cannot be queried, or the state does not start with `Joining` → do nothing.
2. Record `bytes_received` of each established socket on local ports 4444 (SST)
   and 4568 (IST) with `ss`, wait 3 minutes, re-check the state, record again.
   If `ss` itself fails, log an error and exit 1 without acting (a failed `ss`
   is never mistaken for "no connection").
   - The node left `Joining` during the wait → do nothing.
   - The two `ss` samples differ (a connection received bytes, or a new one
     opened) → transfer in progress, do nothing.
   - Otherwise (no connection, or the same connection with the same byte count,
     e.g. a full Recv-Q) → **stuck**.
3. When stuck:
   - If no site 1 node accepts TCP on 4567 → the link is still down, do nothing.
   - If 4 restarts already happened in the last 24 h → log at `crit` and exit 2
     (the service shows as failed). Manual intervention is needed.
   - Otherwise: record the restart, `systemctl stop mysql` (if the stop takes
     longer than 300 s or fails, SIGKILL via `systemctl kill` and wait up to
     60 s more for the stop; if mysql still has not stopped, exit 1 without
     starting it), then `systemctl start --no-block mysql`.

It never bootstraps, never sets `pc.bootstrap`, and never acts on a node that is
non-Primary but not Joining. A node stuck as non-Primary is left alone on purpose.

Exit codes: `0` nothing to do / transfer in progress / restart issued,
`1` error (credentials or lock file unusable, `ss` failed, restart history not
writable, stop or start failed), `2` restart cap reached.

## Requirements

bash ≥ 4.4, `mysql` client, `ss` (iproute2), systemd, `flock`, `logger`,
`timeout`. All ship with RHEL 8+/Ubuntu 18.04+ PXC servers.

## Install (site 2 node only)

```bash
sudo install -m 0755 pxc-watchdog.sh /usr/local/sbin/pxc-watchdog.sh
sudo install -m 0644 pxc-watchdog.service pxc-watchdog.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

### Configure

The settings are at the top of `/usr/local/sbin/pxc-watchdog.sh`. Rather than
editing the script, override them in `/etc/default/pxc-watchdog`. The service
loads that file if it exists, and it survives script upgrades.
[`pxc-watchdog.default`](pxc-watchdog.default) is a commented example with
every setting and its default. At minimum, set `DONOR_IPS` to the site 1 node
addresses:

```bash
sudo install -m 0644 pxc-watchdog.default /etc/default/pxc-watchdog
sudoedit /etc/default/pxc-watchdog
```

The file is read by systemd, not by bash: plain `KEY=VALUE` lines, quotes
around values with spaces, no `$VAR` expansion. Changes apply on the next timer
run. A manual run does not read it; pass settings on the command line instead
(see [Test with DRY_RUN=1](#test-with-dry_run1)).

| Setting | Default | Meaning |
| --- | --- | --- |
| `SERVICE_NAME` | `mysql` | systemd unit running mysqld |
| `DONOR_IPS` | `10.0.1.11 10.0.1.12` | site 1 nodes (space separated) |
| `GCOMM_PORT` | `4567` | port probed on site 1 nodes |
| `WAIT_SECONDS` | `180` | time between the two `ss` samples |
| `MAX_RESTARTS` | `4` | restarts allowed per rolling 24 h |
| `STOP_TIMEOUT` | `300` | seconds `systemctl stop` may take before SIGKILL |
| `MYSQL_DEFAULTS_FILE` | `/etc/pxc-watchdog/my.cnf` | client credentials |
| `STATE_DIR` | `/var/lib/pxc-watchdog` | restart history (persists across reboots) |
| `LOCK_FILE` | `/run/lock/pxc-watchdog.lock` | `flock` lock |
| `DRY_RUN` | `0` | `1` = log only, change nothing |

If you raise `WAIT_SECONDS` or `STOP_TIMEOUT`, also raise `TimeoutStartSec` in
`pxc-watchdog.service` (15 min) with `systemctl edit pxc-watchdog.service`. It
must stay above `WAIT_SECONDS + STOP_TIMEOUT` plus about 2 minutes (about
10 minutes with the defaults). Otherwise systemd could kill the script between
`stop` and `start` and leave mysql down.

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
command line.

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
| info | `state is 'Synced'; nothing to do` | healthy |
| notice | `state is 'Joining…'; checking transfer progress for 180s` | sampling started |
| notice | `state transfer in progress (…)` | bytes are flowing, left alone |
| warning | `node stuck in 'Joining…': …` | stuck, checks before restart follow |
| warning | `no site 1 node … reachable on TCP 4567; link is down, not restarting` | no restart |
| warning | `restarting mysql (… restart N of 4 in 24h)` | restart issued |
| crit | `RESTART CAP REACHED …` | stuck, link up, but no restarts left |
| err | `ss failed; cannot check transfer progress` | nothing done, exit 1 |
| err / crit | `stop did not finish …` / `… did not stop; not starting it` | hung stop; see exit code |

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
- **Progress is judged by network bytes only.** After an SST's data has arrived,
  `xtrabackup --prepare` runs with no socket open. This is safe because mysqld
  does not accept client connections during an SST, so the `mysql` query fails
  and the watchdog does nothing. If a setup did answer queries in that phase,
  a long prepare could be seen as stuck.
- If one transfer connection closes while another stays stuck in the same
  window, the samples differ and that run counts it as progress. The next run,
  15 minutes later, catches it.

## Tests

`tests/run-tests.sh` runs the real script against fake `mysql`, `ss`,
`systemctl` and `logger` binaries (`tests/mocks/`) placed first on
`PATH`, with `WAIT_SECONDS=1`. Site 1 reachability uses real TCP to a local
`python3` listener (python3 is needed for the tests only). Nothing on the host
is touched.

```bash
tests/run-tests.sh
```

Covered cases: Synced; Joining with bytes increasing; ESTAB connection with no
byte change; no connection; site 1 unreachable; restart cap reached (exit 2);
cap reached while site 1 is unreachable (exit 0, no `crit`); Synced during the
wait; restarts older than 24 h ignored; DRY_RUN; stop hangs → SIGKILL; stop
fails at once (not started, reported as a failure); `ss` fails (exit 1, no
restart); mysqld not queryable; connection replaced by a new one; custom
`SERVICE_NAME`; lock held; lock file cannot be opened; missing credentials.
