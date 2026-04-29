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
  local json_output="$REPORT_DIR/${safe_name}_${TODAY}.json"

  echo "::group::Checking $name ($url)"
  npx afdocs@latest check "$url" --max-links=750 --format=json > "$json_output" 2>/dev/null || true

  # Bail out gracefully if the output isn't valid JSON
  if ! jq empty "$json_output" 2>/dev/null; then
    echo "Warning: $name produced invalid JSON, recording as error"
    local tmp
    tmp=$(mktemp)
    jq --arg name "$name" --arg url "$url" \
       '.[$name] = {url: $url, passed: 0, failed: 0, warnings: 0, skipped: 0, total: 0, failures: [], error: "invalid JSON output"}' \
       "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"
    echo "::endgroup::"
    return
  fi

  # Extract counts by status from the results array
  local passed failed warnings skipped total
  passed=$(jq  '[.results[]? | select(.status == "passed" or .status == "pass")] | length' "$json_output")
  failed=$(jq  '[.results[]? | select(.status == "failed" or .status == "fail")] | length' "$json_output")
  warnings=$(jq '[.results[]? | select(.status == "warning" or .status == "warn")] | length' "$json_output")
  skipped=$(jq '[.results[]? | select(.status == "skipped" or .status == "skip")] | length' "$json_output")
  total=$(jq  '[.results[]?] | length' "$json_output")

  # Extract failure details as a JSON array
  local failures
  failures=$(jq '[.results[]? | select(.status == "failed" or .status == "fail") | {
    name:    (.id // .name // .title // .rule // "unknown"),
    category: (.category // null),
    message: (.message // .error // "no details")
  }]' "$json_output")

  echo "  $name: $passed passed, $warnings warnings, $failed failed, $skipped skipped ($total total)"

  # Write into results JSON
  local tmp
  tmp=$(mktemp)
  jq --arg name "$name" \
     --arg url "$url" \
     --argjson passed "$passed" \
     --argjson failed "$failed" \
     --argjson warnings "$warnings" \
     --argjson skipped "$skipped" \
     --argjson total "$total" \
     --argjson failures "$failures" \
     '.[$name] = {url: $url, passed: $passed, failed: $failed, warnings: $warnings, skipped: $skipped, total: $total, failures: $failures}' \
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
  local nl=$'\n'
  local header="*Docs Link Check — ${TODAY}*${nl}${nl}"
  local body=""
  local has_fail=false

  for name in $(jq -r 'keys[]' "$RESULTS_FILE"); do
    local url passed failed warnings skipped total
    url=$(jq -r --arg n "$name" '.[$n].url' "$RESULTS_FILE")
    passed=$(jq -r --arg n "$name" '.[$n].passed' "$RESULTS_FILE")
    failed=$(jq -r --arg n "$name" '.[$n].failed' "$RESULTS_FILE")
    warnings=$(jq -r --arg n "$name" '.[$n].warnings' "$RESULTS_FILE")
    skipped=$(jq -r --arg n "$name" '.[$n].skipped' "$RESULTS_FILE")
    total=$(jq -r --arg n "$name" '.[$n].total' "$RESULTS_FILE")

    # Status is based on whether there are actual failures
    local status
    if [[ "$failed" -gt 0 ]]; then
      status="❌ FAIL"
      has_fail=true
    else
      status="✅ PASS"
    fi

    # Compare with previous run for trend info
    local change_note=""
    if [[ -f "$PREVIOUS_FILE" ]]; then
      local prev_failed
      prev_failed=$(jq -r --arg n "$name" '.[$n].failed // empty' "$PREVIOUS_FILE" 2>/dev/null || true)
      if [[ -n "$prev_failed" ]]; then
        if [[ "$failed" -gt "$prev_failed" ]]; then
          change_note=" (⬆ up from ${prev_failed})"
        elif [[ "$failed" -lt "$prev_failed" ]]; then
          change_note=" (⬇ down from ${prev_failed})"
        elif [[ "$failed" -gt 0 ]]; then
          change_note=" (unchanged)"
        fi
      fi
    fi

    body+="${status}  *${name}* — <${url}|link>${nl}"
    body+="      ${passed} passed | ${warnings} warnings | ${failed} failed${change_note} | ${skipped} skipped (${total} total)${nl}"

    # Include per-check failure details when there are failures
    if [[ "$failed" -gt 0 ]]; then
      local failure_lines
      failure_lines=$(jq -r --arg n "$name" '
        .[$n].failures[] |
        "• [\(.category // "general")] \(.name): \(.message)"
      ' "$RESULTS_FILE")
      body+="\`\`\`${failure_lines}\`\`\`${nl}"
    fi
    body+="${nl}"
  done

  printf '%s' "${header}${body}"
}

post_to_slack() {
  local message
  message=$(build_slack_report)
  if [[ -z "${SLACK_WEBHOOK:-}" ]]; then
    echo "SLACK_WEBHOOK not set, printing report to stdout:"
    printf '%s\n' "$message"
    return
  fi
  curl -sf -X POST "$SLACK_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg text "$message" '{text: $text}')"
  echo "Report posted to Slack."
}

post_to_slack

# Clean up raw daily outputs older than 30 days
find "$REPORT_DIR" -name "*_20*.json" -mtime +30 -delete
find "$HISTORY_DIR" -name "*.json" -mtime +30 -delete
