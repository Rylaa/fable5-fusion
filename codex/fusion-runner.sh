#!/usr/bin/env bash
# fusion-runner.sh — the Codex-side orchestrator for the fable5-fusion panel.
#
# WHY THIS EXISTS
#   The Claude Code path drives Fusion with a *model* orchestrator (Claude): it uses the Write tool
#   to author the panelist/judge/synth prompts and launches each seat runner as a background task,
#   getting a harness notification when each finishes. Codex has neither a Write tool nor that
#   background-task+notification layer — a codex agent only runs shell commands. Asking a codex
#   (GPT-5.5) orchestrator to reproduce SKILL.md Step 0-6 BY HAND (multiple heredocs per turn,
#   carrying literal mktemp paths across stateless shell calls) is fragile. So Steps 0-6 are encoded
#   here as ONE deterministic bash program. The codex slash command (`/fusion`) is THIN: it just
#   feeds this runner the task on stdin and presents the result.
#
#   The intelligence of Fusion lives in the SEATS (panelists / judge / synthesizer), not in the
#   orchestrator — the orchestrator is pure plumbing. Plumbing-in-bash loses nothing and gains
#   determinism, real parallelism, and per-seat timeouts for free.
#
# WHAT IT REUSES (verbatim — additive, never modifies the Claude Code plugin)
#   <plugin>/skills/fusion/scripts/{detect_panel,preflight,run_claude,run_codex,save_run}.sh
#   <plugin>/skills/fusion/references/{panel,judge_rubric}.md
#   The seat runners keep their OWN isolation/sandbox/timeout: run_claude.sh (throwaway repo copy +
#   bypassPermissions, locked --effort max) and run_codex.sh (-s workspace-write, xhigh, web search).
#   This script NEVER touches those files; it only calls them.
#
# ORCHESTRATOR SANDBOX REQUIREMENT (read this)
#   This script spawns `claude -p` and `codex exec` children that need network (model API + web
#   search). run_codex.sh applies its OWN `-s workspace-write` Seatbelt to each GPT-5.5 seat — and
#   macOS Seatbelt CANNOT be nested (a nested sandbox-exec dies with "sandbox_apply: Operation not
#   permitted"). So the codex orchestrator that calls this runner must run UN-sandboxed:
#       codex --sandbox danger-full-access --ask-for-approval never        (interactive)
#       codex exec --dangerously-bypass-approvals-and-sandbox              (headless; exec has NO
#                                                                           --ask-for-approval flag)
#   The seats keep their own sandbox regardless; only the orchestrator is unsandboxed, which also
#   lets the children reach the network. (You can run this runner directly from a normal,
#   un-sandboxed shell too — `bash fusion-runner.sh "task"` — with the same effect.)
#
# USAGE
#   bash fusion-runner.sh "your task"        # task from args
#   bash fusion-runner.sh < task.txt         # task from stdin (preferred for big tasks: no ARG_MAX)
#   FUSION_TIMEOUT=900 bash fusion-runner.sh "heavy deep-research task"
#
# KNOBS (env)
#   FUSION_SCRIPTS          override the plugin scripts dir (else auto-resolved).
#   FUSION_TIMEOUT          per-seat budget, seconds (default 1800). Exported to every seat.
#   FUSION_SYNTH_MODEL      model id for the synth seat only (e.g. claude-opus-4-8[1m] for the
#                           1M-context window on a big Track-A merge). Default: run_claude.sh's default.
#   FUSION_NO_SAVE          set to any value to skip the provenance record (nothing hits disk).
#   FUSION_PROGRESS_INTERVAL seconds between "still running" progress lines (default 20).
#
# Bash 3.2 safe (macOS default): no associative arrays, no `local -n`, no process substitution.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Progress + status go to STDERR so codex shows them live (a long run never looks frozen). Only the
# final user-facing result goes to STDOUT, so the orchestrator can relay stdout verbatim.
log() { printf '%s\n' "[fusion] $*" >&2; }

# Per-seat budget. The codex side defaults to 1800s (the plugin's operational default), vs the seat
# runners' own 300s fallback — a panel at max/xhigh routinely needs minutes. Exported so the nested
# run_claude.sh / run_codex.sh inherit it. User can override by setting FUSION_TIMEOUT in the env.
export FUSION_TIMEOUT="${FUSION_TIMEOUT:-1800}"
PROGRESS_INTERVAL="${FUSION_PROGRESS_INTERVAL:-20}"

# ---- Resolve the plugin scripts + references (first match wins) --------------------------------
FUSION_SCRIPTS="${FUSION_SCRIPTS:-}"
for _c in "$FUSION_SCRIPTS" \
          "$HOME/.claude/plugins/marketplaces/fable5-fusion/skills/fusion/scripts" \
          "$SELF_DIR/../skills/fusion/scripts"; do
  if [ -n "$_c" ] && [ -f "$_c/run_claude.sh" ]; then
    FUSION_SCRIPTS="$(cd "$_c" && pwd)"; break
  fi
