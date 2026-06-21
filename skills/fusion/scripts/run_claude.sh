#!/usr/bin/env bash
# run_claude.sh — run ONE Opus 4.8 panelist via the `claude` CLI at a LOCKED reasoning effort.
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
#   Spawning a panelist through the `Agent` tool / agent-teams makes it a fresh `claude` session whose
#   effort comes from config, NOT from the orchestrator: the `Agent` tool has no per-call effort flag, and
#   the orchestrator's transient `/effort max` is "this session only" and does NOT propagate to (tmux)
#   teammates — so the Opus panelists silently run at whatever effort the config resolves to. This script
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

set -uo pipefail

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
(
  cd "$panel_cwd" || exit 9
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

if [ $status -ne 0 ] || [ ! -s "$output_file" ]; then
  echo "[run_claude.sh] claude exited $status; tail of log:" >&2
  tail -20 "$scratch/stream.log" >&2
  exit 1
fi
echo "[run_claude.sh] ok -> $output_file  (model=$model, effort=$effort)"
