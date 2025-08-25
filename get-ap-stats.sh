#!/usr/bin/env bash

# interfaceName = "$1"
# echo "{\n\t\"Name\": \"wifi1\",\n\t\"time\": \"$(date)\",\n\t\"stats\": [" | tee "${interfaceName}_stats.json"

# mcaDumpStats = $(sshpass -p 14-Ubntcorp-admin ssh -o 'StrictHostKeyChecking no' -o 'UserKnownHostsFile /dev/null' admin@192.168.228.99 mca-dump)

# echo $mcaDumpStats | jq ".radio_table[].athstats | select(.name | contains('${interfaceName}')) | {cu_total, cu_self_rx, cu_self_tx, cu_interf}"

set -euo pipefail

NAME="wifi1"
OUT="wifi-stats.json"
INTERVAL=5

HOST="192.168.228.99"
USER="admin"
PASS="14-Ubntcorp-admin"

# Dependencies
for bin in jq sshpass ssh; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Error: '$bin' is required" >&2
        exit 1
    fi
done

# init output file
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true

# Always (re)initialize the file
RUN_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
tmp="$OUT.$$.init.tmp"
jq -n --arg name "$NAME" --arg date "$RUN_DATE" \
    '{name:$name, date:$date, stats:[]}' > "$tmp" && mv "$tmp" "$OUT"

echo "Collecting into: $OUT"
echo "Interface Name: $NAME | Host: $HOST | User: $USER Interval: ${INTERVAL}s"
echo "Press Ctrl+C to stop"

trap 'echo; echo "Stopping."; exit 0' INT TERM

# Function to get 1+ JSON samples
get_samples() {
    sshpass -p "$PASS" ssh \
        -o 'StrictHostKeyChecking=no' \
        -o 'UserKnownHostsFile=/dev/null' \
        "$USER@$HOST" mca-dump \
    | jq -c --arg w "$NAME" \
        '.radio_table[].athstats
        | select(.name | contains($w))
        | {cu_total, cu_self_rx, cu_self_tx, cu_interf}'
}

while :; do
    # Stream each JSON object (one per line) and append to stats
    appended=0
    get_samples | while IFS= read -r line; do
        # Validate JSON just in case
        echo "$line" | jq -e . >/dev/null 2>&1 || continue
        echo "$line"

        tmp="$OUT.$$.tmp"
        jq --argjson s "$line" '.stats += [$s]' "$OUT" > "$tmp" && mv "$tmp" "$OUT"
        appended=$((appended + 1))
        echo "$appended"
    done 

    # Warn if nothing matched this tick
    if [ "$appended" -eq 0 ]; then
        # Uncomment if you want a warning
        # echo "No matching samples at $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
        :
    fi

    sleep "$INTERVAL"
done