done
if [ ! -f "$FUSION_SCRIPTS/run_claude.sh" ]; then
  log "FATAL: could not find the fusion plugin scripts (run_claude.sh)."
  log "       Install the fable5-fusion plugin in Claude Code, or export FUSION_SCRIPTS to its"
  log "       skills/fusion/scripts directory, then retry."
  exit 1
fi
FUSION_REFS="$(cd "$FUSION_SCRIPTS/.." && pwd)/references"
log "scripts: $FUSION_SCRIPTS"

# ---- Read the task (args win; else stdin) ------------------------------------------------------
if [ "$#" -gt 0 ]; then
  TASK="$*"
else
  TASK="$(cat)"
fi
# Reject an empty / whitespace-only task (mirrors the slash command's "ask once and stop").
if [ -z "$(printf '%s' "$TASK" | tr -d ' \t\n')" ]; then
  log "no task provided. Usage: bash fusion-runner.sh \"your task\"  (or pipe it on stdin)."
  exit 2
fi

# ---- Scratch dirs ------------------------------------------------------------------------------
PDIR="$(mktemp -d "${TMPDIR:-/tmp}/fusion-panel.XXXXXX")" || { log "mktemp failed"; exit 4; }
JDIR="$(mktemp -d "${TMPDIR:-/tmp}/fusion-judge.XXXXXX")" || { log "mktemp failed"; exit 4; }
SDIR="$(mktemp -d "${TMPDIR:-/tmp}/fusion-synth.XXXXXX")" || { log "mktemp failed"; exit 4; }
# Keep scratch on disk only as long as the run; the provenance record (Step 5) is the durable copy.
trap 'rm -rf "$PDIR" "$JDIR" "$SDIR"' EXIT

# 1) the user's task, VERBATIM (Step 5 records this; the seats read the wrapped prompt below).
printf '%s\n' "$TASK" > "$PDIR/question.md"

# 2) the panelist prompt = the verbatim task + a short independence instruction. The SAME prompt
#    goes to every panelist — no lenses, no pre-digesting (see references/panel.md).
{
  printf '%s\n' "$TASK"
  cat <<'PANEL_INSTR'

---
You are one of several independent experts answering the task above. You will NOT see the other
experts' answers, and they will not see yours. Research with web search and bash as needed, reason at
maximum depth, and return a complete, self-contained answer to the task. Answer it yourself — do not
delegate or spawn sub-agents.
PANEL_INSTR
} > "$PDIR/prompt.md"

# emit a file's contents, or an explicit absent marker (never silent agreement).
emit() { if [ -s "$1" ]; then cat "$1"; else printf '%s\n' "_(absent — seat dropped: empty / failed / timed out)_"; fi; }

# ---- Step 0 — verify the panel -----------------------------------------------------------------
log "Step 0 — detecting the panel..."
detect_out="$(bash "$FUSION_SCRIPTS/detect_panel.sh" 2>&1)"
printf '%s\n' "$detect_out" | sed 's/^/[fusion]   /' >&2
claude_ok=0; codex_ok=0
printf '%s\n' "$detect_out" | grep -q '^CLAUDE=ready' && claude_ok=1
printf '%s\n' "$detect_out" | grep -q '^CODEX=ready'  && codex_ok=1
if [ "$codex_ok" = 0 ] && [ "$claude_ok" = 0 ]; then
  log "FATAL: neither claude nor codex is available — no seat can run."
  exit 5
fi

# ---- Step 1 — preflight (informational; never a gate) ------------------------------------------
log "Step 1 — preflight estimate:"
bash "$FUSION_SCRIPTS/preflight.sh" "$PDIR/question.md" 2>&1 | sed 's/^/[fusion]   /' >&2

# ---- Step 2 — fan out the panel, parallel and blind --------------------------------------------
# Seats: 2x Opus 4.8 (run_claude.sh max) when claude is present, + 1x GPT-5.5 (run_codex.sh xhigh)
# when codex is present. Each is its own background process; we poll for live progress, then collect.
log "Step 2 — fanning out the panel (per-seat budget ${FUSION_TIMEOUT}s)..."
labels=(); pids=(); files=()
launch() {  # launch <label> <runner> <out> <effort>
  local label="$1" runner="$2" out="$3" effort="$4"
  bash "$FUSION_SCRIPTS/$runner" "$PDIR/prompt.md" "$out" "$effort" >>"$PDIR/seat.log" 2>&1 &
  labels+=("$label"); pids+=("$!"); files+=("$out")
  log "  launched $label (pid $!)"
}
if [ "$claude_ok" = 1 ]; then
  launch "Opus run 1" run_claude.sh "$PDIR/opus1.md" max
  launch "Opus run 2" run_claude.sh "$PDIR/opus2.md" max
