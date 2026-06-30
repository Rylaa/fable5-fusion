#!/usr/bin/env bash
# preflight.sh — pre-run, NON-BLOCKING sanity check the orchestrator shows before fanning out.
#
# Usage:
#   preflight.sh [prompt_file]
#
# Prints a rough token estimate for this build's FIXED panel — 3 panelists (2x Opus 4.8 + 1x GPT-5.5) plus a
# GPT-5.5 judge and an Opus 4.8 synthesizer (5 locked seats) — the per-seat timeout, and a Codex cap
# reminder, so a heavy question doesn't surprise you. It NEVER blocks: the prompt file is optional, a missing
# or empty file is fine, and it ALWAYS exits 0. Informational only.

set -uo pipefail

prompt_file="${1:-}"

# Fixed panel for this build: 3 panelists (2x Opus 4.8 + 1x GPT-5.5) + 1 GPT-5.5 judge + 1 Opus 4.8 synth.
n_panel=3

words=0
if [ -n "$prompt_file" ] && [ -f "$prompt_file" ]; then
  words="$(wc -w < "$prompt_file" | tr -d ' ')"
fi
# ~1.3 tokens/word, very rough; output usually dwarfs input on deep questions.
in_tokens=$(( words * 4 / 3 ))

echo "preflight (informational — not a gate):"
echo "  panel        : 2x Opus 4.8 + 1x GPT-5.5  ($n_panel panelists + 1 GPT-5.5 judge + 1 Opus 4.8 synth = 5 locked seats)"
echo "  prompt size  : ~${words} words (~${in_tokens} input tokens) sent to EACH of the $n_panel panelists"
echo "  note         : each panelist also writes a full answer, the judge then reads all $n_panel, and the"
echo "                 synthesizer reads the analysis + all answers — real token cost is several× the input."
echo "                 The run is as slow as its slowest seat; deep-research questions are slow."
echo "  per-seat timeout : ${FUSION_TIMEOUT:-1800}s each (override with FUSION_TIMEOUT; raise it for deep research)"

if command -v claude >/dev/null 2>&1; then
  echo "  claude (Opus 4.8) : installed — 2 panelists + synthesizer run via run_claude.sh at locked max."
else
  echo "  claude (Opus 4.8) : NOT installed — Opus seats fall back (Agent-tool panelists at session effort,"
  echo "                      orchestrator writes the final answer). Install + log in for locked max."
fi

if command -v codex >/dev/null 2>&1; then
  echo "  codex (GPT-5.5)   : installed — quota isn't readable non-interactively; if a run fails on a cap,"
  echo "                      check '/status' inside codex. The panel degrades gracefully if a seat drops."
else
  echo "  codex (GPT-5.5)   : NOT installed — the GPT-5.5 panelist + judge are skipped; the judge falls back"
  echo "                      to the orchestrator. Install + log in to codex for the full panel."
fi

exit 0
