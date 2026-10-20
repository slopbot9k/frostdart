#!/usr/bin/env bash
# Runs a command and, if it fails, publishes the last lines of its output as
# a GitHub Actions error annotation. Annotations are readable through the
# public Checks API, so a failure can be diagnosed without downloading logs.
#
#   tool/ci_annotate.sh <title> <command> [args...]
set -uo pipefail

title=$1
shift
log=$(mktemp)
trap 'rm -f "$log"' EXIT

"$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if [ "$status" -ne 0 ]; then
  message=$(tail -n 60 "$log" \
    | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/%/%25/g; s/\r/%0D/g' \
    | awk '{ printf "%s%%0A", $0 }' | tail -c 3800)
  echo "::error title=${title}::${message}"
fi
exit "$status"
