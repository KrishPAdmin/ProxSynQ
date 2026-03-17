#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:-}"
HOST="${2:-}"
REMOTE_BASE="${3:-/home/krishadmin/proxsyncq}"

usage() {
  echo "Usage: $0 {vm1|rpi} host [remote_repo_base]"
  exit 1
}

[[ -n "$ROLE" && -n "$HOST" ]] || usage

ssh "krishadmin@$HOST" "bash $REMOTE_BASE/scripts/export_host_backup.sh $ROLE $REMOTE_BASE/backup"
rsync -a "krishadmin@$HOST:$REMOTE_BASE/backup/$ROLE/" "$HOME/proxsyncq/backup/$ROLE/"
