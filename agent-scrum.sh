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
    if [[ -f "$run_dir/repo-snapshot.md" ]]; then
      printf -- '- %s/repo-snapshot.md\n' "$run_dir"
    fi
    if [[ -f "$run_dir/story-class.md" ]]; then
      printf -- '- %s/story-class.md\n' "$run_dir"
    fi
    if [[ -f "$run_dir/SKILL-CONTEXT.md" ]]; then
      printf -- '- %s/SKILL-CONTEXT.md\n' "$run_dir"
    fi
    if [[ -f "$run_dir/PLAN.md" ]]; then
      printf -- '- %s/PLAN.md\n' "$run_dir"
    fi
    if [[ "$result" == "PASS" ]]; then
      printf -- '- %s/validation-output.txt\n' "$run_dir"
      printf -- '- %s/REVIEW.md\n' "$run_dir"
    elif [[ "$result" == "BLOCKED" ]]; then
      printf -- '- %s/validation-output.txt\n' "$run_dir"
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

generate_repo_snapshot() {
  local run_dir="$1"
  local snapshot_file="$run_dir/repo-snapshot.md"
  local skills_root="$AGENT_SCRUM_ROOT/agent-scrum/skills"

  {
    printf '# Repo Snapshot\n\n'
    printf 'Generated: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '## Repo Path\n'
    printf '%s\n\n' "$REPO_PATH"

    printf '## Top-Level Structure\n'
    (
      cd "$REPO_PATH"
      find . -mindepth 1 -maxdepth 1 | sort | sed 's#^\./#- #'
    )

    printf '\n## app/ Tree (shallow)\n'
    (
      cd "$REPO_PATH"
      if [[ -d app ]]; then
        find app -mindepth 1 -maxdepth 3 | sort | sed 's#^#- #'
      else
        printf -- '- (missing)\n'
      fi
    )

    printf '\n## lib/ Tree (shallow)\n'
    (
      cd "$REPO_PATH"
      if [[ -d lib ]]; then
        find lib -mindepth 1 -maxdepth 3 | sort | sed 's#^#- #'
      else
        printf -- '- (missing)\n'
      fi
    )

    printf '\n## Available Skill Files\n'
    if [[ -d "$skills_root" ]]; then
      (
        cd "$skills_root"
        find . -type f -name '*.md' | sort | sed 's#^\./#- #'
      )
    else
      printf -- '- (missing skills directory)\n'
    fi
  } > "$snapshot_file"

  [[ -s "$snapshot_file" ]] || fail "repo-snapshot.md was not created or is empty: $snapshot_file"
}

read_story_class_scalar() {
  local run_dir="$1"
  local key="$2"
  local story_class_file="$run_dir/story-class.md"

  awk -v key="$key" '
    $0 ~ "^"key":[[:space:]]*" {
      sub("^"key":[[:space:]]*", "", $0)
      print $0
      exit
    }
  ' "$story_class_file"
}

read_story_class_list() {
  local run_dir="$1"
  local key="$2"
  local story_class_file="$run_dir/story-class.md"

  awk -v key="$key" '
    $0 ~ "^"key":[[:space:]]*$" {
      in_list = 1
      next
    }
    in_list && $0 ~ "^[^[:space:]]" {
      exit
    }
    in_list && $0 ~ "^[[:space:]]*-[[:space:]]+" {
      line = $0
      sub("^[[:space:]]*-[[:space:]]+", "", line)
      print line
    }
  ' "$story_class_file"
}

ensure_story_class_contract() {
  local run_dir="$1"
  local story_class_file="$run_dir/story-class.md"

  [[ -s "$story_class_file" ]] || fail "story-class.md is missing or empty: $story_class_file"

  grep -Eq '^story_type:' "$story_class_file" || fail "story-class.md missing key: story_type"
  grep -Eq '^risk_level:' "$story_class_file" || fail "story-class.md missing key: risk_level"
  grep -Eq '^branch_strategy:' "$story_class_file" || fail "story-class.md missing key: branch_strategy"
  grep -Eq '^branch_name:' "$story_class_file" || fail "story-class.md missing key: branch_name"
  grep -Eq '^validation_profile:' "$story_class_file" || fail "story-class.md missing key: validation_profile"
  grep -Eq '^skills_to_inject:' "$story_class_file" || fail "story-class.md missing key: skills_to_inject"
  grep -Eq '^test_writer_needed:' "$story_class_file" || fail "story-class.md missing key: test_writer_needed"
  grep -Eq '^pr_creation:' "$story_class_file" || fail "story-class.md missing key: pr_creation"
  grep -Eq '^blocked_reason:' "$story_class_file" || fail "story-class.md missing key: blocked_reason"
}

