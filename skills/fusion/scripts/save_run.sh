#!/usr/bin/env bash
# save_run.sh — write the provenance .md for one Fusion run, under ~/.claude/fusion-runs/.
#
# Usage:
#   save_run.sh <slug> <question_file> <analysis_file> <final_file> [LABEL=path ...]
#
# - <slug>           : the panel identity for the filename/header. Use what ACTUALLY ran:
#                      opus4.8x2-gpt5.5 for the full panel, or a degraded slug like opus4.8x2 if a seat dropped.
# - <question_file>  : the user's question, verbatim
# - <analysis_file>  : the judge's structured analysis (GPT-5.5 judge output)
# - <final_file>     : the grounded final answer (Opus 4.8 synthesizer output)
# - LABEL=path       : one per panelist, raw answer file. For this build's 3 panelists:
#                      "opus-A=<PDIR>/opus1.md" "opus-B=<PDIR>/opus2.md" "gpt5.5=<PDIR>/gpt.md"
#                      (a missing/empty file is recorded as a placeholder, so a degraded panel still
#                       produces a complete record). With <analysis_file> (= judge) and <final_file>
#                       (= synth) this captures all five seats.
#
# Optional env:
#   FUSION_PANEL_NOTE  degradation note (e.g. "gpt5.5 dropped: codex timed out -> opus-only")
#   FUSION_JUDGE_LABEL which CLI actually judged (e.g. "GPT-5.5 (codex, xhigh)" or an Opus fallback).
#                      Default "GPT-5.5 judge" — the Claude Code path always judges with GPT-5.5 (codex).
#   FUSION_ESTIMATE    the preflight estimate string, for the record
#   FUSION_NO_SAVE     set to any non-empty value to SKIP provenance entirely (nothing hits disk)
#
# Output: prints the path of the .md it wrote. Writes ONLY under ~/.claude/fusion-runs/.
#
# PRIVACY: this record contains the verbatim question and every raw panelist answer in cleartext on
# local disk. The file is written 0600 (owner-only) inside a 0700 dir. For sensitive or confidential
# work, set FUSION_NO_SAVE=1 to disable the record, or prune ~/.claude/fusion-runs/ afterward.

set -uo pipefail

# Opt-out first, before any required-arg checks, so FUSION_NO_SAVE always disables cleanly.
if [ -n "${FUSION_NO_SAVE:-}" ]; then
  echo "[save_run.sh] FUSION_NO_SAVE set — provenance recording skipped (nothing written to disk)." >&2
  exit 0
fi

slug="${1:?usage: save_run.sh <slug> <question_file> <analysis_file> <final_file> [LABEL=path ...]}"
question_file="${2:?need question_file}"
analysis_file="${3:?need analysis_file}"
final_file="${4:?need final_file}"
shift 4

# Owner-only perms for everything we create (dir 0700, file 0600).
umask 077

RUNS_DIR="$HOME/.claude/fusion-runs"
mkdir -p "$RUNS_DIR"
# umask only governs perms at CREATE time; if the dir already existed with looser perms, tighten it now.
chmod 700 "$RUNS_DIR" 2>/dev/null || true
ts="$(date +%Y-%m-%d_%H%M%S)"
out="$RUNS_DIR/${ts}_${slug}.md"

emit_file() {
  if [ -f "$1" ] && [ -s "$1" ]; then
    cat "$1"
    # guarantee a trailing newline so the next markdown block is never glued on
    [ -n "$(tail -c1 "$1")" ] && echo
  else
    echo "_(empty / not available)_"
  fi
}

# Longest run of backticks in a file (0 if none / file absent). Used to size the question's code fence so
# a question that itself contains ``` can't terminate the fenced block early and corrupt the audit markdown.
longest_backtick_run() {
  if [ -f "$1" ]; then
    grep -oE '`+' "$1" 2>/dev/null | awk 'BEGIN{m=0} {if(length($0)>m)m=length($0)} END{print m}'
  else
    echo 0
  fi
}

qrun="$(longest_backtick_run "$question_file")"
fence_n=$(( qrun + 1 ))
[ "$fence_n" -lt 3 ] && fence_n=3
qfence="$(printf "%${fence_n}s" "" | tr ' ' '`')"

{
  echo "# Fusion run — $ts"
  echo
  echo "- **Panel run** : \`$slug\`"
  [ -n "${FUSION_PANEL_NOTE:-}" ] && echo "- **Degradation** : ${FUSION_PANEL_NOTE}"
  [ -n "${FUSION_ESTIMATE:-}" ]   && echo "- **Estimate (preflight)** : ${FUSION_ESTIMATE}"
  echo
  echo "## Question (verbatim)"
  echo
  echo "$qfence"
  emit_file "$question_file"
  echo "$qfence"
  echo
  echo "## Raw panelist answers"
  if [ "$#" -eq 0 ]; then
    echo
    echo "_(no panelist provided)_"
  fi
  for spec in "$@"; do
    label="${spec%%=*}"
    path="${spec#*=}"
    echo
    echo "### $label"
    echo
    emit_file "$path"
    echo
  done
  echo "## Analysis — ${FUSION_JUDGE_LABEL:-GPT-5.5 judge} (consensus / contradictions / partial coverage / unique insights / blind spots)"
  echo
  emit_file "$analysis_file"
  echo
  echo "## Final answer — Opus 4.8 synthesizer"
  echo
  emit_file "$final_file"
  echo
} > "$out"

# Belt-and-suspenders: umask covers new files, but force 0600 in case the file already existed.
chmod 600 "$out" 2>/dev/null || true

echo "$out"
