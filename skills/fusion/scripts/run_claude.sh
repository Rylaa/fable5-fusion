#!/usr/bin/env bash
# run_claude.sh — run ONE Opus 4.8 seat (panelist OR synthesizer) via the `claude` CLI at a LOCKED effort.
#
# Usage:
#   run_claude.sh <prompt_file> <output_file> [reasoning_effort] [model]
#
# - <prompt_file>     : path to a file with the FULL panelist prompt (verbatim task + brief instruction)
# - <output_file>     : where the seat's final answer is written (clean text, just the answer)
# - reasoning_effort  : low | medium | high | xhigh | max   (default: max)
# - model             : a model alias or full id                (default: claude-opus-4-8 = Opus 4.8)
#                       override with FUSION_CLAUDE_MODEL (e.g. claude-opus-4-8[1m] for the 1M-context
#                       variant; the default uses the standard window, ample for panelist prompts)
#
# WHY THIS SCRIPT EXISTS (the whole point):
#   Used for BOTH Opus seats — the two panelists (Step 1) and the synthesizer (Step 3).
#   Spawning an Opus seat through the `Agent` tool / agent-teams makes it a fresh `claude` session whose
#   effort comes from config, NOT from the orchestrator: the `Agent` tool has no per-call effort flag, and
#   the orchestrator's transient `/effort max` is "this session only" and does NOT propagate to (tmux)
#   teammates — so those Opus seats silently run at whatever effort the config resolves to. This script
#   sets the effort EXPLICITLY, per call, instead.
#
#   Effort precedence in Claude Code (highest -> lowest):
#     1. CLAUDE_CODE_EFFORT_LEVEL (env var)   <- highest; OUTRANKS the CLI flag
#     2. --effort (CLI flag)
#     3. settings.json `effortLevel`
#   So we set BOTH the env var AND the flag to "$effort" (default max): whichever of #1/#2 wins, it is max.
#   The ONLY thing that can still override this is a settings.json `env` block pinning a DIFFERENT
#   CLAUDE_CODE_EFFORT_LEVEL — the child re-reads settings.json `env` on launch and applies it on top of our
#   prefix, so a user who deliberately pins sub-max effort globally wins. There is no bulletproof CLI
#   override for that (short of --bare, which breaks OAuth auth). Mirrors run_codex.sh locking GPT-5.5 at xhigh.
#
# Isolation (safe by default, mirrors run_codex.sh):
# - Runs against a TEMPORARY COPY of the current repo/workdir (its CWD), so any candidate files it writes
#   land in the copy, never your live checkout. (CWD isolation; --permission-mode bypassPermissions keeps
#   the headless run from blocking on a prompt. This is not a hard FS sandbox — same trust level as the
#   Agent-tool teammates this replaces.)
# - The copy is deleted when the process exits.
# - `--disallowedTools "Task Agent"` stops a panelist from recursively spawning sub-agents / tmux teammates
#   (a HARD CLI guard). The CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0 prefix below is only best-effort: a
#   settings.json `env` block can re-enable agent-teams in the child, so we don't rely on it.
#
# Timeout: there is no `timeout`/`gtimeout` on stock macOS, so the claude run is wrapped in a
# self-contained perl timeout helper (FUSION_TIMEOUT, default 1800s — see _fusion_lib.sh). On timeout the
# runner exits 124 so the orchestrator drops this Opus seat and degrades gracefully (for the synthesizer
# seat, that means the orchestrator writes the final answer itself). A big Track-A merge can need more
# than 1800s — raise FUSION_TIMEOUT for those.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_fusion_lib.sh"

prompt_file="${1:?usage: run_claude.sh <prompt_file> <output_file> [reasoning_effort] [model]}"
output_file="${2:?usage: run_claude.sh <prompt_file> <output_file> [reasoning_effort] [model]}"
effort="${3:-max}"
model="${4:-${FUSION_CLAUDE_MODEL:-claude-opus-4-8}}"

case "$prompt_file" in
  /*) ;;
  *) prompt_file="$(pwd -P)/$prompt_file" ;;
esac
case "$output_file" in
  /*) ;;
  *) output_file="$(pwd -P)/$output_file" ;;
esac

if [ ! -s "$prompt_file" ]; then
  echo "[run_claude.sh] prompt file is missing or empty: $prompt_file" >&2
  exit 2
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "[run_claude.sh] claude CLI not found on PATH" >&2
  exit 3
fi
mkdir -p "$(dirname "$output_file")"
rm -f "$output_file"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/fusion-claude.XXXXXX")" || { echo "[run_claude.sh] mktemp failed" >&2; exit 4; }
trap 'rm -rf "$scratch"' EXIT
workdir="$scratch/workdir"

source_root="$(pwd -P)"
source_subdir=""
if git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  source_root="$(cd "$git_root" && pwd -P)"
  current_dir="$(pwd -P)"
  case "$current_dir" in
    "$source_root") source_subdir="" ;;
    "$source_root"/*) source_subdir="${current_dir#"$source_root"/}" ;;
    *) source_subdir="" ;;
  esac
fi

mkdir -p "$workdir"
if command -v rsync >/dev/null 2>&1; then
  rsync -a \
    --exclude '.git/index.lock' \
    --exclude '.git/shallow.lock' \
    --exclude '.git/worktrees/*/index.lock' \
    "$source_root"/ "$workdir"/
