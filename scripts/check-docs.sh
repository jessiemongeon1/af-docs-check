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

# --- Skip configuration ---
# Checks skipped for all sites
GLOBAL_SKIP_CHECKS="auth-alternative-access,markdown-content-parity"

# Additional check skipped only for Walrus and Seal
WALRUS_SEAL_EXTRA_SKIP="content-negotiation"

# Human-readable reasons for skipped checks (used in reports)
skip_reason_for() {
  case "$1" in
    auth-alternative-access) echo "Docs do not require authentication" ;;
    markdown-content-parity) echo "Expected due to custom import content module" ;;
    content-negotiation)     echo "Markdown content negotiation not supported" ;;
    *)                       echo "Excluded from scoring" ;;
  esac
}

# Initialize today's results as a JSON object
echo '{}' > "$RESULTS_FILE"

check_site() {
  local name="$1"
  local url="$2"
  local safe_name
  safe_name=$(echo "$name" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
  local output_file="$REPORT_DIR/${safe_name}_${TODAY}.txt"

  # Build skip list for this site
  local skip_checks="$GLOBAL_SKIP_CHECKS"
  if [[ "$name" == "Walrus" || "$name" == "Seal" ]]; then
    skip_checks="${skip_checks},${WALRUS_SEAL_EXTRA_SKIP}"
  fi

  echo "::group::Checking $name ($url)"
  npx afdocs@latest check "$url" --max-links=750 --format scorecard --skip-checks "$skip_checks" > "$output_file" 2>/dev/null || true

  # Append skip reasons to the scorecard output
  {
    echo ""
    echo "Skipped Checks (by sui-docs-link-checker):"
    IFS=',' read -ra skip_arr <<< "$skip_checks"
    for check_id in "${skip_arr[@]}"; do
      echo "  - $check_id: $(skip_reason_for "$check_id")"
    done
  } >> "$output_file"

  # Bail out gracefully if the scorecard is missing
  if ! grep -q 'Overall Score' "$output_file" 2>/dev/null; then
    echo "Warning: $name produced no valid scorecard, recording as error"
    local tmp
    tmp=$(mktemp)
    jq --arg name "$name" --arg url "$url" \
       '.[$name] = {url: $url, score: null, grade: null, passed: 0, failed: 0, warnings: 0, skipped: 0, total: 0, failures: [], skipped_checks: [], error: "invalid scorecard output"}' \
       "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"
    echo "::endgroup::"
    return
  fi

  # Parse overall score and grade from scorecard
  local score grade
  score=$(sed -n 's/.*Overall Score: \([0-9]*\).*/\1/p' "$output_file")
  score="${score:-0}"
  grade=$(sed -n 's/.*Overall Score: [0-9]* \/ [0-9]* (\([^)]*\)).*/\1/p' "$output_file")
  grade="${grade:-?}"

  # Count check statuses
  local passed failed warnings skipped total
  passed=$(grep -c '^ *PASS ' "$output_file") || passed=0
  failed=$(grep -c '^ *FAIL ' "$output_file") || failed=0
  warnings=$(grep -c '^ *WARN ' "$output_file") || warnings=0
  skipped=$(grep -c '^ *SKIP ' "$output_file") || skipped=0
  total=$((passed + failed + warnings + skipped))

  # Extract failure details as JSON array
  local failures
  local fail_lines
  fail_lines=$(grep '^ *FAIL ' "$output_file" 2>/dev/null || true)
  if [[ -n "$fail_lines" ]]; then
    failures=$(echo "$fail_lines" | awk '{
      name = $2
      line = $0
      sub(/^ *FAIL +[^ ]+ +/, "", line)
      print name "\t" line
    }' | jq -R 'split("\t") | {name: .[0], message: .[1]}' | jq -s '.')
  else
    failures="[]"
  fi

  # Build skipped_checks JSON array with reasons
  local skipped_checks_json="[]"
  IFS=',' read -ra skip_arr <<< "$skip_checks"
  for check_id in "${skip_arr[@]}"; do
    local reason
    reason=$(skip_reason_for "$check_id")
    skipped_checks_json=$(echo "$skipped_checks_json" | jq \
      --arg name "$check_id" --arg reason "$reason" \
      '. + [{name: $name, reason: $reason}]')
  done

  echo "  $name: Score ${score}/100 (${grade}) — $passed passed, $warnings warnings, $failed failed, $skipped skipped ($total total)"

  # Write into results JSON
  local tmp
  tmp=$(mktemp)
  jq --arg name "$name" \
     --arg url "$url" \
     --argjson score "$score" \
     --arg grade "$grade" \
     --argjson passed "$passed" \
     --argjson failed "$failed" \
     --argjson warnings "$warnings" \
     --argjson skipped "$skipped" \
     --argjson total "$total" \
     --argjson failures "$failures" \
     --argjson skipped_checks "$skipped_checks_json" \
     '.[$name] = {url: $url, score: $score, grade: $grade, passed: $passed, failed: $failed, warnings: $warnings, skipped: $skipped, total: $total, failures: $failures, skipped_checks: $skipped_checks}' \
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

  for name in $(jq -r 'keys[]' "$RESULTS_FILE"); do
    local url score grade passed failed warnings skipped total
    url=$(jq -r --arg n "$name" '.[$n].url' "$RESULTS_FILE")
    score=$(jq -r --arg n "$name" '.[$n].score' "$RESULTS_FILE")
    grade=$(jq -r --arg n "$name" '.[$n].grade' "$RESULTS_FILE")
    passed=$(jq -r --arg n "$name" '.[$n].passed' "$RESULTS_FILE")
    failed=$(jq -r --arg n "$name" '.[$n].failed' "$RESULTS_FILE")
    warnings=$(jq -r --arg n "$name" '.[$n].warnings' "$RESULTS_FILE")
    skipped=$(jq -r --arg n "$name" '.[$n].skipped' "$RESULTS_FILE")
    total=$(jq -r --arg n "$name" '.[$n].total' "$RESULTS_FILE")

    # Status is based on whether there are actual failures
    local status
    if [[ "$failed" -gt 0 ]]; then
      status="❌ FAIL"
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

    body+="${status}  *${name}* — <${url}|link> — Score: ${score}/100 (${grade})${nl}"
    body+="      ${passed} passed | ${warnings} warnings | ${failed} failed${change_note} | ${skipped} skipped (${total} total)${nl}"

    # Include per-check failure details when there are failures
    if [[ "$failed" -gt 0 ]]; then
      local failure_lines
      failure_lines=$(jq -r --arg n "$name" '
        .[$n].failures[] |
        "• \(.name): \(.message)"
      ' "$RESULTS_FILE")
      body+="\`\`\`${failure_lines}\`\`\`${nl}"
    fi

    # Include skipped checks with reasons
    local skip_count
    skip_count=$(jq -r --arg n "$name" '.[$n].skipped_checks | length' "$RESULTS_FILE")
    if [[ "$skip_count" -gt 0 ]]; then
      local skip_lines
      skip_lines=$(jq -r --arg n "$name" '
        .[$n].skipped_checks[] |
        "      ◦ \(.name) — \(.reason)"
      ' "$RESULTS_FILE")
      body+="      _Skipped checks:_${nl}${skip_lines}${nl}"
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
find "$REPORT_DIR" -name "*_20*.txt" -mtime +30 -delete
find "$REPORT_DIR" -name "*_20*.json" -mtime +30 -delete
find "$HISTORY_DIR" -name "*.json" -mtime +30 -delete
