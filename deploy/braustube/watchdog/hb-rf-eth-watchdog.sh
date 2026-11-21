#!/bin/bash
# hb-rf-eth-watchdog: restart the debmatic stack when the hb_rf_eth driver
# reports "not connected" for a long time although the board answers ping.
#
# One tick per run (driven by hb-rf-eth-watchdog.timer). State lives in
# /run/hb-rf-eth-watchdog and is lost at boot on purpose. A board that does
# not answer ping is left alone: the driver reconnects a restarted board by
# itself (fork patch of the driver). Output goes to stdout, i.e. the journal.
#
# Three triggers, one restart path (act): the driver stays disconnected while
# the board answers; the driver reconnected with a fresh endpoint
# identifier, i.e. the board rebooted and reset its radio coprocessor, which
# the host stack never learns of (trigger A); the link is up but most
# HmIP devices stay UNREACH (trigger B).
set -eu

# Defaults; every one can be overridden in /etc/default/hb-rf-eth-watchdog.
DOWN_SECONDS=120       # is_connected must read 0 this long before any action
COOLDOWN_SECONDS=600   # minimum time between two actions
MAX_RESTARTS=2         # restarts allowed within WINDOW_SECONDS
WINDOW_SECONDS=3600
LOG_INTERVAL=300       # rate limit for repeated log lines of the same kind
REBOOT=no              # yes: reboot once MAX_RESTARTS did not help
RESTART_ON_FRESH_ID=yes  # trigger A: restart on a fresh-identifier reconnect; no: only log
HMIP_CHECK=yes         # trigger B: ask ReGa about HmIP devices; no: skip
HMIP_CHECK_INTERVAL=300  # at most one ReGa query per this many seconds
HMIP_DEAD_MIN=3        # HmIP-RF devices UNREACH at least this many ...
HMIP_DEAD_PERCENT=50   # ... and at least this percent of all of them: "dead"
HMIP_DEAD_SECONDS=900  # dead continuously this long before a restart
REGA_TIMEOUT=20        # seconds before the ReGa query is abandoned

CONFIG_FILE=${CONFIG_FILE:-/etc/default/hb-rf-eth-watchdog}
SYSFS_FILE=${SYSFS_FILE:-/sys/class/hb-rf-eth/hb-rf-eth/is_connected}
BOARD_FILE=${BOARD_FILE:-/etc/default/hb_rf_eth}
STATE_DIR=${STATE_DIR:-/run/hb-rf-eth-watchdog}
UNIT=debmatic.service
# Test hooks: WATCHDOG_NOW replaces the clock, REGA_CMD replaces the built-in
# tclsh query (a command whose output is parsed like the real one),
# BOOT_ID_FILE replaces the kernel's boot id.
REGA_CMD=${REGA_CMD:-}
BOOT_ID_FILE=${BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}
# Kernel text that marks a reconnect with a fresh endpoint identifier: the
# dev_warn at kernel/hb_rf_eth.c:496 ("%pI4 did not answer the stored endpoint
# identifier and accepted a fresh one, ..."). Change it here if the driver text changes.
FRESH_ID_MATCH='accepted a fresh one'

if [ -r "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  . "$CONFIG_FILE"
fi

log() { printf '%s\n' "$*"; }

for v in DOWN_SECONDS COOLDOWN_SECONDS MAX_RESTARTS WINDOW_SECONDS LOG_INTERVAL \
  HMIP_CHECK_INTERVAL HMIP_DEAD_MIN HMIP_DEAD_PERCENT HMIP_DEAD_SECONDS REGA_TIMEOUT; do
  case ${!v} in
    '' | *[!0-9]*) log "invalid $v='${!v}' in $CONFIG_FILE, expected a whole number"; exit 1 ;;
  esac
  # Base 10: a value written as 08 must not be read as an invalid octal number.
  printf -v "$v" '%s' "$((10#${!v}))"
done
for v in REBOOT RESTART_ON_FRESH_ID HMIP_CHECK; do
  case ${!v} in
    yes | no) ;;
    *) log "invalid $v='${!v}' in $CONFIG_FILE, expected yes or no"; exit 1 ;;
  esac
done

mkdir -p "$STATE_DIR"
now=${WATCHDOG_NOW:-$(date +%s)}

# is_epoch FILE: succeeds and sets $epoch when FILE holds a number not in the future.
is_epoch() {
  epoch=
  [ -f "$1" ] || return 1
  { read -r epoch < "$1"; } 2>/dev/null || return 1
  case $epoch in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$epoch" -le "$now" ]
}