fi
if [ "$codex_ok" = 1 ]; then
  launch "GPT-5.5"    run_codex.sh  "$PDIR/gpt.md"   xhigh
fi

# Poll for completions so the foreground run streams progress instead of looking frozen.
n="${#pids[@]}"
done_mark=(); i=0; while [ "$i" -lt "$n" ]; do done_mark+=(0); i=$((i+1)); done
remaining="$n"
while [ "$remaining" -gt 0 ]; do
  still=""
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${done_mark[$i]}" = 0 ]; then
      if kill -0 "${pids[$i]}" 2>/dev/null; then
        still="$still ${labels[$i]};"
      else
        done_mark[$i]=1; remaining=$((remaining-1))
        log "  ${labels[$i]} finished"
      fi
    fi
    i=$((i+1))
  done
  [ "$remaining" -le 0 ] && break
  [ -n "$still" ] && log "  still running:$still"
  sleep "$PROGRESS_INTERVAL"
done

# Collect real exit codes and report each seat.
i=0; n_ok=0
while [ "$i" -lt "$n" ]; do
  wait "${pids[$i]}"; rc=$?
  if [ "$rc" = 0 ] && [ -s "${files[$i]}" ]; then
    log "  ${labels[$i]}: OK ($(wc -c < "${files[$i]}" | tr -d ' ') bytes)"
    n_ok=$((n_ok+1))
  elif [ "$rc" = 124 ]; then
    log "  ${labels[$i]}: ABSENT (timed out after ${FUSION_TIMEOUT}s)"
  else
    log "  ${labels[$i]}: ABSENT (exit $rc / empty output)"
  fi
  i=$((i+1))
done
if [ "$n_ok" = 0 ]; then
  log "FATAL: every panelist dropped — nothing to judge or synthesize."
  log "       See $PDIR/seat.log for the seat logs (kept until this process exits)."
  exit 6
fi

# ---- Step 3 — judge (analysis only) ------------------------------------------------------------
# Judge CLI: prefer codex (GPT-5.5, cross-family); fall back to claude only if codex is absent.
log "Step 3 — judging (analysis only)..."
{
  printf '# Task (verbatim)\n\n'; cat "$PDIR/question.md"
  printf '\n# Panel answer — Opus run 1\n\n'; emit "$PDIR/opus1.md"
  printf '\n# Panel answer — Opus run 2\n\n'; emit "$PDIR/opus2.md"
  printf '\n# Panel answer — GPT-5.5\n\n';    emit "$PDIR/gpt.md"
  printf '\n# Judge instructions\n\n'; cat "$FUSION_REFS/judge_rubric.md"
  printf '\nYou are the JUDGE. Produce the structured ANALYSIS only (follow the Judge sections of the rubric). Do NOT write the final deliverable.\n'
} > "$JDIR/judge_prompt.md"
if [ "$codex_ok" = 1 ]; then
  bash "$FUSION_SCRIPTS/run_codex.sh"  "$JDIR/judge_prompt.md" "$JDIR/judge_out.md" xhigh >>"$JDIR/judge.log" 2>&1
else
  bash "$FUSION_SCRIPTS/run_claude.sh" "$JDIR/judge_prompt.md" "$JDIR/judge_out.md" max   >>"$JDIR/judge.log" 2>&1
fi
jrc=$?
if [ "$jrc" = 0 ] && [ -s "$JDIR/judge_out.md" ]; then
  log "  judge: OK"
else
  log "  judge: FAILED (exit $jrc) — synthesizing directly from the panel answers"
  printf '%s\n' "_(judge analysis unavailable — the synthesizer derives the answer directly from the panel answers below)_" > "$JDIR/judge_out.md"
fi