run_classifier() {
  local run_dir="$1"
  local story_class_file="$run_dir/story-class.md"
  local prompt_file="$PROMPTS_DIR/classifier.txt"

  log "Running classifier..."
  run_codex_prompt "$prompt_file" "$story_class_file"
  ensure_story_class_contract "$run_dir"
}

is_story_blocked() {
  local run_dir="$1"
  local risk_level

  risk_level="$(read_story_class_scalar "$run_dir" "risk_level" | tr -d '\r' | xargs)"
  [[ "$risk_level" == "blocked" ]]
}

blocked_reason_for_story() {
  local run_dir="$1"
  local blocked_reason

  blocked_reason="$(read_story_class_scalar "$run_dir" "blocked_reason" | tr -d '\r' | xargs)"
  if [[ -z "$blocked_reason" || "$blocked_reason" == "none" ]]; then
    printf '%s\n' "Classifier marked this story as blocked."
    return 0
  fi
  printf '%s\n' "$blocked_reason"
}

load_skills() {
  local run_dir="$1"
  local skills_root="$AGENT_SCRUM_ROOT/agent-scrum/skills"
  local skill_context_file="$run_dir/SKILL-CONTEXT.md"
  local loaded_count=0
  local missing_count=0
  local skill_rel

  {
    printf '# Skill Context\n\n'
    printf 'Source: classifier skills_to_inject from story-class.md\n'
  } > "$skill_context_file"

  while IFS= read -r skill_rel; do
    skill_rel="$(printf '%s' "$skill_rel" | tr -d '\r' | xargs)"
    [[ -z "$skill_rel" || "$skill_rel" == "none" ]] && continue

    if [[ -f "$skills_root/$skill_rel" ]]; then
      {
        printf '\n## Skill: %s\n\n' "$skill_rel"
        cat "$skills_root/$skill_rel"
        printf '\n'
      } >> "$skill_context_file"
      loaded_count=$((loaded_count + 1))
    else
      {
        printf '\n## Missing Skill: %s\n\n' "$skill_rel"
        printf 'Warning: classifier requested a skill file that does not exist at %s\n' "$skills_root/$skill_rel"
      } >> "$skill_context_file"
      log "Warning: missing classifier-requested skill file: $skills_root/$skill_rel"
      missing_count=$((missing_count + 1))
    fi
  done < <(read_story_class_list "$run_dir" "skills_to_inject")

  if (( loaded_count == 0 )); then
    {
      printf '\n## No Skill Files Loaded\n\n'
      printf 'No available skills were injected for this run.\n'
    } >> "$skill_context_file"
  fi

  if (( missing_count > 0 )); then
    log "Skill loading completed with $missing_count missing skill file(s)"
  fi

  [[ -s "$skill_context_file" ]] || fail "SKILL-CONTEXT.md was not created or is empty: $skill_context_file"
}

read_validation_profile() {
  local run_dir="$1"
  local cmd

  while IFS= read -r cmd; do
    cmd="$(printf '%s' "$cmd" | tr -d '\r' | xargs)"
    [[ -z "$cmd" || "$cmd" == "none" ]] && continue
    printf '%s\n' "$cmd"
  done < <(read_story_class_list "$run_dir" "validation_profile")
}

run_single_validation_command() {
  local run_dir="$1"
  local validation_file="$2"
  local validation_cmd="$3"
  local exit_code
  local spec_file

  {
    printf '\n'
    printf '=== VALIDATION COMMAND ===\n'
    printf 'Command: %s\n' "$validation_cmd"
  } >> "$validation_file"

  if [[ "$validation_cmd" =~ ^pnpm[[:space:]]+playwright[[:space:]]+test[[:space:]]+(.+)$ ]]; then
    spec_file="${BASH_REMATCH[1]}"
    if ! can_run_e2e; then
      log "Required e2e validation is blocked because E2E credentials are not set"
      mark_e2e_blocked "$run_dir" "$spec_file"
      return 1
    fi

    log "Running required e2e validation: $spec_file"
    run_e2e_validation "$run_dir" "$spec_file"
    return $?
  fi

  set +e
  (
    cd "$REPO_PATH"
    bash -lc "$validation_cmd"
  ) >>"$validation_file" 2>&1
  exit_code=$?
  set -e

  return "$exit_code"
}

