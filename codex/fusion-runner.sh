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
#   FUSION_TIMEOUT=3600 bash fusion-runner.sh "heavy deep-research task"
#
# KNOBS (env)
#   FUSION_SCRIPTS          override the plugin scripts dir (else auto-resolved).
#   FUSION_TIMEOUT          per-seat budget, seconds (default 1800). Exported to every seat.
#   FUSION_OPUS_SERIAL      run the 2 Opus seats one-at-a-time (default 1) instead of both at once, so the
#                           shared Anthropic rate-limit pool isn't saturated by a burst. 0 = parallel (faster).
#   FUSION_OPUS_SEATS       how many Opus panelists to run: 2 (default) or 1 (degraded, under a tight cap).
#   FUSION_SEAT_RETRIES     run_claude.sh retries on a rate-limit signature (default 2; 0 disables): a
#                           rate-limited seat backs off (FUSION_SEAT_RETRY_BACKOFF, default 20s, +jitter) and
#                           retries — a real timeout (124) or a non-rate-limit crash is never retried.
#   FUSION_JUDGE_CLI        which CLI judges: auto (default; codex then claude), codex (codex only),
#                           or claude (Opus judge from the start — cuts codex contention under a heavy cap).
#   FUSION_SYNTH_MODEL      model id for the synth seat only (e.g. claude-opus-4-8[1m] for the
#                           1M-context window on a big Track-A merge). Default: run_claude.sh's default.
#   FUSION_SERVICE_TIER     codex service tier for the GPT-5.5 seats (run_codex.sh). Default 'priority'
#                           (fast). Set EMPTY (FUSION_SERVICE_TIER=) to fall back to ~/.codex/config.toml
#                           — drops priority-forcing, which is steadier on a subscription-auth'd codex.
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
case "$PROGRESS_INTERVAL" in ''|*[!0-9]*) PROGRESS_INTERVAL=20 ;; *) [ "$PROGRESS_INTERVAL" -ge 1 ] 2>/dev/null || PROGRESS_INTERVAL=20 ;; esac

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
labels=(); pids=(); files=(); rc_cap=(); starts=()
launch() {  # launch <label> <runner> <out> <effort>
  local label="$1" runner="$2" out="$3" effort="$4"
  bash "$FUSION_SCRIPTS/$runner" "$PDIR/prompt.md" "$out" "$effort" >>"$PDIR/seat.log" 2>&1 &
  labels+=("$label"); pids+=("$!"); files+=("$out"); rc_cap+=(""); starts+=("$(date +%s)")
  log "  launched $label (pid $!)"
}
reap() {  # reap <idx> — wait the seat ONCE and cache its exit code; idempotent (safe to call again).
  local idx="$1"                            # NB: a 2nd `wait` on a reaped PID returns 127 in bash and would
  [ -n "${rc_cap[$idx]}" ] && return 0      # corrupt the seat's real status — so cache it, never re-wait.
  wait "${pids[$idx]}"; rc_cap[$idx]=$?
}
_elapsed() {  # _elapsed <start_epoch> -> "Nm SSs"
  local s=$(( $(date +%s) - ${1:-0} )); [ "$s" -lt 0 ] && s=0
  printf '%dm%02ds' "$(( s / 60 ))" "$(( s % 60 ))"
}
# A live seat produces NO interim output — `claude -p --output-format text` writes its answer only at the
# very end — so silence is NORMAL, not a hang. Emit a strong, elapsed-stamped heartbeat that PROVES the seat
# is alive, so no external watcher (codex, a harness) abandons a slow-but-working seat and closes early.
# Liveness is read from the process (kill -0), never inferred from elapsed time; a live seat is only ever
# ended by its own FUSION_TIMEOUT (exit 124), never by "it's been quiet too long".
alive_heartbeat() {  # alive_heartbeat <idx> — print a heartbeat iff the seat is still alive
  local idx="$1"
  kill -0 "${pids[$idx]}" 2>/dev/null || return 1
  log "  still working: ${labels[$idx]} ($(_elapsed "${starts[$idx]}") elapsed) — no interim output is normal at max effort; a live seat is NOT frozen. Waiting up to ${FUSION_TIMEOUT}s per seat before it is treated as timed out; do not abort."
}
# GPT-5.5 (codex) is a SEPARATE provider (OpenAI) — it never touches the Anthropic rate-limit pool, so it
# always runs in parallel. The two Opus seats DO share one Anthropic pool; launching both at once is what
# saturates it under load (overlapping panels) and gets them killed together. So by default run the Opus
# seats SERIALLY (FUSION_OPUS_SERIAL=1): Opus run 2 starts only after Opus run 1 finishes — one Anthropic
# seat at a time, while GPT-5.5 overlaps for free. FUSION_OPUS_SERIAL=0 launches both at once (faster, but
# reintroduces the burst). FUSION_OPUS_SEATS=1 runs a single Opus seat (degraded panel under a tight cap).
opus_seats="${FUSION_OPUS_SEATS:-2}"; case "$opus_seats" in 1|2) ;; *) opus_seats=2 ;; esac
if [ "$codex_ok" = 1 ]; then
  launch "GPT-5.5"    run_codex.sh  "$PDIR/gpt.md"   xhigh
