#!/bin/bash
# scripts/check-docs.sh

set -euo pipefail

REPORT_DIR="docs-link-reports"
TODAY=$(date +"%Y-%m-%d")
RESULTS_FILE="$REPORT_DIR/latest-results.json"
PREVIOUS_FILE="$REPORT_DIR/previous-results.json"
HISTORY_DIR="$REPORT_DIR/history"

mkdir -p "$REPORT_DIR" "$HISTORY_DIR"

# Rotate: current latest becomes previous
if [[ -f "$RESULTS_FILE" ]]; then
  cp "$RESULTS_FILE" "$PREVIOUS_FILE"
fi

# Sites to check
SITE_NAMES=(
  "Sui"
  "Walrus"
  "SuiNS"
  "Seal"
  "Move_Book"
  "SDKs"
)
SITE_URLS=(
  "https://docs.sui.io"
  "https://docs.wal.app"
  "https://docs.suins.io"
  "https://seal-docs.wal.app"
  "https://move-book.com"
  "https://sdk.mystenlabs.com/"
)

# Initialize today's results as a JSON object
echo '{}' > "$RESULTS_FILE"

check_site() {
  local name="$1"
  local url="$2"
  local safe_name
  safe_name=$(echo "$name" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
  local raw_output="$REPORT_DIR/${safe_name}_${TODAY}.txt"

  echo "::group::Checking $name ($url)"
  npx afdocs@0.6.0 check "$url" --max-links=750 > "$raw_output" 2>&1 || true

  # Extract a stable, comparable fingerprint: sorted broken links only.
  # Adjust this grep/sed to match afdocs output format.
  local fingerprint
  fingerprint=$(grep -E '^\s*(✖|BROKEN|ERR|404|fail)' "$raw_output" | sort || echo "NO_BROKEN_LINKS")

  # Store fingerprint hash + raw summary
  local hash
  hash=$(echo "$fingerprint" | sha256sum | awk '{print $1}')
  local summary
  summary=$(tail -5 "$raw_output" | head -c 500)

  # Write into results JSON
  local tmp
  tmp=$(mktemp)
  jq --arg name "$name" \
     --arg hash "$hash" \
     --arg summary "$summary" \
     --arg url "$url" \
     '.[$name] = {hash: $hash, summary: $summary, url: $url}' \
     "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"

  echo "::endgroup::"
}

# Run all checks
for i in "${!SITE_NAMES[@]}"; do
  check_site "${SITE_NAMES[$i]}" "${SITE_URLS[$i]}"
done

# Archive today's full results
cp "$RESULTS_FILE" "$HISTORY_DIR/results_${TODAY}.json"

# --- Compare against previous and build Slack report ---

build_slack_report() {
  local header="*Docs Link Check — ${TODAY}*\n"
  local body=""
  local has_fail=false

  for name in $(jq -r 'keys[]' "$RESULTS_FILE"); do
    local today_hash
    today_hash=$(jq -r --arg n "$name" '.[$n].hash' "$RESULTS_FILE")
    local url
    url=$(jq -r --arg n "$name" '.[$n].url' "$RESULTS_FILE")
    local summary
    summary=$(jq -r --arg n "$name" '.[$n].summary' "$RESULTS_FILE")

    local status="✅ PASS"

    if [[ -f "$PREVIOUS_FILE" ]]; then
      local prev_hash
      prev_hash=$(jq -r --arg n "$name" '.[$n].hash // "NONE"' "$PREVIOUS_FILE")
      if [[ "$today_hash" != "$prev_hash" ]]; then
        status="❌ FAIL (results changed)"
        has_fail=true
      fi
    else
      status="🆕 NEW (no previous baseline)"
    fi

    body+="${status}  *${name}* — ${url}\n"
    body+="\`\`\`${summary}\`\`\`\n"
  done

  local color="#36a64f"
  if [[ "$has_fail" == "true" ]]; then
    color="#e01e5a"
  fi

  echo "${header}${body}"
}

post_to_slack() {
  local message
  message=$(build_slack_report)

    if [[ -z "${SLACK_WEBHOOK:-}" ]]; then
    echo "SLACK_WEBHOOK not set, printing report to stdout:"
    echo -e "$message"
    return
  fi

  curl -sf -X POST "$SLACK_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg text "$message" '{text: $text}')"

  echo "Report posted to Slack."
}

post_to_slack

# Clean up raw daily outputs older than 30 days
find "$REPORT_DIR" -name "*_20*.txt" -mtime +30 -delete
find "$HISTORY_DIR" -name "*.json" -mtime +30 -delete