# log_every KEY SECONDS MESSAGE: log MESSAGE unless the same KEY logged within SECONDS.
# A missing, non-numeric or future timestamp counts as due.
log_every() {
  local key=$1 interval=$2
  shift 2
  if is_epoch "$STATE_DIR/log_$key" && [ $((now - epoch)) -lt "$interval" ]; then
    return 0
  fi
  printf '%s\n' "$now" > "$STATE_DIR/log_$key"
  log "$*"
}

# Marks: down_since (driver down), hmip_dead_since (trigger B), fresh_pending
# (trigger A seen but not yet acted on). Any restart or reboot clears all three,
# so every clock starts from zero after an action.
clear_down_mark() { rm -f "$STATE_DIR/down_since"; }
clear_hmip_mark() { rm -f "$STATE_DIR/hmip_dead_since"; }
clear_marks() { rm -f "$STATE_DIR/down_since" "$STATE_DIR/hmip_dead_since" "$STATE_DIR/fresh_pending"; }

# act REASON: the one restart path of all triggers. Returns 0 after a restart or
# reboot, 1 when the cooldown holds it back, 2 when MAX_RESTARTS is used up and
# REBOOT=no. REASON is the start of the log line.
act() {
  local reason=$1 t kind last=0 restarts=0
  if [ -f "$STATE_DIR/actions" ]; then
    while read -r t kind; do
      case $t in
        '' | *[!0-9]*) continue ;;
      esac
      if [ "$t" -gt "$now" ]; then
        continue
      fi
      if [ "$t" -gt "$last" ]; then
        last=$t
      fi
      if [ "$kind" = restart ] && [ $((now - t)) -lt "$WINDOW_SECONDS" ]; then
        restarts=$((restarts + 1))
      fi
    done < "$STATE_DIR/actions"
  fi

  if [ "$last" -gt 0 ] && [ $((now - last)) -lt "$COOLDOWN_SECONDS" ]; then
    return 1
  fi

  if [ "$restarts" -lt "$MAX_RESTARTS" ]; then
    log "$reason: restarting $UNIT (restart $((restarts + 1)) of $MAX_RESTARTS within $WINDOW_SECONDS s)"
    printf '%s restart\n' "$now" >> "$STATE_DIR/actions"
    clear_marks
    if ! systemctl restart "$UNIT"; then
      log "systemctl restart $UNIT failed"
      exit 1
    fi
    # The restart re-initialises the stack, so it covers every fresh-identifier
    # line logged before it completed, including one that arrived during this
    # tick (after the kernel log was read, e.g. while ping ran) that no later
    # tick may act on again. The module reload that debmatic does on restart
    # connects without that warning (kernel/hb_rf_eth.c:541), so nothing else
    # would mask the stale line. Moving the cursor to the journal end is keyed
    # on journal position, not on tick order.
    anchor_kernel_cursor || true
    return 0
  fi

  if [ "$REBOOT" = yes ]; then
    log "$reason, $restarts restarts within $WINDOW_SECONDS s did not help: rebooting"
    printf '%s reboot\n' "$now" >> "$STATE_DIR/actions"
    clear_marks
    systemctl reboot
    return 0
  fi

  log_every wouldreboot "$COOLDOWN_SECONDS" "$reason, $restarts restarts within $WINDOW_SECONDS s did not help: would reboot (REBOOT=no)"
  return 2
}

# New kernel messages since the previous tick, read on every tick before any
# early exit so that no line is ever replayed later. A missing cursor file means
# first tick since boot: journalctl would print the whole boot, so the output
# is dropped and only the cursor is kept (anchor_kernel_cursor).
# journalctl does not fail on every bad cursor. Measured with systemd 257: an
# empty file and a cursor of another boot make it print the whole current boot
# (exit 0), which would replay old fresh-identifier lines; a garbled or
# truncated cursor, or one from a vacuumed journal, makes it exit 1 and leave
# the file as it is, so every later tick would fail the same way. Both are
# handled alike: a cursor that is not of the current boot's format is not
# passed to journalctl, a failed read counts as unusable too, and the file is
# deleted and re-anchored at the journal end at once, without acting on
# anything. Lines logged between the unusable cursor and the re-anchor are
# lost; trigger B covers that.
anchor_kernel_cursor() {
  journalctl -k --cursor-file="$STATE_DIR/kernel.cursor" -q -o cat > /dev/null 2>&1
}

# cursor_usable: the cursor file holds one journal cursor of the current boot
# ("s=...;i=...;b=<boot id>;m=...", b= is the boot id without dashes).
cursor_usable() {
  local c b id
  { read -r c < "$STATE_DIR/kernel.cursor"; } 2> /dev/null || return 1
  case $c in
    s=*';i='*';b='*';m='*) ;;
    *) return 1 ;;
  esac
  b=${c#*';b='}
  b=${b%%';'*}
  if { read -r id < "$BOOT_ID_FILE"; } 2> /dev/null; then
    [ "$b" = "${id//-/}" ] || return 1
  fi
}

