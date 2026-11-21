# braustube: patched pivccu-modules-dkms

This is the install note for the `braustube` patch set on top of
piVCCU. Commands run as root on the host that runs debmatic (the CCU
host). The board address in the examples is `192.0.2.44`; use the
`HB_RF_ETH_ADDRESS` from `/etc/default/hb_rf_eth` on your host.

## What the package changes

Package `pivccu-modules-dkms` `1.0.89+braustube1` is upstream 1.0.89
plus the braustube patch set, and its `hb_rf_eth` module reports version
`1.24+braustube1`. The patch lets the driver reconnect a board that
rebooted or went away (endpoint identifier 0 fallback after three failed
attempts, raw UART restart), fixes memory and locking defects in it,
rate limits its reconnect log lines, and makes `eq3_char_loop` return
`-EAGAIN` instead of `-EFAULT` on a full buffer.

The deb file `pivccu-modules-dkms-1.0.89+braustube1.deb` is not part of
this repository. Build it from the `braustube` branch with
`./create_modules_dkms.sh` in the repository root (it writes the deb to
the current directory) and copy it to the host.

## Install

First record what the host has now, before anything is installed:

```
dpkg-query -W -f '${Version}\n' pivccu-modules-dkms
modinfo -F version hb_rf_eth
```

Write both lines down, or redirect them into a file of your choice. They
are the rollback target (see Rollback): the repository does not keep
every version, and the upstream version the patch is based on is not
necessarily what the host had. If the first command already prints a
version with `+braustube` in it, a patched package is installed and you
have recorded it before; keep that earlier record and do not make a new
one.

```
apt install ./pivccu-modules-dkms-1.0.89+braustube1.deb
apt-mark hold pivccu-modules-dkms
systemctl restart debmatic.service
```

- The `./` is required, otherwise apt looks for a package of that name
  in the repositories.
- The install builds the kernel modules with DKMS for the running
  kernel and takes a minute or two.
- The restart is needed: the old module stays loaded until
  `debmatic.service` stops (its `ExecStopPost` unloads `hb_rf_eth`) and
  starts again. Restarting it restarts every debmatic service, so
  expect the CCU to be unavailable for a few minutes.
- The hold keeps an upstream `pivccu-modules-dkms` from silently
  replacing the patched package. If a debmatic update ever needs a newer
  modules package, apt reports the held package instead of upgrading it.

## Verify

```
dpkg-query -W pivccu-modules-dkms
modinfo -F version hb_rf_eth
cat /sys/module/hb_rf_eth/version
apt-mark showhold
cat /sys/class/hb-rf-eth/hb-rf-eth/is_connected
dmesg | grep -i hb-rf-eth
```

Expect:

- `dpkg-query` prints `pivccu-modules-dkms` and `1.0.89+braustube1`.
- `modinfo` (the module on disk) and `/sys/module/hb_rf_eth/version`
  (the loaded module) both print `1.24+braustube1`. If only the first
  one does, debmatic was not restarted.
- `apt-mark showhold` lists `pivccu-modules-dkms`.
- `is_connected` prints `1`.
- `dmesg` shows `Trying to connect to 192.0.2.44` followed by
  `Successfully connected to 192.0.2.44` (the device name
  `hb-rf-eth` precedes each line). When the connection is lost later:
  `Did not receive any packet in the last 5 seconds, terminating
  connection.`, then `Trying to reconnect to 192.0.2.44 (attempt N)`,
  then `Successfully connected to 192.0.2.44`. After a board reboot the
  line `... accepted a fresh one, the board was probably restarted` also
  appears. Repeated reconnect and timeout lines are limited to one per
  30 seconds each, the attempt number tells how many happened.

## Watchdog

The watchdog restarts `debmatic.service` (the CCU stack: multimacd, rfd,
hmserver) in three cases. All three go through the same restart path:
at least 600 seconds between actions, at most two restarts per hour, and
it never reboots unless you switch that on.

1. Driver down. `is_connected` has read 0 for more than 120 seconds
   although the board answers ping, which means the board is up and the
   driver is stuck. A board that does not answer is left to the driver.
2. Trigger A, board restarted. The kernel log shows that the driver
   reconnected with a fresh endpoint identifier (`... accepted a fresh
   one, the board was probably restarted`) and `is_connected` reads 1.
   A board that restarts resets its radio coprocessor; the CCU stack is
   not told and stays out of sync with it, so every HmIP device turns
   UNREACH although the link is up again. A restart of the stack fixes
   that. The watchdog reads the kernel log once per tick; the first tick
   after boot only marks the position, so a line from boot time is never
   acted on. A line that arrives inside the cooldown is kept and acted on
   when the cooldown ends; one that arrives while `is_connected` reads 0
   is ignored (case 1 covers it). The text it looks for is in one
   variable, `FRESH_ID_MATCH`, at the top of the script.
