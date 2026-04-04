#!/usr/bin/env bash
set -euo pipefail

REPO_PATH="/opt/openclaw/doittimer"
AGENT_SCRUM_ROOT="/opt/openclaw/agent-scrum"
WORKSPACE="$AGENT_SCRUM_ROOT/workspace"
RUNS_DIR="$WORKSPACE/runs"
PROMPTS_DIR="$AGENT_SCRUM_ROOT/prompts"
STORY_LOG="$AGENT_SCRUM_ROOT/story-log.md"
MAX_RETRIES=3
BASE_BRANCH="main"

LATEST_RUN_FILE="$WORKSPACE/latest-run.txt"

log() {
  printf '[agent-scrum] %s\n' "$*"
}

fail() {
  printf '[agent-scrum][error] %s\n' "$*" >&2
  exit 1
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
}

read_story_input() {
  local input="$1"

  if [[ -f "$input" ]]; then
    cat "$input"
    return 0
  fi

  printf '%s' "$input"
}

current_branch() {
  git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD
}

ensure_clean_repo() {
  if [[ -n "$(git -C "$REPO_PATH" status --porcelain)" ]]; then
    fail "Working tree is not clean in $REPO_PATH"
  fi
}

clean_generated_artifacts() {
  (
    cd "$REPO_PATH"
    git restore --worktree --source=HEAD -- test-results/.last-run.json 2>/dev/null || true
  )
  rm -rf "$REPO_PATH/playwright/.auth"
}

write_changed_files() {
  local run_dir="$1"

  (
    cd "$REPO_PATH"
    git diff --name-only \
      | grep -Ev '^(test-results/\.last-run\.json|playwright/\.auth/)' \
      > "$run_dir/changed-files.txt" || true
  )

  [[ -f "$run_dir/changed-files.txt" ]] || fail "Failed to write changed-files.txt"
}

ensure_playwright_browsers() {
  log "Ensuring Playwright Chromium is installed"
  (
    cd "$REPO_PATH"
    pnpm exec playwright install chromium
  )
}

playwright_base_url() {
  printf '%s\n' "${PLAYWRIGHT_BASE_URL:-http://127.0.0.1:3000}"
}

wait_for_url() {
  local url="$1"
  local attempts="${2:-30}"
  local sleep_seconds="${3:-1}"
  local i

  for ((i = 1; i <= attempts; i += 1)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_seconds"
  done

  return 1
}

start_playwright_app_if_needed() {
  local base_url
  local host_port
  local host
  local port
  local run_dir="$1"
  local server_log="$run_dir/playwright-server.log"

  base_url="$(playwright_base_url)"

  case "$base_url" in
    http://127.0.0.1:*|http://localhost:*)
      host_port="${base_url#http://}"
      host="${host_port%%:*}"
      port="${host_port##*:}"
      ;;
    *)
      log "PLAYWRIGHT_BASE_URL is non-local ($base_url); assuming app is managed externally"
      return 0
      ;;
  esac

  if wait_for_url "$base_url" 2 1; then
    log "Playwright base URL already reachable: $base_url"
    return 0
  fi

  log "Starting app for Playwright at $base_url"
  (
    cd "$REPO_PATH"
    PORT="$port" pnpm start >"$server_log" 2>&1 &
    echo $! > "$run_dir/playwright-server.pid"
  )

  if wait_for_url "$base_url" 60 1; then
    log "Playwright app is reachable: $base_url"
    return 0
  fi

  return 1
}

stop_playwright_app_if_started() {
  local run_dir="$1"
  local pid_file="$run_dir/playwright-server.pid"

  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$pid_file"
  fi
}

prepare_required_e2e_runtime() {
  local run_dir="$1"

  ensure_playwright_browsers

  if ! start_playwright_app_if_needed "$run_dir"; then
    {
      printf '\n'
      printf '=== E2E RUNTIME PRECHECK ===\n'
      printf 'STATUS: FAILED\n'
      printf 'Reason: PLAYWRIGHT_BASE_URL was not reachable and the orchestrator could not start the app successfully.\n'
    } >> "$run_dir/validation-output.txt"
    return 1
  fi

  return 0
}

plan_requires_e2e() {
  local run_dir="$1"
  local plan_file="$run_dir/PLAN.md"

  [[ -f "$plan_file" ]] || return 1

  grep -Eiq 'e2e|playwright' "$plan_file"
}

