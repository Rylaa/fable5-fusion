#!/usr/bin/env bash
# detect_panel.sh — verify the CLIs the Fusion panel needs before a run.
#
# Panel (fixed):
#   2x Claude Opus 4.8  -> run_claude.sh  (claude -p, LOCKED --effort max)   => needs the `claude` CLI on PATH
#   1x GPT-5.5          -> run_codex.sh   (codex exec, LOCKED xhigh)         => needs the `codex` CLI
# Judge: Claude Opus 4.8 (the orchestrator). Synthesizer: GPT-5.5 (codex).
#   => BOTH `claude` and `codex` are required for the full panel.
#
# Output: human-readable lines + a final `PANEL=ready|degraded` line the orchestrator can grep,
# plus `CLAUDE=...` and `CODEX=...` lines.

have() { command -v "$1" >/dev/null 2>&1; }

echo "fusion panel: 2x Opus 4.8 (claude -p, locked max) + 1x GPT-5.5 (codex, xhigh)  |  judge: Opus 4.8  |  synth: GPT-5.5 (codex)"

claude_ok=0
if have claude; then
  echo "  claude  : found ($(claude --version 2>/dev/null | head -1)) — Opus 4.8 panelists run via run_claude.sh at --effort max"
  echo "CLAUDE=ready"
  claude_ok=1
else
  echo "  claude  : NOT found on PATH — run_claude.sh cannot lock the Opus panelists at max effort"
  echo "  (fallback: spawn the Opus panelists with the Agent tool, but they will inherit the session effort, not max)"
  echo "CLAUDE=missing"
fi

codex_ok=0
if have codex; then
  echo "  codex   : found ($(codex --version 2>/dev/null | head -1)) — GPT-5.5 panelist + synthesizer ready"
  echo "CODEX=ready"
  codex_ok=1
else
  echo "  codex   : NOT found — the GPT-5.5 panelist and the GPT-5.5 synthesizer cannot run"
  echo "  install + log in to the codex CLI, or fall back to an Opus-4.8-only panel"
  echo "CODEX=missing"
fi

if [ "$claude_ok" = 1 ] && [ "$codex_ok" = 1 ]; then
  echo "PANEL=ready"
else
  echo "PANEL=degraded"
fi
