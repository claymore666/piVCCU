#!/bin/bash
# Install or remove the HB-RF-ETH watchdog. Run as root from this directory
# or by path: ./install.sh [install|uninstall]
# DESTDIR=/some/dir copies the files below that prefix and skips systemctl
# (for a dry run).
set -eu

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dest=${DESTDIR:-}
sbin=$dest/usr/local/sbin
units=$dest/etc/systemd/system
defaults=$dest/etc/default

if [ -z "$dest" ] && [ "$(id -u)" -ne 0 ]; then
  echo "run as root" >&2
  exit 1
fi

ctl() {
  if [ -n "$dest" ]; then
    echo "DESTDIR set, skipping: systemctl $*"
  else
    systemctl "$@"
  fi
}

case ${1:-install} in
  install)
    install -d "$sbin" "$units" "$defaults"
    install -m 0755 "$here/hb-rf-eth-watchdog.sh" "$sbin/hb-rf-eth-watchdog.sh"
    install -m 0644 "$here/hb-rf-eth-watchdog.service" "$units/hb-rf-eth-watchdog.service"
    install -m 0644 "$here/hb-rf-eth-watchdog.timer" "$units/hb-rf-eth-watchdog.timer"
    if [ -e "$defaults/hb-rf-eth-watchdog" ]; then
      echo "keeping existing $defaults/hb-rf-eth-watchdog"
    else
      install -m 0644 "$here/hb-rf-eth-watchdog.default" "$defaults/hb-rf-eth-watchdog"
    fi
    ctl daemon-reload
    ctl enable --now hb-rf-eth-watchdog.timer
    echo "installed; follow it with: journalctl -u hb-rf-eth-watchdog.service -f"
    ;;
  uninstall)
    ctl disable --now hb-rf-eth-watchdog.timer || true
    ctl stop hb-rf-eth-watchdog.service || true
    ctl reset-failed hb-rf-eth-watchdog.service || true
    rm -f "$units/hb-rf-eth-watchdog.timer" "$units/hb-rf-eth-watchdog.service" "$sbin/hb-rf-eth-watchdog.sh"
    if [ -e "$defaults/hb-rf-eth-watchdog" ]; then
      if cmp -s "$here/hb-rf-eth-watchdog.default" "$defaults/hb-rf-eth-watchdog"; then
        rm -f "$defaults/hb-rf-eth-watchdog"
      else
        echo "keeping edited $defaults/hb-rf-eth-watchdog"
      fi
    fi
    ctl daemon-reload
    if [ -z "$dest" ]; then
      rm -rf /run/hb-rf-eth-watchdog
    fi
    echo "removed"
    ;;
  *)
    echo "usage: $0 [install|uninstall]" >&2
    exit 2
    ;;
esac