# ---- Step 4 — synthesize the ONE final answer --------------------------------------------------
# Synth CLI: prefer claude (Opus 4.8); fall back to codex (GPT-5.5) only if claude is absent.
log "Step 4 — synthesizing the final answer..."
{
  printf '# Task (verbatim)\n\n'; cat "$PDIR/question.md"
  printf '\n# Judge analysis\n\n'; emit "$JDIR/judge_out.md"
  printf '\n# Panel answer — Opus run 1\n\n'; emit "$PDIR/opus1.md"
  printf '\n# Panel answer — Opus run 2\n\n'; emit "$PDIR/opus2.md"
  printf '\n# Panel answer — GPT-5.5\n\n';    emit "$PDIR/gpt.md"
  printf '\n# Synthesizer instructions\n\n'; cat "$FUSION_REFS/judge_rubric.md"
  printf '\nYou are the SYNTHESIZER. Follow the Synthesizer track of the rubric and write the ONE final deliverable (Track A: run/merge the candidates in your trusted copy until they pass; Track B: derive the answer from the judge analysis). Output ONLY the final deliverable.\n'
} > "$SDIR/synth_prompt.md"
if [ "$claude_ok" = 1 ]; then
  if [ -n "${FUSION_SYNTH_MODEL:-}" ]; then
    bash "$FUSION_SCRIPTS/run_claude.sh" "$SDIR/synth_prompt.md" "$SDIR/synth_out.md" max "$FUSION_SYNTH_MODEL" >>"$SDIR/synth.log" 2>&1
  else
    bash "$FUSION_SCRIPTS/run_claude.sh" "$SDIR/synth_prompt.md" "$SDIR/synth_out.md" max >>"$SDIR/synth.log" 2>&1
  fi
  synth_cli="Opus 4.8 (claude -p, max)"
else
  bash "$FUSION_SCRIPTS/run_codex.sh" "$SDIR/synth_prompt.md" "$SDIR/synth_out.md" xhigh >>"$SDIR/synth.log" 2>&1
  synth_cli="GPT-5.5 (codex, xhigh) — Opus unavailable"
fi
src=$?
if [ "$src" = 0 ] && [ -s "$SDIR/synth_out.md" ]; then
  log "  synth: OK ($synth_cli)"
  synth_ok=1
else
  log "  synth: FAILED (exit $src) — emitting the judge analysis + raw panel answers instead"
  synth_ok=0
fi

# ---- Decide the panel slug + degradation note --------------------------------------------------
note=""
if [ "$claude_ok" = 1 ] && [ "$codex_ok" = 1 ] && [ -s "$PDIR/gpt.md" ] && [ -s "$PDIR/opus1.md" ]; then
  slug="opus4.8x2-gpt5.5"
elif [ "$claude_ok" = 0 ]; then
  slug="gpt5.5-only"; note="claude missing — GPT-5.5-only panel + GPT-5.5 synth; install + log in to claude for the full panel"
elif [ ! -s "$PDIR/gpt.md" ]; then
  slug="opus4.8x2"; note="GPT-5.5 panelist dropped — Opus-only panel"
else
  slug="opus4.8x2-gpt5.5"
fi
[ "$synth_ok" = 0 ] && note="${note:+$note; }synthesizer seat failed — final answer not produced"

# ---- Step 5 — save provenance ------------------------------------------------------------------
log "Step 5 — saving provenance..."
final_for_record="$SDIR/synth_out.md"; [ "$synth_ok" = 0 ] && final_for_record="$JDIR/judge_out.md"
saved=""
if [ -n "${FUSION_NO_SAVE:-}" ]; then
  log "  FUSION_NO_SAVE set — provenance skipped (nothing written to disk)."
else
  saved="$(FUSION_PANEL_NOTE="$note" bash "$FUSION_SCRIPTS/save_run.sh" \
    "$slug" "$PDIR/question.md" "$JDIR/judge_out.md" "$final_for_record" \
    "opus-A=$PDIR/opus1.md" "opus-B=$PDIR/opus2.md" "gpt5.5=$PDIR/gpt.md" 2>>"$SDIR/save.log")"
  [ -n "$saved" ] && log "  saved: $saved"
fi

# ---- Step 6 — present (stdout: final answer first, then the audit trail) ------------------------
log "Step 6 — done. Presenting result on stdout."
{
  echo "===== FUSION FINAL ANSWER ====="
  echo
  if [ "$synth_ok" = 1 ]; then
    cat "$SDIR/synth_out.md"
  else
    echo "_(The synthesizer seat failed, so no merged final answer was produced. The judge analysis and"
    echo "the raw panel answers are in the audit trail below — use them directly.)_"
  fi
  echo
  echo "===== FUSION AUDIT TRAIL ====="
  echo
  echo "Panel run: \`$slug\`   (synth: $synth_cli)"
  [ -n "$note" ] && echo "Degradation: $note"
  [ -n "$saved" ] && echo "Provenance: $saved"
  [ -z "$saved" ] && [ -n "${FUSION_NO_SAVE:-}" ] && echo "Provenance: skipped (FUSION_NO_SAVE)"
  echo
  echo "## Judge analysis"
  echo
  emit "$JDIR/judge_out.md"
  echo
  echo "## Raw panel answers"
  echo
  echo "### Opus run 1"; echo; emit "$PDIR/opus1.md"; echo
  echo "### Opus run 2"; echo; emit "$PDIR/opus2.md"; echo
  echo "### GPT-5.5";    echo; emit "$PDIR/gpt.md";   echo
}
