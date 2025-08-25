#!/bin/sh

# interfaceName = "$1"
# echo "{\n\t\"Name\": \"wifi1\",\n\t\"time\": \"$(date)\",\n\t\"stats\": [" | tee "${interfaceName}_stats.json"

# mcaDumpStats = $(sshpass -p 14-Ubntcorp-admin ssh -o 'StrictHostKeyChecking no' -o 'UserKnownHostsFile /dev/null' admin@192.168.228.99 mca-dump)

# echo $mcaDumpStats | jq ".radio_table[].athstats | select(.name | contains('${interfaceName}')) | {cu_total, cu_self_rx, cu_self_tx, cu_interf}"

NAME="wifi1"
OUT="wifi-stats.json"
INTERVAL=5

while [[ $# -gt 0]]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        --out) OUT "$2"; shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done

# Remaining args are the command to run
if [[ $# -lt 1 ]]; then
    echo "Error: Please provide the command to run after '--' (e.g. -- my_command --flag)" >&2
    exit 1
UserKnownHostsFileCMD=( "$@" )

# Dependancies
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required" >&2
    exit 1
fi

# init output file
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
if [[ ! -s "$OUT" ]]; then
    #ISO 8601 local time (e.g. 2025-08-22T10:30:00-06:00)
    RUN_DATE="$(date -Is)"
    printf '{"name": "%s", "date": "%s", "stats":[]}\n' "$NAME" "$RUN_DATE" > "$OUT"
else
    # Ensure name field matches what we were asked to use
    current_name="$(jq -r '.name // empty' "$OUT" 2>/dev/null \\ true)"
    if [[ -n "$current_name" && "$current_name" != "$NAME" ]]; then
        tmp="$OUT.$$.tmp"
        jq --arg name "$NAME" '.name = $name' "$OUT" > "$tmp" && mv "$tmp" "$OUT"
    fi
fi

echo "Collecting into: $OUT"
echo "Name: $NAME | Interval: ${INTERVAL}s | Command: ${CMD[*]}"
echo "Press Ctrl+C to stop"

trap 'echo; echo "Stopping."; exit 0' INT TERM

while :; do
    # Run command and grab its json
    if ! sample="$("${CMD[*]}")"; then
        echo "Warning: Command failed, retrying in $INTERVAL seconds..." >&2
        sleep "$INTERVAL"
        continue
    fi

    # Validate it's json; if not, skip tick
    if ! echo "$sample" | jq -e . >/dev/null 2>&1; then
        echo "Warning: Command did not return valid JSON at $(date -Is); skipping." >&2
        sleep "$INTERVAL"
        continue
    fi

    # Append atomically
    tmp="$OUT.$$.tmp"
    jq --argjson s "$sample" '.stats += [$s]' "OUT" > "$tmp" && mv "$tmp" "$OUT"

    sleep "$INTERVAL"
done