3. Trigger B, HmIP dead with the link up (backstop for anything trigger
   A cannot see). While `is_connected` reads 1 and `debmatic.service` is
   active, at most every 300 seconds the watchdog asks ReGa (with
   `tclsh` and `tclrega.so`, the way debmatic's own scripts do) how many
   HmIP-RF devices have `UNREACH` set on their `:0` channel. When at
   least 3 devices and at least 50 percent of all of them are UNREACH
   for 900 seconds without interruption, it restarts the stack. A ReGa
   error, a timeout (20 seconds) or an unreadable answer is logged and
   changes nothing, the dead-since mark stays as it was. After a restart
   the CCU keeps UNREACH set until a device reports again, so the
   cooldown is what holds a second restart back in the first minutes,
   and the 900 seconds start from zero.

Install (the files are in `deploy/braustube/watchdog/` of the
repository; copy that directory to the host):

```
cd watchdog
./install.sh
```

The installer copies the script to `/usr/local/sbin/`, the service and
timer to `/etc/systemd/system/`, and `/etc/default/hb-rf-eth-watchdog`
only if it does not exist yet, then enables and starts
`hb-rf-eth-watchdog.timer`. Running it again is harmless. The timer
starts five minutes after boot and then runs every 30 seconds.

Read it:

```
systemctl list-timers hb-rf-eth-watchdog.timer
journalctl -u hb-rf-eth-watchdog.service -f
```

systemd logs a start and a finish line per run;
`journalctl -t hb-rf-eth-watchdog.sh` shows only the script's own lines.
The script prints a line only when something happens: `connected again after N s`,
`restarting debmatic.service` (the line starts with the reason: `driver
down for N s`, `trigger A`, `trigger B, N of M HmIP-RF devices UNREACH`),
`board does not answer, leaving it to the driver`, `would reboot`,
`HmIP check: ReGa query failed` and `HmIP devices reachable again`. State
is kept in `/run/hb-rf-eth-watchdog/` and is lost at boot on purpose.

Settings are in `/etc/default/hb-rf-eth-watchdog`; every value is
there, commented out, with its default. The file is read on every run,
no restart is needed. `REBOOT=yes` makes the watchdog reboot the machine
when two restarts within an hour did not bring the driver back; the
default `REBOOT=no` only logs `would reboot`.

The settings of the two newer triggers: `RESTART_ON_FRESH_ID` (`yes`;
`no` only logs trigger A), `HMIP_CHECK` (`yes`; `no` never asks ReGa),
`HMIP_CHECK_INTERVAL` (300 s), `HMIP_DEAD_MIN` (3), `HMIP_DEAD_PERCENT`
(50), `HMIP_DEAD_SECONDS` (900), `REGA_TIMEOUT` (20 s). An existing host
needs no change: the installer keeps an edited default file, and every
default also lives in the script, so a file without the new keys gets the
new behaviour as soon as the new script is copied. Copy the new keys from
`hb-rf-eth-watchdog.default` into the file only to change them.

Run the tests (no root, no board, no dependencies beyond bash; the
script runs against stubs of `systemctl`, `journalctl`, `ping` and the
ReGa query):

```
watchdog/test/run-tests.sh
```

It prints one line per case and exits non-zero when any case fails. It
does not show that the real `journalctl`, `tclsh` and ReGa behave as the
stubs assume; test plan step 5 does.

Turn it off for a while, or for good:

```
systemctl disable --now hb-rf-eth-watchdog.timer
./install.sh uninstall
```

`uninstall` removes the script, the units and the default file; an
edited default file is kept.

## Rollback

The target is the package version you recorded before the install, not
a fixed number. See which versions the repository offers:

```
apt-cache policy pivccu-modules-dkms
```

Then, with the recorded version in place of `<recorded version>`:

```
apt-mark unhold pivccu-modules-dkms
apt install --allow-downgrades pivccu-modules-dkms=<recorded version>
systemctl restart debmatic.service
```

`--allow-downgrades` is needed because a version older than
`1.0.89+braustube1`, and `1.0.89` itself, sorts before it. If the
recorded version is not in the `apt-cache policy` list, the repository
no longer offers it; pick one of the offered versions, and expect the
module version to differ from the recorded one. Run the Verify commands
again: `modinfo -F version hb_rf_eth` should now print the module version
you recorded, and `dpkg-query` the recorded package version. Switch the
watchdog off as well if you roll back (`systemctl disable --now
hb-rf-eth-watchdog.timer`): it is meant for the patched driver.

## When upstream releases 1.0.90

In a clone of this repository, with the remote `upstream` pointing at
the piVCCU project:

```
git fetch upstream
git checkout master
git merge --ff-only upstream/master
git checkout braustube
git rebase master          # or: git merge master
```

Resolve conflicts, then:

1. In `create_modules_dkms.sh` keep the `+braustube1` suffix on
   `PKG_VERSION` (upstream changes `PKG_BUILD`). If the patch content
   changed since the last deb you installed, use `+braustube2`.
2. In `kernel/hb_rf_eth.c` the `MODULE_VERSION` is upstream's module
   version plus the same suffix, for example `1.25+braustube1` if
   upstream moved to 1.25.
3. Build: `./create_modules_dkms.sh` in the repository root. The result
   is `pivccu-modules-dkms-1.0.90+braustube1.deb` in the current
   directory.
4. Copy it to the host and repeat Install, with `apt-mark unhold` first
   and `apt-mark hold` again afterwards. Do not record the installed
   version again: it is the patched one, and the rollback target stays
   the version recorded before the first install. Update the two
   expected versions in the Automation list.

## Test plan

Run these by hand on the host after installing, once. Stop the watchdog
for tests 1 to 3 so the driver is tested alone, and start it again at
the end:

```
systemctl stop hb-rf-eth-watchdog.timer
# ... tests 1 to 3 ...
systemctl start hb-rf-eth-watchdog.timer
```

Set `BOARD=192.0.2.44` (your board address) in the shell first.

1. Block the board for 10 s and for 60 s. The driver must reconnect
   after the block ends. Within three failed attempts it uses the stored
   identifier, later ones use identifier 0 (the "fresh one" warning can
   appear even though the board did not reboot); either way the pass
   criterion is `is_connected` back to 1 and the devices answering.

   ```
   iptables -I INPUT -s $BOARD -j DROP
   iptables -I OUTPUT -d $BOARD -j DROP
   sleep 10
   iptables -D INPUT -s $BOARD -j DROP
   iptables -D OUTPUT -d $BOARD -j DROP
   sleep 5; cat /sys/class/hb-rf-eth/hb-rf-eth/is_connected
   dmesg | grep -i hb-rf-eth | tail
   ```

   Repeat with `sleep 60`.

2. Power-cycle the board (remove its power for a few seconds). The
   driver must reconnect by itself, without a module reload or a debmatic
   restart, and both HmIP and BidCos devices must answer afterwards.

   ```
   watch -n 2 cat /sys/class/hb-rf-eth/hb-rf-eth/is_connected
   dmesg | grep -i hb-rf-eth | tail -20
   ```

   Expect rising attempt numbers while the board boots, then the
   "fresh one" warning and `Successfully connected`. Then trigger a
   device (for example `get_value` or a switch from the CCU UI) and check
   that it reacts.

3. Memory must stay flat while the board is blocked for an hour:

   ```
   grep '^kmalloc-2k' /proc/slabinfo
   iptables -I INPUT -s $BOARD -j DROP
   iptables -I OUTPUT -d $BOARD -j DROP
   for i in $(seq 1 6); do sleep 600; grep '^kmalloc-2k' /proc/slabinfo; done
   iptables -D INPUT -s $BOARD -j DROP
   iptables -D OUTPUT -d $BOARD -j DROP
   ```

   The active object count (second column) must not grow from sample to
   sample. Check that the log is quiet too: `dmesg | grep -ic
   hb-rf-eth` before and after should differ by a handful of lines, not
   thousands.

4. Overnight soak with the watchdog running and the board connected:

   ```
   journalctl -k -b --no-pager | grep -ic hb-rf-eth
   journalctl -t hb-rf-eth-watchdog.sh --since yesterday
   ```

   Run the first command in the evening and again in the morning; the
   difference is the log line rate (expect nearly nothing on a healthy
   link). The second command lists only the lines the script itself
   printed (not systemd's start and finish lines), that is everything
   the watchdog did; on a healthy night it prints nothing but the
   `-- No entries --` marker.

5. Board restart with the watchdog running (trigger A). Needs the
   watchdog timer active and HmIP devices paired. Power-cycle the board
   (remove its power for a few seconds), do not touch the host. Expected
   within about ten minutes:

   ```
   journalctl -t hb-rf-eth-watchdog.sh --since -15min
   journalctl -k --since -15min | grep -i hb-rf-eth
   ```

   The kernel log shows the reconnect attempts, then `accepted a fresh
   one` and `Successfully connected`. The watchdog log shows, at the next
   tick (30 seconds at most) after the reconnect, `trigger A, kernel log
   shows a reconnect with a fresh endpoint identifier ...: restarting
   debmatic.service (restart 1 of 2 within 3600 s)`. If the board was
   off longer than the 120 seconds of case 1 and the driver was down
   meanwhile, the line may instead start with `driver down for`; that is
   fine, the point is exactly one restart. Afterwards
   `cat /sys/class/hb-rf-eth/hb-rf-eth/is_connected` reads 1 and the HmIP
   devices leave UNREACH within ten minutes. No second restart follows
   inside the 600 seconds cooldown.

   Once, check the trigger B query by hand on the host (it must print one
   line, `HMIP total=N unreach=M`, with N the number of HmIP-RF devices
   you have):

   ```
   systemctl stop hb-rf-eth-watchdog.timer
   sed -n "/^REGA_TCL='/,/^}\]'/p" /usr/local/sbin/hb-rf-eth-watchdog.sh \
     | sed "1s/^REGA_TCL='//; \$s/'\$//" | tclsh
   systemctl start hb-rf-eth-watchdog.timer
   ```

## Automation

The steps and assertions above as a flat list, for writing a playbook.
Variables: `deb_file` is `pivccu-modules-dkms-1.0.89+braustube1.deb`,
`module_version` is `1.24+braustube1`, `package_version` is
`1.0.89+braustube1`. `recorded_package_version` and
`recorded_module_version` are set by step 2 and kept between runs.

1. Copy `deb_file` to the host.
2. Record the pre-patch versions, before any install and only if
   `dpkg-query -W -f '${Version}' pivccu-modules-dkms` prints a version
   that does not contain `+braustube`: save that version as
   `recorded_package_version` and `modinfo -F version hb_rf_eth` as
   `recorded_module_version`, where they survive the run (a file on the
   host, or a fact on the controller). Otherwise leave the saved values
   alone: on a host that has the patched package, recording again would
   store the patched version as the rollback target. If the package is
   not installed, nothing is recorded and step 15 cannot run.
3. Install it with `apt install ./pivccu-modules-dkms-1.0.89+braustube1.deb`,
   only if the installed version is not `1.0.89+braustube1`.
4. Set the package state of `pivccu-modules-dkms` to `hold`
   (`apt-mark hold pivccu-modules-dkms`).
5. Assert `modinfo -F version hb_rf_eth` prints `1.24+braustube1`.
6. Assert `dpkg-query -W -f '${Version}' pivccu-modules-dkms` prints
   `1.0.89+braustube1`.
7. Restart `debmatic.service` when step 3 installed something, or when
   `/sys/module/hb_rf_eth/version` exists and does not contain
   `1.24+braustube1` (a run interrupted after the install leaves the old
   module loaded; steps 5 and 6 only read the disk). Do not restart
   otherwise.
8. Always assert, after any restart and on every run, that
   `/sys/module/hb_rf_eth/version` contains `1.24+braustube1` and that
   `/sys/class/hb-rf-eth/hb-rf-eth/is_connected` becomes `1` (retry for
   up to a few minutes).
9. Copy `watchdog/hb-rf-eth-watchdog.sh` to
   `/usr/local/sbin/hb-rf-eth-watchdog.sh`, mode 0755, owner root. This
   is also the whole update for hosts that already run the watchdog: the
   defaults of the newer triggers live in the script (nothing else to
   copy; `watchdog/test/` stays in the repository).
10. Copy `watchdog/hb-rf-eth-watchdog.service` and
    `watchdog/hb-rf-eth-watchdog.timer` to `/etc/systemd/system/`, mode
    0644.
11. Copy `watchdog/hb-rf-eth-watchdog.default` to
    `/etc/default/hb-rf-eth-watchdog`, mode 0644, only if the target does
    not exist (do not overwrite an edited file).
12. Run `systemctl daemon-reload` if step 10 changed a unit file.
13. Enable and start `hb-rf-eth-watchdog.timer`.
14. Assert `systemctl is-active hb-rf-eth-watchdog.timer` prints
    `active`.
15. Rollback, when requested: disable and stop the timer,
    `apt-mark unhold pivccu-modules-dkms`,
    `apt install --allow-downgrades pivccu-modules-dkms=<recorded_package_version>`,
    restart `debmatic.service`, assert `dpkg-query -W -f '${Version}'
    pivccu-modules-dkms` prints `recorded_package_version` and
    `modinfo -F version hb_rf_eth` prints `recorded_module_version`. If
    the repository no longer offers `recorded_package_version` the
    install fails; report that and stop.
