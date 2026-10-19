#!/bin/sh
# Polls an environment until all three services report the expected version.
# The caller (Jenkins) enforces the overall timeout.
#
#   wait-for-version.sh <base-url> <version>
set -u
base_url="$1"
expected="$2"
interval=15

while :; do
  ready=0
  for path in /version.json /api/flights/version /api/bookings/version; do
    body=$(wget -q -T 5 -O - "${base_url}${path}" 2>/dev/null || true)
    if printf '%s' "$body" | grep -Eq "\"version\" *: *\"${expected}\""; then
      ready=$((ready + 1))
    fi
  done

  if [ "$ready" -eq 3 ]; then
    echo "All services at ${expected} on ${base_url}"
    exit 0
  fi
  echo "$(date -u +%H:%M:%S) ${ready}/3 services at ${expected}; checking again in ${interval}s"
  sleep "$interval"
done