else
  cp -R "$source_root"/. "$workdir"/
fi

panel_cwd="$workdir"
if [ -n "$source_subdir" ]; then
  panel_cwd="$workdir/$source_subdir"
fi

# Run headless at a LOCKED model + effort. Set BOTH the highest-precedence effort knob
# (CLAUDE_CODE_EFFORT_LEVEL) AND the --effort flag, so the seat reaches "$effort" whichever one config would
# otherwise resolve. --disallowedTools blocks recursive sub-agent / teammate spawning (hard guard).
# The whole `claude -p` is wrapped in the perl timeout helper via `env` (perl execs `env`, which sets the
# locked-effort vars then execs claude) so the locked env + the "Task Agent" guard survive the wrapper
# untouched. The cd into the throwaway copy stays in this subshell; it exits right after, so nothing leaks.
# Rate-limit-aware retry. Under a saturated Anthropic rate-limit pool (many concurrent `claude -p` seats —
# e.g. overlapping Fusion panels), a seat can get 429 ("Server is temporarily limiting requests"); the CLI
# retries silently for tens of seconds, then the session dies with EMPTY output. That is NOT our timeout
# (exit 124) and NOT a crash — it is recoverable by backing off until the pool drains. So we retry ONLY on a
# rate-limit signature in the seat's stderr; a real timeout (124) or a non-rate-limit failure is never
# retried. Tunables: FUSION_SEAT_RETRIES (extra attempts, default 2), FUSION_SEAT_RETRY_BACKOFF (first
# backoff seconds, default 20; grows x3 each retry, + jitter so concurrent seats don't retry in lockstep).
# Set FUSION_SEAT_RETRIES=0 to disable retries; a clean (non-rate-limited) run loops exactly once.
attempts="${FUSION_SEAT_RETRIES:-2}"
backoff="${FUSION_SEAT_RETRY_BACKOFF:-20}"
try=0
while :; do
  rm -f "$output_file"
  (
    cd "$panel_cwd" || exit 9
    _run_with_timeout "$FUSION_TIMEOUT" env \
      CLAUDE_CODE_EFFORT_LEVEL="$effort" \
      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0 \
      CLAUDE_CODE_SPAWN_BACKEND= \
      claude -p \
        --model "$model" \
        --effort "$effort" \
        --permission-mode bypassPermissions \
        --output-format text \
        --disallowedTools "Task Agent" \
        < "$prompt_file" \
        > "$output_file" \
        2> "$scratch/stream.log"
  )
  status=$?

  # A real timeout (the seat exceeded FUSION_TIMEOUT): that was intentional — never retry it.
  if [ $status -eq 124 ]; then
    echo "[run_claude.sh] claude timed out after ${FUSION_TIMEOUT}s (FUSION_TIMEOUT); treat this Opus seat as absent. tail of log:" >&2
    tail -20 "$scratch/stream.log" >&2
    exit 124
  fi
  # Success: clean exit AND a non-empty answer.
  if [ $status -eq 0 ] && [ -s "$output_file" ]; then
    [ "$try" -gt 0 ] && echo "[run_claude.sh] recovered after $try retr$([ "$try" = 1 ] && echo y || echo ies)." >&2
    echo "[run_claude.sh] ok -> $output_file  (model=$model, effort=$effort)"
    exit 0
  fi
  # Rate-limit signature in the seat's stderr + retries left? back off (with jitter) and try again.
  if [ "$try" -lt "$attempts" ] && grep -qiE 'rate.?limit|temporarily limiting|overloaded|server is busy|too many requests|429|usage limit' "$scratch/stream.log" 2>/dev/null; then
    try=$((try + 1))
    jitter=0; [ "$backoff" -gt 0 ] && jitter=$(( ${RANDOM:-0} % 8 ))   # 0-7s so concurrent seats desync
    wait_s=$(( backoff + jitter ))
    echo "[run_claude.sh] seat rate-limited (attempt $try/$attempts) — backing off ${wait_s}s then retrying." >&2
    [ "$wait_s" -gt 0 ] && sleep "$wait_s"
    backoff=$(( backoff * 3 ))
    continue
  fi
  # Real failure: non-rate-limit crash, empty output with no rate-limit signature, or retries exhausted.
  echo "[run_claude.sh] claude exited $status (no recoverable rate-limit signature, or retries exhausted); tail of log:" >&2
  tail -20 "$scratch/stream.log" >&2
  exit 1
done
