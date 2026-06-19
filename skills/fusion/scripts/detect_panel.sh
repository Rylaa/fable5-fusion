#!/usr/bin/env bash
# detect_panel.sh — verify the CLIs the Fusion panel needs before a run.
#
# Panel (fixed): 2x Claude Opus 4.8 (Agent subagents, always available) + 1x GPT-5.5 (codex).
# Judge: Claude Opus 4.8 (the orchestrator). Synthesizer: GPT-5.5 (codex).
# => the `codex` CLI is REQUIRED (it runs the 1 GPT-5.5 panelist AND the synthesizer).
#
# Output: human-readable lines + a final `CODEX=ready|missing` line the orchestrator can grep.

have() { command -v "$1" >/dev/null 2>&1; }

echo "fusion panel: 2x Opus 4.8 (Agent) + 1x GPT-5.5 (codex)  |  judge: Opus 4.8  |  synth: GPT-5.5 (codex)"
echo "  opus4.8 : yes (Agent subagents — always available, also judge)"

if have codex; then
  echo "  codex   : found ($(codex --version 2>/dev/null | head -1)) — GPT-5.5 panelist + synthesizer ready"
  echo "CODEX=ready"
else
  echo "  codex   : NOT found — the GPT-5.5 panelist and the GPT-5.5 synthesizer cannot run"
  echo "  install + log in to the codex CLI, or fall back to an Opus-4.8-only panel"
  echo "CODEX=missing"
fi
