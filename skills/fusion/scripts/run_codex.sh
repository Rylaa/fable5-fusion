#!/usr/bin/env bash
# run_codex.sh — run one GPT-5.5 seat (panelist OR judge) via codex, with web search + bash.
#
# Usage:
#   run_codex.sh <prompt_file> <output_file> [reasoning_effort]
#
# - <prompt_file>   : path to a file containing the FULL prompt (verbatim task + brief instruction)
# - <output_file>   : where the seat's final answer is written (clean, just the answer)
# - reasoning_effort: low | medium | high | xhigh   (default: xhigh)
#
# Speed: `-c service_tier=priority` runs on OpenAI's PRIORITY (fast) processing tier — it keeps the
#   xhigh reasoning quality but serves the request faster. (Override with FUSION_SERVICE_TIER.)
#
# Isolation model (safe by default):
# - The seat runs against a TEMPORARY COPY of the current repo/workdir, set as its working root with
#   `--cd`, so it SEES the project for context but its writes never touch your live checkout.
# - `-s workspace-write` keeps codex SANDBOXED: it may read and write only inside that copy (its
#   workspace); the rest of the host is protected. We deliberately do NOT use
#   `--dangerously-bypass-approvals-and-sandbox` — codex's own help marks it "EXTREMELY DANGEROUS …
#   solely for environments that are externally sandboxed", which a normal dev machine is not.
# - `-c tools.web_search=true` enables web search. `--ephemeral` avoids persisting session files.
# - `-o/--output-last-message` writes ONLY the final message — no streaming noise to parse.
# - The throwaway copy is deleted when the process exits.
# - There is no `timeout`/`gtimeout` on stock macOS, so the codex run is wrapped in a self-contained
#   perl timeout helper (FUSION_TIMEOUT, default 300s — see _fusion_lib.sh). On timeout the runner
#   exits 124 so the orchestrator drops this GPT-5.5 seat and degrades the panel gracefully.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_fusion_lib.sh"

prompt_file="${1:?usage: run_codex.sh <prompt_file> <output_file> [reasoning_effort]}"
output_file="${2:?usage: run_codex.sh <prompt_file> <output_file> [reasoning_effort]}"
effort="${3:-xhigh}"
service_tier="${FUSION_SERVICE_TIER-priority}"   # priority = fast processing tier. Use `-` (not `:-`) so
                                                 # FUSION_SERVICE_TIER="" actually DISABLES the override
                                                 # (falls back to ~/.codex/config.toml); unset => priority.

case "$prompt_file" in
  /*) ;;
  *) prompt_file="$(pwd -P)/$prompt_file" ;;
esac
case "$output_file" in
  /*) ;;
  *) output_file="$(pwd -P)/$output_file" ;;
esac

if [ ! -s "$prompt_file" ]; then
  echo "[run_codex.sh] prompt file is missing or empty: $prompt_file" >&2
  exit 2
fi
mkdir -p "$(dirname "$output_file")"
rm -f "$output_file"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/fusion-codex.XXXXXX")"
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

# gh auth precheck (informational only — never a gate). Warns if `gh` is installed but not
# authenticated in the PARENT environment. Note: this seat runs SANDBOXED (`-s workspace-write`), so
# keychain-backed `gh` may be unavailable inside the sandbox regardless; web search is unaffected. We
# deliberately do NOT add `--dangerously-bypass-approvals-and-sandbox` to "fix" this — the sandbox stays.
if command -v gh >/dev/null 2>&1; then
  if gh auth status --active --hostname github.com >/dev/null 2>&1; then
    echo "[run_codex.sh] gh auth ok in parent environment (note: codex is sandboxed; the seat can't use keychain-backed gh)" >&2
  else
    echo "[run_codex.sh] warning: gh is installed but not authenticated in the parent environment (gh auth status failed)" >&2
  fi
fi

# Build the codex args; only add service_tier when non-empty (empty = use config.toml default).
tier_args=()
if [ -n "$service_tier" ]; then
  tier_args=(-c "service_tier=$service_tier")
  # Only `priority` is the confirmed fast tier in codex 0.139; unrecognized values (e.g. a typo, or `flex`)
  # are SILENTLY coerced to codex's default/auto tier — fast mode would be lost with no error. Surface it.
  [ "$service_tier" != "priority" ] && \
    echo "[run_codex.sh] WARNING: FUSION_SERVICE_TIER='$service_tier' is not the known fast tier 'priority'; codex may fall back to its default tier (fast mode off)." >&2
fi

# Wrap in the per-seat timeout (FUSION_TIMEOUT, default 300s). The array/flag expansion happens in bash
# before perl sees the words, so service_tier / sandbox / effort are all preserved exactly. The caller's
# redirections below apply to the wrapped codex process: stdin from the prompt file, stdout+stderr to the log.
_run_with_timeout "$FUSION_TIMEOUT" codex exec \
  --skip-git-repo-check \
  --ephemeral \
  --cd "$panel_cwd" \
  -s workspace-write \
  -c tools.web_search=true \
  ${tier_args[@]+"${tier_args[@]}"} \
  -c "model_reasoning_effort=$effort" \
  -o "$output_file" \
  - < "$prompt_file" \
  > "$scratch/stream.log" 2>&1
status=$?

if [ $status -eq 124 ]; then
  echo "[run_codex.sh] codex timed out after ${FUSION_TIMEOUT}s (FUSION_TIMEOUT); treat this GPT-5.5 seat as absent. tail of log:" >&2
  tail -20 "$scratch/stream.log" >&2
  exit 124
fi
if [ $status -ne 0 ] || [ ! -s "$output_file" ]; then
  echo "[run_codex.sh] codex exited $status; tail of log:" >&2
  tail -20 "$scratch/stream.log" >&2
  exit 1
fi
echo "[run_codex.sh] ok -> $output_file"