run_codex_prompt() {
  local prompt_file="$1"
  local output_file="$2"
  local skill_context_file="${3:-}"
  local prompt_text

  [[ -f "$prompt_file" ]] || fail "Missing prompt file: $prompt_file"
  [[ -s "$prompt_file" ]] || fail "Prompt file is empty: $prompt_file"

  require_command codex

  prompt_text="$(cat "$prompt_file")"
  if [[ -n "$skill_context_file" ]]; then
    [[ -f "$skill_context_file" ]] || fail "Missing skill context file: $skill_context_file"
    prompt_text+=$'\n\nRun-local instruction: Before doing any other work, read this file for skill context:\n'"$skill_context_file"
  fi

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
  local skill_context_file="${2:-}"
  local temp_output
  local exit_code
  local prompt_text

  [[ -f "$prompt_file" ]] || fail "Missing prompt file: $prompt_file"
  [[ -s "$prompt_file" ]] || fail "Prompt file is empty: $prompt_file"

  require_command codex

  prompt_text="$(cat "$prompt_file")"
  if [[ -n "$skill_context_file" ]]; then
    [[ -f "$skill_context_file" ]] || fail "Missing skill context file: $skill_context_file"
    prompt_text+=$'\n\nRun-local instruction: Before doing any other work, read this file for skill context:\n'"$skill_context_file"
  fi
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
  local skill_context_file="$run_dir/SKILL-CONTEXT.md"

  log "Running planner..."
  run_codex_prompt "$prompt_file" "$plan_file" "$skill_context_file"
}

run_implementer() {
  local run_dir="$1"
  local prompt_file="$PROMPTS_DIR/implementer.txt"
  local skill_context_file="$run_dir/SKILL-CONTEXT.md"

  log "Running implementer..."
  run_codex_prompt_summary_only "$prompt_file" "$skill_context_file"

  write_changed_files "$run_dir"
}

run_validation() {
  local run_dir="$1"
  local validation_file="$run_dir/validation-output.txt"
  local validation_cmd
  local -a validation_commands=()

  mapfile -t validation_commands < <(read_validation_profile "$run_dir")
  (( ${#validation_commands[@]} > 0 )) || fail "validation_profile in story-class.md is empty for run: $run_dir"

  {
    printf 'Validation profile source: %s/story-class.md\n' "$run_dir"
    printf 'Validation commands:\n'
    for validation_cmd in "${validation_commands[@]}"; do
      printf -- '- %s\n' "$validation_cmd"
    done
    printf '\n'
  } > "$validation_file"

  for validation_cmd in "${validation_commands[@]}"; do
    log "Running validation command: $validation_cmd"
    if ! run_single_validation_command "$run_dir" "$validation_file" "$validation_cmd"; then
      return 1
    fi
  done

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

write_blocked_validation_output() {
  local run_dir="$1"
  local blocked_reason="$2"
  local validation_file="$run_dir/validation-output.txt"

  cat > "$validation_file" <<EOF
=== CLASSIFIER BLOCKED STORY ===
STATUS: BLOCKED
Reason: $blocked_reason
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

  generate_repo_snapshot "$run_dir"
  run_classifier "$run_dir"

  if is_story_blocked "$run_dir"; then
    local blocked_reason
    blocked_reason="$(blocked_reason_for_story "$run_dir")"
    log "Classifier blocked run $run_id: $blocked_reason"
    write_blocked_validation_output "$run_dir" "$blocked_reason"
    : > "$run_dir/changed-files.txt"
    write_run_meta "$run_id" "$run_date" "BLOCKED" "$attempts" "$run_dir"
    append_story_log "$run_id" "$story" "BLOCKED" "$attempts" "$run_dir"
    exit 0
  fi

  load_skills "$run_dir"

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
