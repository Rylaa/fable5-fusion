#!/usr/bin/env bash
# detect_panel.sh — verify the CLIs the Fusion panel needs before a run.
#
# Panel (fixed):
#   Panelists: 2x Claude Opus 4.8 (run_claude.sh, claude -p, LOCKED max) + 1x GPT-5.5 (run_codex.sh, LOCKED xhigh)
#   Judge: GPT-5.5 (run_codex.sh, xhigh / priority "fast" tier).  Synthesizer: Claude Opus 4.8 (run_claude.sh, LOCKED max).
#   => `claude` runs the Opus panelists + the Opus synthesizer; `codex` runs the GPT-5.5 panelist + the GPT-5.5 judge.
#      BOTH `claude` and `codex` are required for the full panel.
#
# Output: human-readable lines + a final `PANEL=ready|degraded` line the orchestrator can grep,
# plus `CLAUDE=...` and `CODEX=...` lines.

have() { command -v "$1" >/dev/null 2>&1; }

echo "fusion panel: 2x Opus 4.8 (claude -p, max) + 1x GPT-5.5 (codex, xhigh)  |  judge: GPT-5.5 (codex, xhigh/fast)  |  synth: Opus 4.8 (claude -p, max)"

claude_ok=0
if have claude; then
  echo "  claude  : found ($(claude --version 2>/dev/null | head -1)) — Opus 4.8 panelists + synthesizer run via run_claude.sh at max"
  echo "CLAUDE=ready"
  claude_ok=1
else
  echo "  claude  : NOT found on PATH — run_claude.sh cannot run the Opus panelists/synthesizer at locked max"
  echo "  (fallback: Agent-tool panelists at session effort, not max; orchestrator writes the final answer itself)"
  echo "CLAUDE=missing"
fi

codex_ok=0
if have codex; then
  echo "  codex   : found ($(codex --version 2>/dev/null | head -1)) — GPT-5.5 panelist + judge ready"
  echo "CODEX=ready"
  codex_ok=1
else
  echo "  codex   : NOT found — the GPT-5.5 panelist and the GPT-5.5 judge cannot run"
  echo "  (fallback: the judge runs on Opus instead; install + log in to codex for the full panel)"
  echo "CODEX=missing"
fi

if [ "$claude_ok" = 1 ] && [ "$codex_ok" = 1 ]; then
  echo "PANEL=ready"
else
  echo "PANEL=degraded"
fi
