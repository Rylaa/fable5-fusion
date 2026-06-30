#!/usr/bin/env bash
# install.sh — install the Fusion slash command for Codex CLI (additive; touches nothing in Claude Code).
#
# What it does:
#   1. Copies codex/fusion-runner.sh -> $CODEX_HOME/fusion/fusion-runner.sh   (the deterministic orchestrator)
#   2. Copies codex/prompts/fusion.md -> $CODEX_HOME/prompts/fusion.md        (so `/fusion` appears in codex)
#   3. Verifies the Fusion seat-runner scripts can be found (the runner resolves them at run time)
#   4. Prints exactly how to launch codex and invoke the command
#
# It does NOT edit ~/.codex/config.toml, your shell rc, or any Claude Code plugin file. It NEVER
# silently overwrites an existing fusion.md / fusion-runner.sh: if one already exists and differs, it
# refuses and asks you to re-run with --force (which backs up the old file first).
#
# Usage:
#   bash codex/install.sh            # install / update (refuses to clobber a different existing file)
#   bash codex/install.sh --force    # overwrite, backing up any different existing file first

set -uo pipefail

FORCE=0
case "${1:-}" in
  --force|-f) FORCE=1 ;;
  "" ) ;;
  * ) echo "[install] unknown arg: $1 (use --force to overwrite different existing files)" >&2; exit 2 ;;
esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

SRC_PROMPT="$SELF_DIR/prompts/fusion.md"
SRC_RUNNER="$SELF_DIR/fusion-runner.sh"
DEST_PROMPT="$CODEX_HOME/prompts/fusion.md"
DEST_RUNNER="$CODEX_HOME/fusion/fusion-runner.sh"

for f in "$SRC_PROMPT" "$SRC_RUNNER"; do
  [ -f "$f" ] || { echo "[install] source file not found: $f" >&2; exit 1; }
done

# install_one <src> <dest> <mode> — copy src->dest, treating an existing dest as a real file:
#   identical  -> skip (already current)
#   different  -> without --force: REFUSE (touch nothing). with --force: back up dest, then overwrite.
install_one() {
  src="$1"; dest="$2"; mode="$3"
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ]; then
    if cmp -s "$src" "$dest"; then
      echo "[install] $dest is already current — skipped."
      return 0
    fi
    if [ "$FORCE" != 1 ]; then
      echo "[install] REFUSING to overwrite an existing, DIFFERENT file:" >&2
      echo "          $dest" >&2
      echo "          (it may be a prior Fusion-for-Codex install or your own customization)." >&2
      echo "          Re-run with --force to back it up and replace it:" >&2
      echo "              bash codex/install.sh --force" >&2
      return 3
    fi
    bak="$dest.bak.$(date +%Y%m%d%H%M%S)"
    cp "$dest" "$bak"
    echo "[install] existing $dest backed up -> $bak"
  fi
  cp "$src" "$dest"
  chmod "$mode" "$dest"
  echo "[install] wrote $dest"
}

rc=0
install_one "$SRC_RUNNER" "$DEST_RUNNER" 755 || rc=$?
install_one "$SRC_PROMPT" "$DEST_PROMPT" 644 || rc=$?
if [ "$rc" != 0 ]; then
  echo "[install] nothing was overwritten without --force. See the message(s) above." >&2
  exit "$rc"
fi

# Resolve the seat-runner scripts the runner will use at run time (same order as the runner).
SCRIPTS=""
for c in "${FUSION_SCRIPTS:-}" \
         "$HOME/.claude/plugins/marketplaces/fable5-fusion/skills/fusion/scripts" \
         "$SELF_DIR/../skills/fusion/scripts"; do
  if [ -n "$c" ] && [ -f "$c/run_claude.sh" ]; then SCRIPTS="$(cd "$c" && pwd)"; break; fi
done
echo
if [ -n "$SCRIPTS" ]; then
  echo "[install] fusion seat-runner scripts found at:"
  echo "          $SCRIPTS"
else
  echo "[install] WARNING: could not find the fusion seat-runner scripts in the usual places."
  echo "          Install the fable5-fusion plugin in Claude Code, or export FUSION_SCRIPTS to its"
  echo "          skills/fusion/scripts directory before running /fusion."
fi

# Dependency hints (non-fatal).
command -v codex  >/dev/null 2>&1 || echo "[install] note: 'codex' not on PATH."
command -v claude >/dev/null 2>&1 || echo "[install] note: 'claude' not on PATH — Fusion runs an Opus-less (GPT-5.5-only) degraded panel until you install + log in to claude."
command -v perl   >/dev/null 2>&1 || echo "[install] note: 'perl' not found — the per-seat timeout helper needs it."

cat <<'NEXT'

Done. To use Fusion from Codex:

  1. Launch codex with the sandbox OFF. macOS Seatbelt cannot be nested, and the panel's GPT-5.5
     seats apply their own -s workspace-write sandbox, so the orchestrator itself must be unsandboxed:

       codex --sandbox danger-full-access --ask-for-approval never

     Tip — add a one-word launcher to your shell rc (~/.zshrc):

       alias fusion-codex='codex --sandbox danger-full-access --ask-for-approval never'

  2. Inside codex, run:

       /fusion <your question or task>

     (If your codex build namespaces custom prompts, type "/" then "fusion" — it may show as
      /prompts:fusion. Restart codex once so it picks up the new prompt.)

  Headless one-shot from a normal shell (no TUI, no slash command) — the runner needs no sandbox flags
  because a plain shell is already unsandboxed:

       bash codex/fusion-runner.sh "your question or task"
NEXT