fi
if [ "$claude_ok" = 1 ]; then
  launch "Opus run 1" run_claude.sh "$PDIR/opus1.md" max
  if [ "$opus_seats" -ge 2 ]; then
    if [ "${FUSION_OPUS_SERIAL:-1}" = 1 ]; then
      # Serial handoff: finish Opus run 1 before starting Opus run 2 — but NEVER with a silent `wait`. A
      # plain wait here blocks for the seat's whole (multi-minute, output-less) runtime, and that dead-silent
      # window is exactly what an external watcher misreads as a hang. So poll + heartbeat until it exits.
      o1_idx=$(( ${#pids[@]} - 1 ))
      while kill -0 "${pids[$o1_idx]}" 2>/dev/null; do
        alive_heartbeat "$o1_idx"
        sleep "$PROGRESS_INTERVAL"
      done
      reap "$o1_idx"                          # cache its rc (idempotent)
      log "  Opus run 1 finished (serial) — launching Opus run 2"
    fi
    launch "Opus run 2" run_claude.sh "$PDIR/opus2.md" max
  fi
fi

# Poll for completions so the foreground run streams progress instead of looking frozen.
n="${#pids[@]}"
done_mark=(); i=0; while [ "$i" -lt "$n" ]; do done_mark+=(0); i=$((i+1)); done
remaining="$n"
while [ "$remaining" -gt 0 ]; do
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${done_mark[$i]}" = 0 ]; then
      if kill -0 "${pids[$i]}" 2>/dev/null; then
        alive_heartbeat "$i"                  # strong, elapsed-stamped "still working" — never looks frozen
      else
        done_mark[$i]=1; remaining=$((remaining-1))
        log "  ${labels[$i]} finished"
      fi
    fi
    i=$((i+1))
  done
  [ "$remaining" -le 0 ] && break
  sleep "$PROGRESS_INTERVAL"
done

# Collect real exit codes and report each seat.
i=0; n_ok=0
while [ "$i" -lt "$n" ]; do
  reap "$i"; rc="${rc_cap[$i]}"
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
# Judge CLI policy (FUSION_JUDGE_CLI): a single bad codex judge call must NOT silently degrade the run
# to a judge-less synth, so the judge gets the same cross-family fallback the synth already has.
#   auto   (default) cross-family: try codex (GPT-5.5, xhigh); if it fails/absent, retry on claude (Opus, max).
#   codex            codex only — no claude retry (fail -> placeholder).
#   claude           Opus judge from the start (skips codex entirely) — cuts codex contention under a heavy cap.
log "Step 3 — judging (analysis only)..."
{
  printf '# Task (verbatim)\n\n'; cat "$PDIR/question.md"
  printf '\n# Panel answer — Opus run 1\n\n'; emit "$PDIR/opus1.md"
  printf '\n# Panel answer — Opus run 2\n\n'; emit "$PDIR/opus2.md"
  printf '\n# Panel answer — GPT-5.5\n\n';    emit "$PDIR/gpt.md"
  printf '\n# Judge instructions\n\n'; cat "$FUSION_REFS/judge_rubric.md"
  printf '\nYou are the JUDGE. Produce the structured ANALYSIS only (follow the Judge sections of the rubric). Do NOT write the final deliverable.\n'
} > "$JDIR/judge_prompt.md"
judge_policy="${FUSION_JUDGE_CLI:-auto}"
case "$judge_policy" in auto|codex|claude) ;; *)
  log "  judge: FUSION_JUDGE_CLI='$judge_policy' unrecognized — using 'auto'"; judge_policy=auto ;;
esac
judge_ok=0; judge_cli=""; jrc=0

# Attempt 1 — codex GPT-5.5 (skipped when the policy forces claude, or codex isn't present).
if [ "$judge_policy" != claude ] && [ "$codex_ok" = 1 ]; then
  bash "$FUSION_SCRIPTS/run_codex.sh" "$JDIR/judge_prompt.md" "$JDIR/judge_out.md" xhigh >>"$JDIR/judge.log" 2>&1
  jrc=$?
  [ "$jrc" = 0 ] && [ -s "$JDIR/judge_out.md" ] && { judge_ok=1; judge_cli="GPT-5.5 (codex, xhigh)"; }
fi

# Attempt 2 — claude Opus, when codex didn't produce a judge and the policy allows claude (auto/claude,
# never codex). Under 'auto' this is the cross-family fallback; under 'claude' it is the first choice.
if [ "$judge_ok" = 0 ] && [ "$judge_policy" != codex ] && [ "$claude_ok" = 1 ]; then
  retry_label="Opus 4.8 (claude -p, max)"
  if [ "$judge_policy" = auto ] && [ "$codex_ok" = 1 ]; then
    log "  judge: codex failed (exit $jrc) — retrying on claude (Opus)"
    retry_label="Opus 4.8 (claude -p, max) — codex judge unavailable"
  fi
  bash "$FUSION_SCRIPTS/run_claude.sh" "$JDIR/judge_prompt.md" "$JDIR/judge_out.md" max >>"$JDIR/judge.log" 2>&1
  jrc=$?
  [ "$jrc" = 0 ] && [ -s "$JDIR/judge_out.md" ] && { judge_ok=1; judge_cli="$retry_label"; }
fi

if [ "$judge_ok" = 1 ]; then
  log "  judge: OK ($judge_cli)"
else
  log "  judge: FAILED (exit $jrc) — synthesizing directly from the panel answers"
  printf '%s\n' "_(judge analysis unavailable — the synthesizer derives the answer directly from the panel answers below)_" > "$JDIR/judge_out.md"
  judge_cli="none — judge unavailable"
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
# Cross-family synth fallback: if the Opus synth seat fails AT RUNTIME (e.g. rate-limited under load) and
# codex is healthy, retry the synthesis on GPT-5.5 — the symmetric twin of the judge's cross-family fallback
# (v1.4.1). Previously synth fell back to codex only when claude was ABSENT, so a runtime Opus failure (the
# common case when both Opus panelists also dropped to the same rate-limit pool) lost the merged answer.
if { [ "$src" != 0 ] || [ ! -s "$SDIR/synth_out.md" ]; } && [ "$claude_ok" = 1 ] && [ "$codex_ok" = 1 ]; then
  log "  synth: Opus failed (exit $src) — retrying synth on codex (GPT-5.5), cross-family"
  bash "$FUSION_SCRIPTS/run_codex.sh" "$SDIR/synth_prompt.md" "$SDIR/synth_out.md" xhigh >>"$SDIR/synth.log" 2>&1
  src=$?
  synth_cli="GPT-5.5 (codex, xhigh) — Opus synth unavailable"
fi
if [ "$src" = 0 ] && [ -s "$SDIR/synth_out.md" ]; then
  log "  synth: OK ($synth_cli)"
  synth_ok=1
else
  log "  synth: FAILED (exit $src) — emitting the judge analysis + raw panel answers instead"
  synth_ok=0
fi

# ---- Decide the panel slug + degradation note --------------------------------------------------
# Count what ACTUALLY produced output, so a dropped seat (incl. opus1 down / opus2 alive) is reported
# rather than passed off as a clean full panel.
note=""
o1=0; [ -s "$PDIR/opus1.md" ] && o1=1
o2=0; [ -s "$PDIR/opus2.md" ] && o2=1
gp=0; [ -s "$PDIR/gpt.md" ]   && gp=1
n_opus=$((o1 + o2))
if [ "$claude_ok" = 0 ]; then
  slug="gpt5.5-only"; note="claude missing — GPT-5.5-only panel + GPT-5.5 synth; install + log in to claude for the full panel"
elif [ "$codex_ok" = 0 ] || [ "$gp" = 0 ]; then
  slug="opus4.8x2"
  if [ "$codex_ok" = 0 ]; then
    note="codex missing — Opus-only panel (no GPT-5.5 panelist or judge)"
  else
    note="GPT-5.5 panelist dropped — Opus-only panel"
  fi
else
  # claude + codex both present and GPT survived: name the slug by how many Opus seats ACTUALLY produced,
  # so two dropped Opus seats read as `gpt5.5-only`, not a clean full panel.
  case "$n_opus" in
    2) slug="opus4.8x2-gpt5.5" ;;
    1) slug="opus4.8x1-gpt5.5" ;;
    *) slug="gpt5.5-only" ;;
  esac