detect_relevant_e2e_spec() {
  local run_dir="$1"
  local plan_file="$run_dir/PLAN.md"

  [[ -f "$plan_file" ]] || return 1

  if grep -Fq 'tests/e2e/dashboard-optimized.spec.ts' "$plan_file"; then
    printf '%s\n' 'tests/e2e/dashboard-optimized.spec.ts'
    return 0
  fi

  if grep -Fq 'tests/e2e/dashboard.spec.ts' "$plan_file"; then
    printf '%s\n' 'tests/e2e/dashboard.spec.ts'
    return 0
  fi

  return 1
}

can_run_e2e() {
  [[ -n "${E2E_EMAIL:-}" && -n "${E2E_PASSWORD:-}" ]]
}

run_e2e_validation() {
  local run_dir="$1"
  local spec_file="$2"
  local validation_file="$run_dir/validation-output.txt"
  local exit_code

  {
    printf '\n'
    printf '=== E2E VALIDATION ===\n'
    printf 'Spec: %s\n' "$spec_file"
    printf 'Base URL: %s\n' "$(playwright_base_url)"
  } >> "$validation_file"

  if ! prepare_required_e2e_runtime "$run_dir" >>"$validation_file" 2>&1; then
    return 1
  fi

  set +e
  (
    cd "$REPO_PATH"
    PLAYWRIGHT_BASE_URL="$(playwright_base_url)" pnpm playwright test "$spec_file"
  ) >>"$validation_file" 2>&1
  exit_code=$?
  set -e

  stop_playwright_app_if_started "$run_dir"

  return "$exit_code"
}

mark_e2e_blocked() {
  local run_dir="$1"
  local spec_file="$2"
  local validation_file="$run_dir/validation-output.txt"

  {
    printf '\n'
    printf '=== E2E VALIDATION ===\n'
    printf 'Spec: %s\n' "$spec_file"
    printf 'STATUS: BLOCKED\n'
    printf 'Reason: E2E_EMAIL and/or E2E_PASSWORD are not set, so required e2e validation could not run.\n'
  } >> "$validation_file"
}

resolve_next_run_id() {
  local run_date="$1"
  local n=1
  while [[ -d "$RUNS_DIR/US${n}-${run_date}" ]]; do
    n=$((n + 1))
  done
  printf 'US%s-%s\n' "$n" "$run_date"
}

append_story_log() {
  local run_id="$1"
  local story="$2"
  local result="$3"
  local attempts="$4"
  local run_dir="$5"

  local changed_files_text="(none)"
  if [[ -s "$run_dir/changed-files.txt" ]]; then
    changed_files_text="$(sed 's/^/- /' "$run_dir/changed-files.txt")"
  fi

  {
    printf '## %s\n' "$(date '+%Y-%m-%d')"
    printf 'Run ID: %s\n' "$run_id"
    printf 'Story: %s\n' "$story"
    printf 'Result: %s\n' "$result"
    printf 'Attempts: %s\n' "$attempts"
    printf 'Files changed:\n%s\n' "$changed_files_text"
    printf 'Artifacts:\n'
    printf -- '- %s/PLAN.md\n' "$run_dir"
    if [[ "$result" == "PASS" ]]; then
      printf -- '- %s/validation-output.txt\n' "$run_dir"
      printf -- '- %s/REVIEW.md\n' "$run_dir"
    else
      if [[ -f "$run_dir/FIX-NOTES.md" ]]; then
        printf -- '- %s/FIX-NOTES.md\n' "$run_dir"
      fi
      printf -- '- %s/validation-output.txt\n' "$run_dir"
      printf -- '- %s/FAILURE-REPORT.md\n' "$run_dir"
    fi
    printf -- '---\n'
  } >> "$STORY_LOG"
}

write_run_meta() {
  local run_id="$1"
  local run_date="$2"
  local status="$3"
  local attempts="$4"
  local run_dir="$5"

  cat > "$run_dir/run-meta.env" <<EOF
RUN_ID=$run_id
RUN_DATE=$run_date
REPO_PATH=$REPO_PATH
STATUS=$status
ATTEMPTS=$attempts
EOF
}

run_codex_prompt() {
  local prompt_file="$1"
  local output_file="$2"
  local prompt_text

  [[ -f "$prompt_file" ]] || fail "Missing prompt file: $prompt_file"
  [[ -s "$prompt_file" ]] || fail "Prompt file is empty: $prompt_file"

  require_command codex

  prompt_text="$(cat "$prompt_file")"

  (
    cd "$REPO_PATH"
    codex exec --full-auto "$prompt_text"
  ) > "$output_file"

  [[ -s "$output_file" ]] || fail "Expected output file was not created or is empty: $output_file"
}