kmsg=
if [ -e "$STATE_DIR/kernel.cursor" ]; then
  if ! cursor_usable || ! kmsg=$(journalctl -k --cursor-file="$STATE_DIR/kernel.cursor" -q -o cat 2> /dev/null); then
    kmsg=
    rm -f "$STATE_DIR/kernel.cursor" || true
    anchor_kernel_cursor || true
    log_every journalctl "$LOG_INTERVAL" "journalctl -k failed or the kernel cursor is unusable, trigger A blind this tick"
  fi
elif ! anchor_kernel_cursor; then
  log_every journalctl "$LOG_INTERVAL" "journalctl -k failed, trigger A blind this tick"
fi
fresh_seen=no
case $kmsg in
  *"$FRESH_ID_MATCH"*) fresh_seen=yes ;;
esac

# Trigger A. Only called while is_connected reads 1 and the unit is active.
# Returns 0 when it restarted or rebooted.
trigger_fresh() {
  local rc=0
  if [ "$RESTART_ON_FRESH_ID" != yes ]; then
    rm -f "$STATE_DIR/fresh_pending"
    if [ "$fresh_seen" = yes ]; then
      log "kernel log: reconnect with a fresh endpoint identifier, board restarted; RESTART_ON_FRESH_ID=no, no action"
    fi
    return 1
  fi
  if [ "$fresh_seen" = yes ]; then
    printf '%s\n' "$now" > "$STATE_DIR/fresh_pending"
  fi
  is_epoch "$STATE_DIR/fresh_pending" || return 1
  act "trigger A, kernel log shows a reconnect with a fresh endpoint identifier (board restarted, radio coprocessor reset), link is up" || rc=$?
  case $rc in
    0) return 0 ;;
    1) # Cooldown: keep the mark, try again on the next tick.
      log_every freshwait "$LOG_INTERVAL" "trigger A pending, cooldown of $COOLDOWN_SECONDS s holds the restart back"
      ;;
    *) rm -f "$STATE_DIR/fresh_pending" ;;
  esac
  return 1
}