fi
# A dropped Opus panelist — measured against how many we INTENDED to launch (opus_seats), so running
# FUSION_OPUS_SEATS=1 on purpose is NOT misreported as a drop. Surfaced even if the GPT-5.5 seat survived.
if [ "$claude_ok" = 1 ] && [ "$n_opus" -lt "$opus_seats" ]; then
  if [ "$n_opus" = 0 ]; then
    note="${note:+$note; }all Opus panelists dropped (ran with 0 of $opus_seats Opus seats)"
  else
    note="${note:+$note; }$(( opus_seats - n_opus )) of $opus_seats Opus panelists dropped"
  fi
fi
[ "$judge_ok" = 0 ] && note="${note:+$note; }judge seat failed — final answer synthesized WITHOUT the judge analysis"
[ "$synth_ok" = 0 ] && note="${note:+$note; }synthesizer seat failed — final answer not produced"

# ---- Step 5 — save provenance ------------------------------------------------------------------
log "Step 5 — saving provenance..."
final_for_record="$SDIR/synth_out.md"; [ "$synth_ok" = 0 ] && final_for_record="$JDIR/judge_out.md"
saved=""
if [ -n "${FUSION_NO_SAVE:-}" ]; then
  log "  FUSION_NO_SAVE set — provenance skipped (nothing written to disk)."
else
  saved="$(FUSION_PANEL_NOTE="$note" FUSION_JUDGE_LABEL="$judge_cli" bash "$FUSION_SCRIPTS/save_run.sh" \
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
  echo "Panel run: \`$slug\`   (judge: $judge_cli; synth: $synth_cli)"
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