run_codex_prompt_to_file() {
  local prompt_file="$1"
  local output_file="$2"
  local temp_output
  local exit_code
  local prompt_text

  [[ -f "$prompt_file" ]] || fail "Missing prompt file: $prompt_file"
  [[ -s "$prompt_file" ]] || fail "Prompt file is empty: $prompt_file"

  require_command codex

  prompt_text="$(cat "$prompt_file")"
  temp_output="$(mktemp)"

  set +e
  (
    cd "$REPO_PATH"
    codex exec --full-auto "$prompt_text"
  ) > "$temp_output"
  exit_code=$?
  set -e

  if [[ $exit_code -ne 0 ]]; then
    rm -f "$temp_output"
    return "$exit_code"
  fi

  [[ -s "$temp_output" ]] || fail "Expected codex output was not created or is empty"
  mv "$temp_output" "$output_file"
}

run_codex_prompt_summary_only() {
  local prompt_file="$1"
  local temp_output
  local exit_code
  local prompt_text

  [[ -f "$prompt_file" ]] || fail "Missing prompt file: $prompt_file"
  [[ -s "$prompt_file" ]] || fail "Prompt file is empty: $prompt_file"

  require_command codex

  prompt_text="$(cat "$prompt_file")"
  temp_output="$(mktemp)"

  set +e
  (
    cd "$REPO_PATH"
    codex exec --full-auto "$prompt_text"
  ) > "$temp_output"
  exit_code=$?
  set -e

  if [[ $exit_code -ne 0 ]]; then
    rm -f "$temp_output"
    return "$exit_code"
  fi

  [[ -s "$temp_output" ]] || fail "Expected codex summary output was not created or is empty"
  rm -f "$temp_output"
}

run_planner() {
  local run_dir="$1"
  local plan_file="$run_dir/PLAN.md"
  local prompt_file="$PROMPTS_DIR/planner.txt"

  log "Running planner..."
  run_codex_prompt "$prompt_file" "$plan_file"
}

run_implementer() {
  local run_dir="$1"
  local prompt_file="$PROMPTS_DIR/implementer.txt"

  log "Running implementer..."
  run_codex_prompt_summary_only "$prompt_file"

  write_changed_files "$run_dir"
}

run_validation() {
  local run_dir="$1"
  local validation_file="$run_dir/validation-output.txt"
  local exit_code
  local spec_file=""

  log "Running validation: pnpm lint, pnpm typecheck, pnpm build"
  set +e
  (
    cd "$REPO_PATH"
    pnpm lint
    pnpm typecheck
    pnpm build
  ) >"$validation_file" 2>&1
  exit_code=$?
  set -e

  if [[ $exit_code -ne 0 ]]; then
    return "$exit_code"
  fi

  if plan_requires_e2e "$run_dir"; then
    if ! spec_file="$(detect_relevant_e2e_spec "$run_dir")"; then
      {
        printf '\n'
        printf '=== E2E VALIDATION ===\n'
        printf 'STATUS: REQUIRED BUT UNMAPPED\n'
        printf 'Reason: PLAN.md requires e2e evidence but no supported spec file could be detected.\n'
      } >> "$validation_file"
      return 1
    fi

    if ! can_run_e2e; then
      log "Required e2e validation is blocked because E2E credentials are not set"
      mark_e2e_blocked "$run_dir" "$spec_file"
      return 1
    fi

    log "Running required e2e validation: $spec_file"
    run_e2e_validation "$run_dir" "$spec_file"
    return $?
  fi

  return 0
}

run_reanalyzer() {
  local run_dir="$1"
  local fix_notes_file="$run_dir/FIX-NOTES.md"
  local prompt_file="$PROMPTS_DIR/re-analyzer.txt"

  log "Running re-analyzer..."
  run_codex_prompt_to_file "$prompt_file" "$fix_notes_file"
  [[ -s "$fix_notes_file" ]] || fail "FIX-NOTES.md was not created or is empty"

  write_changed_files "$run_dir"
}

run_reviewer() {
  local run_dir="$1"
  local review_file="$run_dir/REVIEW.md"
  local prompt_file="$PROMPTS_DIR/reviewer.txt"

  log "Running reviewer..."
  run_codex_prompt "$prompt_file" "$review_file"

  [[ -s "$review_file" ]] || fail "REVIEW.md was not created"
  local first_line
  first_line="$(head -n 1 "$review_file" | tr -d '\r')"
  [[ "$first_line" == "PASS" || "$first_line" == "FAIL" ]] || fail "REVIEW.md first line must be PASS or FAIL"

  [[ "$first_line" == "PASS" ]]
}

