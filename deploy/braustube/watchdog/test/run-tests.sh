#!/bin/bash
# Tests for hb-rf-eth-watchdog.sh. Plain bash, no dependencies: the real script
# runs against stubs of systemctl, journalctl, ping and the ReGa query that are
# put first on PATH, with every file location and the clock overridden.
# One line per case; exit status 1 when any case failed.
#   ./run-tests.sh            run all cases
#   ./run-tests.sh PATTERN    run the cases whose name contains PATTERN
# The stubs model what the real tools are documented to do (journalctl: print
# everything after the cursor file's position, or everything when there is
# none, then store the new position). Whether the real tools behave so on a
# host is the live test plan's job (README, test plan step 5).
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$here/../hb-rf-eth-watchdog.sh
# The line the driver prints (kernel/hb_rf_eth.c, dev_warn after a reconnect with identifier 0).
FRESH_LINE='hb_rf_eth hb-rf-eth: 192.0.2.44 did not answer the stored endpoint identifier and accepted a fresh one, the board was probably restarted'

# ---- fixture ---------------------------------------------------------------

new_fixture() {
  T=$(mktemp -d)
  mkdir -p "$T/bin" "$T/state"
  : > "$T/klog"
  : > "$T/calls"
  : > "$T/out"
  : > "$T/config"
  echo 1 > "$T/sysfs"
  echo active > "$T/unit"
  echo 'HB_RF_ETH_ADDRESS=192.0.2.44' > "$T/board"
  cat > "$T/bin/systemctl" <<'STUB'
#!/bin/bash
case $1 in
  is-active) cat "$FX/unit" ;;
  restart) echo "restart $2" >> "$FX/calls" ;;
  reboot) echo reboot >> "$FX/calls" ;;
esac
STUB
  cat > "$T/bin/ping" <<'STUB'
#!/bin/bash
# ping_logs: the driver logs a fresh-identifier line while ping runs.
[ ! -e "$FX/ping_logs" ] || echo "$(cat "$FX/ping_logs")" >> "$FX/klog"
[ ! -e "$FX/noping" ]
STUB
  cat > "$T/bin/journalctl" <<'STUB'
