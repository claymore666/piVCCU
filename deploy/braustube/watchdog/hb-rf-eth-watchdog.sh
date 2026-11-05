#!/bin/bash
# hb-rf-eth-watchdog: restart the debmatic stack when the hb_rf_eth driver
# reports "not connected" for a long time although the board answers ping.
#
# One tick per run (driven by hb-rf-eth-watchdog.timer). State lives in
# /run/hb-rf-eth-watchdog and is lost at boot on purpose. A board that does
# not answer ping is left alone: the driver reconnects a restarted board by
# itself (fork patch WP-001). Output goes to stdout, i.e. the journal.
set -eu

# Defaults; every one can be overridden in /etc/default/hb-rf-eth-watchdog.
DOWN_SECONDS=120       # is_connected must read 0 this long before any action
COOLDOWN_SECONDS=600   # minimum time between two actions
MAX_RESTARTS=2         # restarts allowed within WINDOW_SECONDS
WINDOW_SECONDS=3600
LOG_INTERVAL=300       # rate limit for repeated log lines of the same kind
REBOOT=no              # yes: reboot once MAX_RESTARTS did not help

CONFIG_FILE=${CONFIG_FILE:-/etc/default/hb-rf-eth-watchdog}
SYSFS_FILE=${SYSFS_FILE:-/sys/class/hb-rf-eth/hb-rf-eth/is_connected}
BOARD_FILE=${BOARD_FILE:-/etc/default/hb_rf_eth}
STATE_DIR=${STATE_DIR:-/run/hb-rf-eth-watchdog}
UNIT=debmatic.service

if [ -r "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  . "$CONFIG_FILE"
fi

log() { printf '%s\n' "$*"; }

for v in DOWN_SECONDS COOLDOWN_SECONDS MAX_RESTARTS WINDOW_SECONDS LOG_INTERVAL; do
  case ${!v} in
    '' | *[!0-9]*) log "invalid $v='${!v}' in $CONFIG_FILE, expected a whole number"; exit 1 ;;
  esac
done
case $REBOOT in
  yes | no) ;;
  *) log "invalid REBOOT='$REBOOT' in $CONFIG_FILE, expected yes or no"; exit 1 ;;
esac

mkdir -p "$STATE_DIR"
now=$(date +%s)

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

clear_down_mark() { rm -f "$STATE_DIR/down_since"; }

# 1. No driver sysfs file: module not loaded or being reloaded.
if [ ! -r "$SYSFS_FILE" ]; then
  clear_down_mark
  exit 0
fi

# 2. Operator stop or boot in progress: not our business.
state=$(systemctl is-active "$UNIT" || true)
if [ "$state" != active ]; then
  clear_down_mark
  exit 0
fi

value=
{ read -r value < "$SYSFS_FILE"; } 2>/dev/null || true

# 3. Connected.
if [ "$value" = 1 ]; then
  if is_epoch "$STATE_DIR/down_since"; then
    log "connected again after $((now - epoch)) s"
  fi
  clear_down_mark
  exit 0
fi

if [ "$value" != 0 ]; then
  log_every badvalue "$LOG_INTERVAL" "unexpected is_connected value '$value', no action"
  exit 0
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
last=0
restarts=0
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
  exit 0
fi

if [ "$restarts" -lt "$MAX_RESTARTS" ]; then
  log "driver down for $down s, board $addr answers: restarting $UNIT (restart $((restarts + 1)) of $MAX_RESTARTS within $WINDOW_SECONDS s)"
  printf '%s restart\n' "$now" >> "$STATE_DIR/actions"
  clear_down_mark
  if ! systemctl restart "$UNIT"; then
    log "systemctl restart $UNIT failed"
    exit 1
  fi
  exit 0
fi

if [ "$REBOOT" = yes ]; then
  log "driver down for $down s, board $addr answers, $restarts restarts within $WINDOW_SECONDS s did not help: rebooting"
  printf '%s reboot\n' "$now" >> "$STATE_DIR/actions"
  clear_down_mark
  systemctl reboot
  exit 0
fi

log_every wouldreboot "$COOLDOWN_SECONDS" "driver down for $down s, board $addr answers, $restarts restarts within $WINDOW_SECONDS s did not help: would reboot (REBOOT=no)"
exit 0