write_failure_report() {
  local run_id="$1"
  local story="$2"
  local attempts="$3"
  local run_dir="$4"

  local changed_files_text="(none)"
  if [[ -s "$run_dir/changed-files.txt" ]]; then
    changed_files_text="$(sed 's/^/- /' "$run_dir/changed-files.txt")"
  fi

  cat > "$run_dir/FAILURE-REPORT.md" <<EOF
# FAILURE REPORT

Run ID: $run_id
Story: $story
Attempts: $attempts

## Failure reason
Run did not reach PASS after exhausting MAX_RETRIES=$MAX_RETRIES.

## Likely root cause
See validation-output.txt, REVIEW.md, and FIX-NOTES.md for the latest observed failure and retry analysis.

## Files touched
$changed_files_text

## Next human action
Inspect PLAN.md, validation-output.txt, FIX-NOTES.md, and the repo diff, then make a targeted manual fix or tighten the prompts before retrying.
EOF
}

main() {
  [[ $# -ge 1 ]] || fail "Usage: ./agent-scrum.sh \"As a user I want ...\""

  local story
  story="$(read_story_input "$1")"

  [[ -d "$REPO_PATH" ]] || fail "REPO_PATH does not exist: $REPO_PATH"
  git -C "$REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "REPO_PATH is not a git repository: $REPO_PATH"

  require_command node
  require_command pnpm
  require_command curl
  require_command git
  require_command codex

  mkdir -p "$RUNS_DIR"

  local branch
  branch="$(current_branch)"
  [[ "$branch" == "$BASE_BRANCH" ]] || fail "Current branch is '$branch', expected '$BASE_BRANCH'"

  ensure_clean_repo
  clean_generated_artifacts

  local run_date
  run_date="$(date '+%Y-%m-%d')"

  local run_id
  run_id="$(resolve_next_run_id "$run_date")"

  local run_dir="$RUNS_DIR/$run_id"
  mkdir -p "$run_dir"

  printf '%s\n' "$run_id" > "$LATEST_RUN_FILE"
  printf '%s\n' "$story" > "$run_dir/user-story.md"

  local attempts=0
  write_run_meta "$run_id" "$run_date" "STARTED" "$attempts" "$run_dir"

  log "Starting run $run_id"
  log "Run directory: $run_dir"

  run_planner "$run_dir"
  [[ -s "$run_dir/PLAN.md" ]] || fail "PLAN.md is missing or empty after planner"

  run_implementer "$run_dir"
  clean_generated_artifacts
  write_changed_files "$run_dir"

  if run_validation "$run_dir"; then
    write_run_meta "$run_id" "$run_date" "VALIDATION_PASSED" "$attempts" "$run_dir"
    clean_generated_artifacts
    write_changed_files "$run_dir"
    if run_reviewer "$run_dir"; then
      write_run_meta "$run_id" "$run_date" "PASS" "$attempts" "$run_dir"
      append_story_log "$run_id" "$story" "PASS" "$attempts" "$run_dir"
      log "Run completed successfully"
      exit 0
    fi

    write_run_meta "$run_id" "$run_date" "FAIL" "$attempts" "$run_dir"
    write_failure_report "$run_id" "$story" "$attempts" "$run_dir"
    append_story_log "$run_id" "$story" "FAIL" "$attempts" "$run_dir"
    fail "Run failed review after validation passed"
  fi

  while (( attempts < MAX_RETRIES )); do
    attempts=$((attempts + 1))
    log "Run failed on attempt $attempts/$MAX_RETRIES"
    write_run_meta "$run_id" "$run_date" "RETRYING" "$attempts" "$run_dir"

    run_reanalyzer "$run_dir"
    clean_generated_artifacts
    write_changed_files "$run_dir"

    if run_validation "$run_dir"; then
      write_run_meta "$run_id" "$run_date" "VALIDATION_PASSED" "$attempts" "$run_dir"
      clean_generated_artifacts
      write_changed_files "$run_dir"
      if run_reviewer "$run_dir"; then
        write_run_meta "$run_id" "$run_date" "PASS" "$attempts" "$run_dir"
        append_story_log "$run_id" "$story" "PASS" "$attempts" "$run_dir"
        log "Run completed successfully after retry"
        exit 0
      fi

      write_run_meta "$run_id" "$run_date" "FAIL" "$attempts" "$run_dir"
      write_failure_report "$run_id" "$story" "$attempts" "$run_dir"
      append_story_log "$run_id" "$story" "FAIL" "$attempts" "$run_dir"
      fail "Run failed review after validation passed on retry"
    fi
  done

  write_run_meta "$run_id" "$run_date" "FAIL" "$attempts" "$run_dir"
  write_failure_report "$run_id" "$story" "$attempts" "$run_dir"
  append_story_log "$run_id" "$story" "FAIL" "$attempts" "$run_dir"
  fail "Run failed after $MAX_RETRIES retries"
}

main "$@"