#!/bin/bash
for a in "$@"; do
  case $a in --cursor-file=*) cf=${a#*=} ;; esac
done
[ ! -e "$FX/journalctl_fail" ] || exit 1
pos=0
[ -f "$cf" ] && read -r pos < "$cf"
tail -n +$((pos + 1)) "$FX/klog"
wc -l < "$FX/klog" > "$cf"
STUB
  cat > "$T/rega" <<'STUB'
#!/bin/bash
echo x >> "$FX/rega_calls"
[ ! -e "$FX/rega_hang" ] || sleep 5
[ ! -e "$FX/rega_fail" ] || exit 1
cat "$FX/rega_out"
STUB
  # tclsh stub for the built-in query: runs the real tclsh with a prelude that
  # fakes the CCU's load of tclrega.so and rega_script, which returns what the
  # real one returns: a Tcl list of STDOUT followed by the script's variables.
  cat > "$T/bin/tclsh" <<'STUB'
#!/bin/bash
{ cat "$FX/tcl_prelude"; cat; } | PATH=${PATH#"$FX/bin:"} tclsh
STUB
  chmod +x "$T/bin/"* "$T/rega"
  echo 'HMIP total=10 unreach=0' > "$T/rega_out"
}

# tick TIME: one run of the script at the fake time TIME.
tick() {
  FX=$T WATCHDOG_NOW=$1 PATH="$T/bin:$PATH" \
    SYSFS_FILE=$T/sysfs BOARD_FILE=$T/board CONFIG_FILE=$T/config STATE_DIR=$T/state \
    REGA_CMD=$([ -e "$T/use_tcl" ] || echo "$T/rega") bash "$script" >> "$T/out" 2>&1
  last_rc=$?
}

# Run the same, but export FX for the stubs.
export_fx() { export FX=$T; }

set_cfg() { echo "$1" >> "$T/config"; }
klog_add() { echo "$1" >> "$T/klog"; }
restarts() { grep -c '^restart' "$T/calls" || true; }
reboots() { grep -c '^reboot' "$T/calls" || true; }
rega_calls() { if [ -f "$T/rega_calls" ]; then grep -c x "$T/rega_calls"; else echo 0; fi; }
out_has() { grep -q -- "$1" "$T/out"; }

fail() { echo "  $*"; exit 1; }
want_restarts() { local n; n=$(restarts); [ "$n" = "$1" ] || fail "$2: expected $1 restarts, got $n"; }
want_out() { out_has "$1" || fail "expected output containing '$1', got: $(tr '\n' '|' < "$T/out")"; }
want_no_out() { ! out_has "$1" || fail "unexpected output '$1': $(tr '\n' '|' < "$T/out")"; }

# ---- WP-002 behaviour --------------------------------------------------------

case_down_path() {
  echo 0 > "$T/sysfs"
  tick 1000; tick 1100
  want_restarts 0 "down 100 s"
  tick 1121
  want_restarts 1 "down 121 s"
  want_out "driver down for 121 s, board 192.0.2.44 answers: restarting debmatic.service (restart 1 of 2 within 3600 s)"
  tick 1130; tick 1260
  want_restarts 1 "cooldown"
  tick 1800
  want_restarts 2 "after cooldown"
  tick 2500; tick 2650
  want_restarts 2 "restart limit"
  want_out "2 restarts within 3600 s did not help: would reboot (REBOOT=no)"
  [ "$(reboots)" = 0 ] || fail "rebooted with REBOOT=no"
}

case_down_path_reboot() {
  set_cfg REBOOT=yes
  echo 0 > "$T/sysfs"
  tick 1000; tick 1121; tick 1800; tick 1900; tick 2400
  want_restarts 2 "before escalation"
  [ "$(reboots)" = 0 ] || fail "rebooted too early"
  tick 3000; tick 3200
  [ "$(reboots)" = 1 ] || fail "expected one reboot, got $(reboots)"
}

case_down_board_silent() {
  echo 0 > "$T/sysfs"; touch "$T/noping"
  tick 1000; tick 1500; tick 5000
  want_restarts 0 "board does not answer"
  want_out "board does not answer, leaving it to the driver"
}

case_down_reconnect_clears() {
  echo 0 > "$T/sysfs"
  tick 1000; tick 1100
  echo 1 > "$T/sysfs"; tick 1110
  want_out "connected again after 110 s"
  echo 0 > "$T/sysfs"; tick 1120; tick 1200
  want_restarts 0 "clock restarts after reconnect"
}

# ---- trigger A ---------------------------------------------------------------

case_a_first_tick_silent() {
  klog_add "$FRESH_LINE"
  tick 1000
  want_restarts 0 "line from before the first tick"
  [ -e "$T/state/kernel.cursor" ] || fail "no cursor created on first tick"
  tick 1030
  want_restarts 0 "second tick, no new line"
}

case_a_fires_once_per_line() {
  tick 1000
  klog_add "$FRESH_LINE"
  tick 1030
  want_restarts 1 "new line"
  want_out "trigger A"
  tick 1060; tick 2000; tick 3000
  want_restarts 1 "same line must not act again"
  klog_add "other kernel noise"
  tick 4000
  want_restarts 1 "unrelated line"
  klog_add "$FRESH_LINE"
  tick 5000
  want_restarts 2 "second line"
}

case_a_ignored_when_down() {
  tick 1000
  echo 0 > "$T/sysfs"
  klog_add "$FRESH_LINE"
  tick 1030
  want_restarts 0 "line while is_connected=0"
  want_out "seen while is_connected=0, ignored"
  echo 1 > "$T/sysfs"
  tick 1060; tick 1090
  want_restarts 0 "line was consumed, not replayed"
}

case_a_ignored_when_unit_stopped() {
  tick 1000
  echo inactive > "$T/unit"
  klog_add "$FRESH_LINE"
  tick 1030
  echo active > "$T/unit"
  tick 1060
  want_restarts 0 "line seen while the unit was stopped"
}

case_a_log_only() {
  set_cfg RESTART_ON_FRESH_ID=no
  tick 1000
  klog_add "$FRESH_LINE"
  tick 1030; tick 1060
  want_restarts 0 "RESTART_ON_FRESH_ID=no"
  want_out "RESTART_ON_FRESH_ID=no, no action"
}

case_a_deferred_by_cooldown() {
  tick 1000
  klog_add "$FRESH_LINE"; tick 1030
  want_restarts 1 "first line"
  klog_add "$FRESH_LINE"; tick 1100
  want_restarts 1 "second line inside cooldown"
  tick 1500
  want_restarts 1 "still inside cooldown"
  tick 1700
  want_restarts 2 "pending line acts when cooldown ends"
  tick 2400
  want_restarts 2 "and only once"
}

case_a_restart_limit() {
  set_cfg REBOOT=yes
  tick 1000
  klog_add "$FRESH_LINE"; tick 1030
  klog_add "$FRESH_LINE"; tick 1700
  want_restarts 2 "two lines"
  klog_add "$FRESH_LINE"; tick 2400
  want_restarts 2 "limit reached"
  [ "$(reboots)" = 1 ] || fail "expected escalation to reboot, got $(reboots)"
}

case_a_limit_no_reboot() {
  tick 1000
  klog_add "$FRESH_LINE"; tick 1030
  klog_add "$FRESH_LINE"; tick 1700
  klog_add "$FRESH_LINE"; tick 2400
  want_restarts 2 "limit reached"
  want_out "would reboot (REBOOT=no)"
  tick 2430; tick 3000
  tick 4700
  want_restarts 2 "limit-blocked line is dropped, not retried once the window slides"
}

case_a_pending_dropped_when_down() {
  tick 1000
  klog_add "$FRESH_LINE"; tick 1030
  want_restarts 1 "first line"
  klog_add "$FRESH_LINE"; tick 1100
  echo 0 > "$T/sysfs"; tick 1130
  echo 1 > "$T/sysfs"; tick 1160
  tick 1700; tick 2400
  want_restarts 1 "pending line dropped when is_connected read 0"
}

case_a_line_during_down_path_restart() {
  # One board reboot, one restart: the tick read is_connected=0 and the kernel
  # log (empty), the driver reconnects while the down path pings, the restart
  # covers that line, no later tick may act on it.
  echo 0 > "$T/sysfs"
  tick 1000
  echo "$FRESH_LINE" > "$T/ping_logs"
  tick 1121
  want_restarts 1 "down path restart"
  rm "$T/ping_logs"
  echo 1 > "$T/sysfs"
  for t in 1151 1181 1500 1760 1800 2400; do tick "$t"; done
  want_restarts 1 "line logged before the restart completed"
}

case_a_journalctl_failure() {
  touch "$T/journalctl_fail"
  tick 1000
  want_out "journalctl -k failed"
  [ "$last_rc" = 0 ] || fail "tick must not fail, rc=$last_rc"
}

# ---- trigger B ---------------------------------------------------------------

dead() { echo "HMIP total=$1 unreach=$2" > "$T/rega_out"; }

case_b_below_threshold() {
  dead 4 2
  for t in 1000 1300 1600 1900 2200 5000; do tick "$t"; done
  want_restarts 0 "2 of 4 (below HMIP_DEAD_MIN)"
  dead 10 3
  for t in 6000 6300 6600 6900 7200 10000; do tick "$t"; done
  want_restarts 0 "3 of 10 (below HMIP_DEAD_PERCENT)"
  dead 0 0
  for t in 11000 11300 12000; do tick "$t"; done
  want_restarts 0 "no HmIP devices"
}

case_b_dead_too_short() {
  dead 6 4
  tick 1000; tick 1300; tick 1600
  want_restarts 0 "dead 600 s"
  tick 1899
  want_restarts 0 "dead 899 s (check skipped, interval 300 s)"
}

case_b_dead_long_enough() {
  dead 6 4
  tick 1000; tick 1300; tick 1600
  want_restarts 0 "before HMIP_DEAD_SECONDS"
  tick 1900
  want_restarts 1 "dead 900 s"
  want_out "trigger B, 4 of 6 HmIP-RF devices UNREACH for 900 s while the link is up: restarting debmatic.service"
  tick 1930
  want_restarts 1 "next tick"
}

case_b_clock_restarts_after_restart() {
  dead 6 4
  tick 1000; tick 1300; tick 1600; tick 1900
  want_restarts 1 "first restart"
  # UNREACH stays set after the restart; the mark starts again at the next check.
  tick 2200; tick 2500; tick 2800
  want_restarts 1 "600 s after the restart, mark restarted at 2200"
  tick 3100
  want_restarts 2 "900 s after the new mark"
}

case_b_cooldown_holds() {
  set_cfg COOLDOWN_SECONDS=2000
  dead 6 4
  tick 1000; tick 1300; tick 1600; tick 1900
  want_restarts 1 "first restart"
  tick 2200; tick 2500; tick 2800; tick 3100; tick 3400
  want_restarts 1 "dead long enough again but inside cooldown"
  tick 4000
  want_restarts 2 "cooldown over, still dead"
}

case_b_recovery_resets() {
  dead 6 4
  tick 1000; tick 1300
  dead 6 1
  tick 1600
  want_out "reachable again"
  dead 6 4
  tick 1900; tick 2200; tick 2500
  want_restarts 0 "dead again only 600 s"
  tick 2800
  want_restarts 1 "dead 900 s since the new mark"
}

case_b_rega_error_no_action() {
  touch "$T/rega_fail"
  for t in 1000 1300 1600 1900 2200 5000; do tick "$t"; done
  want_restarts 0 "ReGa error"
  want_out "ReGa query failed"
  [ "$last_rc" = 0 ] || fail "tick must not fail, rc=$last_rc"
}

case_b_rega_error_keeps_mark() {
  dead 6 4
  tick 1000
  touch "$T/rega_fail"
  tick 1300; tick 1600
  want_restarts 0 "errors"
  rm "$T/rega_fail"
  tick 1900
  want_restarts 1 "mark from 1000 survived the errors"
}

# The built-in query (REGA_CMD unset) against a tclsh whose rega_script returns
# the raw list the CCU returns; measured live: STDOUT {HMIP total=24 unreach=1
# } sessionId {} total 24 unreach 1 ...
case_b_builtin_query_list_format() {
  command -v tclsh > /dev/null || { echo "  skipped: no tclsh on this host"; return 0; }
  touch "$T/use_tcl"
  cat > "$T/tcl_prelude" <<'TCL'
proc load {args} {}
proc rega_script {script} {
  return [list STDOUT "HMIP total=6 unreach=4\n" sessionId {} httpUserAgent {} total 6 unreach 4 sDevId 1678 oDev {RPI-RF-MOD Serverraum} oIface HmIP-RF oDp null]
}
TCL
  tick 1000; tick 1300; tick 1600
  want_no_out "ReGa query failed"
  want_restarts 0 "before HMIP_DEAD_SECONDS"
  tick 1900
  want_restarts 1 "dead 900 s read through the built-in query"
  want_out "trigger B, 4 of 6 HmIP-RF devices UNREACH"
}

case_b_garbage_output() {
  echo 'not what we expect' > "$T/rega_out"
  for t in 1000 1300 1600 1900 5000; do tick "$t"; done
  want_restarts 0 "unparsable output"
  want_out "ReGa query failed"
  echo 'HMIP total=3 unreach=9' > "$T/rega_out"
  for t in 6000 6300 6600 6900 9000; do tick "$t"; done
  want_restarts 0 "more unreachable than devices"
}

case_b_timeout() {
  set_cfg REGA_TIMEOUT=1
  touch "$T/rega_hang"
  dead 6 4
  tick 1000
  want_out "ReGa query failed"
  want_restarts 0 "timeout"
}

case_b_interval() {
  dead 10 0
  tick 1000; tick 1030; tick 1060; tick 1299
  [ "$(rega_calls)" = 1 ] || fail "expected 1 query within 300 s, got $(rega_calls)"
  tick 1300
  [ "$(rega_calls)" = 2 ] || fail "expected 2nd query at 300 s, got $(rega_calls)"
}

case_b_disabled() {
  set_cfg HMIP_CHECK=no
  dead 6 6
  for t in 1000 1300 1600 1900 5000; do tick "$t"; done
  want_restarts 0 "HMIP_CHECK=no"
  [ "$(rega_calls)" = 0 ] || fail "ReGa asked although HMIP_CHECK=no"
}

case_b_not_asked_when_down_or_stopped() {
  dead 6 6
  echo 0 > "$T/sysfs"
  tick 1000; tick 1500
  echo inactive > "$T/unit"
  echo 1 > "$T/sysfs"
  tick 2000; tick 2500
  [ "$(rega_calls)" = 0 ] || fail "ReGa asked while link down or unit stopped"
}

case_b_mark_cleared_when_not_connected() {
  dead 6 6
  tick 1000; tick 1300; tick 1600
  echo 0 > "$T/sysfs"; tick 1700
  echo 1 > "$T/sysfs"
  tick 1900
  want_restarts 0 "dead time before a link drop does not count"
}

case_b_thresholds_configurable() {
  set_cfg HMIP_DEAD_MIN=1
  set_cfg HMIP_DEAD_PERCENT=08
  set_cfg HMIP_DEAD_SECONDS=300
  dead 10 1
  tick 1000
  tick 1299
  want_restarts 0 "dead 299 s"
  tick 1300
  want_restarts 1 "1 of 10 is 10 percent, over 08 (read as 8), dead 300 s"
}

# ---- shared path ---------------------------------------------------------------

case_shared_a_then_b() {
  set_cfg COOLDOWN_SECONDS=2000
  dead 6 4
  tick 1000; tick 1300; tick 1600
  klog_add "$FRESH_LINE"; tick 1650
  want_restarts 1 "A"
  tick 1900; tick 2200; tick 2500; tick 2800; tick 3100
  want_restarts 1 "B inside the cooldown that A started"
}

case_shared_b_then_a() {
  set_cfg COOLDOWN_SECONDS=2000
  dead 6 4
  tick 1000; tick 1300; tick 1600; tick 1900
  want_restarts 1 "B"
  klog_add "$FRESH_LINE"; tick 2000
  want_restarts 1 "A inside the cooldown that B started"
}

case_shared_limit() {
  dead 6 4
  tick 1000; tick 1300; tick 1600; tick 1900
  klog_add "$FRESH_LINE"; tick 2600
  want_restarts 2 "B then A"
  tick 2900; tick 3200; tick 3500; tick 3800; tick 4100; tick 4400; tick 5000
  want_restarts 2 "limit holds for B too"
  want_out "would reboot (REBOOT=no)"
}

case_shared_down_then_a() {
  echo 0 > "$T/sysfs"
  tick 1000; tick 1121
  want_restarts 1 "down path"
  echo 1 > "$T/sysfs"
  klog_add "$FRESH_LINE"; tick 1200
  want_restarts 1 "A inside the cooldown of the down path"
}

# ---- config ----------------------------------------------------------------------

case_bad_config() {
  set_cfg HMIP_DEAD_MIN=three
  tick 1000
  [ "$last_rc" = 1 ] || fail "expected exit 1, got $last_rc"
  want_out "invalid HMIP_DEAD_MIN"
  : > "$T/config"; set_cfg HMIP_CHECK=maybe
  tick 1000
  [ "$last_rc" = 1 ] || fail "expected exit 1 for HMIP_CHECK, got $last_rc"
}

case_no_sysfs() {
  rm "$T/sysfs"
  tick 1000; tick 1500
  want_restarts 0 "module not loaded"
  [ "$last_rc" = 0 ] || fail "rc=$last_rc"
}

# ---- runner ---------------------------------------------------------------------

pattern=${1:-}
total=0
failed=0
for fn in $(declare -F | awk '{print $3}' | grep '^case_'); do
  name=${fn#case_}
  case $name in *"$pattern"*) ;; *) continue ;; esac
  total=$((total + 1))
  new_fixture
  if msg=$(export FX=$T; set +e; "$fn" 2>&1); then
    printf 'ok   %s\n' "$name"
  else
    failed=$((failed + 1))
    printf 'FAIL %s\n%s\n' "$name" "$msg"
  fi
  rm -rf "${T:?}"
done
printf '%d cases, %d failed\n' "$total" "$failed"
[ "$failed" -eq 0 ]