# rega_script returns a Tcl list (STDOUT, then every script variable), not
# plain text; measured on a live CCU, hence the array and $r(STDOUT).
# The ReGa query: one line "HMIP total=N unreach=M" over the HmIP-RF devices'
# maintenance channel (:0) UNREACH datapoint. Built-in version below; REGA_CMD
# replaces it for tests.
REGA_TCL='load tclrega.so
array set r [rega_script {
  integer total = 0;
  integer unreach = 0;
  string sDevId;
  foreach (sDevId, dom.GetObject(ID_DEVICES).EnumUsedIDs()) {
    object oDev = dom.GetObject(sDevId);
    object oIface = dom.GetObject(oDev.Interface());
    if ((oIface != null) && (oIface.Name() == "HmIP-RF")) {
      string sChId;
      foreach (sChId, oDev.Channels()) {
        object oCh = dom.GetObject(sChId);
        if (oCh.ChnNumber() == 0) {
          object oDp = oCh.DPByHssDP("UNREACH");
          if (oDp != null) {
            total = total + 1;
            if (oDp.Value() == true) {
              unreach = unreach + 1;
            }
          }
        }
      }
    }
  }
  WriteLine("HMIP total=" # total # " unreach=" # unreach);
}]
puts $r(STDOUT)'

# rega_counts: sets $total and $unreach, or returns 1 (error, timeout, unparsable).
rega_counts() {
  local out line argv
  total=''
  unreach=''
  if [ -n "$REGA_CMD" ]; then
    read -ra argv <<< "$REGA_CMD"
    out=$(timeout "$REGA_TIMEOUT" "${argv[@]}" 2> /dev/null) || return 1
  else
    out=$(printf '%s\n' "$REGA_TCL" | timeout "$REGA_TIMEOUT" tclsh 2> /dev/null) || return 1
  fi
  while read -r line; do
    line=${line%$'\r'}
    case $line in
      'HMIP total='*' unreach='*)
        total=${line#HMIP total=}
        total=${total%% *}
        unreach=${line##* unreach=}
        case $total$unreach in
          *[!0-9]*) continue ;;
        esac
        [ -n "$total" ] && [ -n "$unreach" ] || continue
        total=$((10#$total))
        unreach=$((10#$unreach))
        [ "$unreach" -le "$total" ] && return 0
        ;;
    esac
  done <<< "$out"
  return 1
}

# Trigger B, backstop: link up, but HmIP devices stay UNREACH. Only called while
# is_connected reads 1 and the unit is active. After a restart the CCU keeps
# UNREACH set until each device reports, so the next checks still read "dead";
# the cooldown holds the second restart back and act() clears the dead-since
# mark, so HMIP_DEAD_SECONDS count from zero again. Returns 0 when it acted.
trigger_hmip() {
  local rc=0 dead_for
  if [ "$HMIP_CHECK" != yes ]; then
    clear_hmip_mark
    return 1
  fi
  if is_epoch "$STATE_DIR/hmip_checked" && [ $((now - epoch)) -lt "$HMIP_CHECK_INTERVAL" ]; then
    return 1
  fi
  printf '%s\n' "$now" > "$STATE_DIR/hmip_checked"
  if ! rega_counts; then
    # Dead-since mark stays as it is: an unreadable answer proves nothing.
    log_every regafail "$LOG_INTERVAL" "HmIP check: ReGa query failed, timed out or gave no counts, no action"
    return 1
  fi
  if [ "$unreach" -lt "$HMIP_DEAD_MIN" ] || [ $((unreach * 100)) -lt $((HMIP_DEAD_PERCENT * total)) ]; then
    if is_epoch "$STATE_DIR/hmip_dead_since"; then
      log "HmIP devices reachable again ($unreach of $total UNREACH)"
    fi
    clear_hmip_mark
    return 1
  fi
  if ! is_epoch "$STATE_DIR/hmip_dead_since"; then
    printf '%s\n' "$now" > "$STATE_DIR/hmip_dead_since"
    epoch=$now
  fi
  dead_for=$((now - epoch))
  if [ "$dead_for" -lt "$HMIP_DEAD_SECONDS" ]; then
    return 1
  fi
  act "trigger B, $unreach of $total HmIP-RF devices UNREACH for $dead_for s while the link is up" || rc=$?
  [ "$rc" -eq 0 ]
}

# 1. No driver sysfs file: module not loaded or being reloaded.
if [ ! -r "$SYSFS_FILE" ]; then
  clear_marks
  exit 0
fi

# 2. Operator stop or boot in progress: not our business.
state=$(systemctl is-active "$UNIT" || true)
if [ "$state" != active ]; then
  clear_marks
  exit 0
fi

value=
{ read -r value < "$SYSFS_FILE"; } 2>/dev/null || true

# 3. Connected: triggers A and B.
if [ "$value" = 1 ]; then
  if is_epoch "$STATE_DIR/down_since"; then
    log "connected again after $((now - epoch)) s"
  fi
  clear_down_mark
  if trigger_fresh; then
    exit 0
  fi
  trigger_hmip || true
  exit 0
fi

if [ "$value" != 0 ]; then
  clear_hmip_mark
  log_every badvalue "$LOG_INTERVAL" "unexpected is_connected value '$value', no action"
  exit 0
fi

# Trigger A needs a live link: while it is down the checks below own the case.
# A pending trigger A mark is dropped; a new line or the down path takes over.
clear_hmip_mark
rm -f "$STATE_DIR/fresh_pending"
if [ "$fresh_seen" = yes ]; then
  log "kernel log: reconnect with a fresh endpoint identifier seen while is_connected=0, ignored"
fi

# 4. Not connected: start or continue the clock.
if ! is_epoch "$STATE_DIR/down_since"; then
  printf '%s\n' "$now" > "$STATE_DIR/down_since"
  epoch=$now
fi
down=$((now - epoch))
if [ "$down" -le "$DOWN_SECONDS" ]; then
  exit 0
fi

# 5. Is the board up? Only a board that answers is the driver's fault.
addr=$(
  HB_RF_ETH_ADDRESS=
  if [ -r "$BOARD_FILE" ]; then
    # shellcheck source=/dev/null
    . "$BOARD_FILE" > /dev/null 2>&1 || true
  fi
  printf '%s' "${HB_RF_ETH_ADDRESS:-}"
)
case $addr in
  '' | [!A-Za-z0-9]* | *[!A-Za-z0-9.:-]*)
    log_every noaddr "$LOG_INTERVAL" "driver down for $down s, but no usable HB_RF_ETH_ADDRESS in $BOARD_FILE, no action"
    exit 0
    ;;
esac
if ! ping -c 3 -W 1 -q "$addr" > /dev/null 2>&1; then
  log_every noping "$LOG_INTERVAL" "driver down for $down s, board does not answer, leaving it to the driver"
  exit 0
fi

# 6. Board answers, driver down: act, but never in a loop.
act "driver down for $down s, board $addr answers" || true
exit 0
