#!/usr/bin/env bash
# fusion-runner.test.sh — prove fusion-runner.sh's orchestration WITHOUT calling real models.
#
# It stubs the five plugin scripts (detect_panel/preflight/run_claude/run_codex/save_run) with fakes
# that record how they were called, then asserts the runner: fans out the right seats, judges after
# the panel, synthesizes after the judge, picks the right CLI per seat (Opus synth when claude is
# present, GPT-5.5 synth when it isn't), chooses the right provenance slug, and rejects an empty task.
#
# Run:  bash codex/tests/fusion-runner.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HERE/../fusion-runner.sh"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found at $RUNNER"; exit 1; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   - %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL - %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

# Build a stub plugin tree:  $STUB/skills/fusion/{scripts,references}
make_stubs() {  # make_stubs <claude_state ready|missing> <codex_state ready|missing>
  local cl="$1" cx="$2"
  STUB="$(mktemp -d "${TMPDIR:-/tmp}/fusion-stub.XXXXXX")"
  SCR="$STUB/skills/fusion/scripts"; REF="$STUB/skills/fusion/references"
  mkdir -p "$SCR" "$REF"
  printf 'JUDGE RUBRIC (stub)\n' > "$REF/judge_rubric.md"
  printf 'PANEL (stub)\n'        > "$REF/panel.md"
  CALLOG="$STUB/calls.log"; : > "$CALLOG"

  cat > "$SCR/detect_panel.sh" <<EOF
#!/usr/bin/env bash
echo "detect" >> "$CALLOG"
echo "CLAUDE=$cl"
echo "CODEX=$cx"
if [ "$cl" = ready ] && [ "$cx" = ready ]; then echo "PANEL=ready"; else echo "PANEL=degraded"; fi
EOF

  cat > "$SCR/preflight.sh" <<EOF
#!/usr/bin/env bash
echo "preflight" >> "$CALLOG"
echo "preflight: stub estimate"
exit 0
EOF

  # run_claude.sh <prompt> <out> <effort> [model]  — record call + write a fake answer.
  # A judge call (out=judge_out.md) is force-failed when STUB_CLAUDE_JUDGE_FAIL is set, to exercise the
  # judge fallback/placeholder paths without real models. Non-judge calls (panelists, synth) are unaffected.
  cat > "$SCR/run_claude.sh" <<EOF
#!/usr/bin/env bash
echo "run_claude out=\$(basename "\$2") effort=\$3 model=\${4:-_} prompt=\$(basename "\$1")" >> "$CALLOG"
case "\$(basename "\$2")" in
  judge_out.md) [ -n "\${STUB_CLAUDE_JUDGE_FAIL:-}" ] && { echo "stub: claude judge forced-fail" >&2; exit 1; } ;;
  synth_out.md) [ -n "\${STUB_CLAUDE_SYNTH_FAIL:-}" ] && { echo "stub: claude synth forced-fail" >&2; exit 1; } ;;
  opus1.md|opus2.md)
    [ -n "\${STUB_CLAUDE_PANEL_FAIL:-}" ] && { echo "stub: claude panelist forced-fail" >&2; exit 1; }
    [ -n "\${STUB_CLAUDE_PANEL_SLEEP:-}" ] && sleep "\${STUB_CLAUDE_PANEL_SLEEP}" ;;
esac
printf 'FAKE-CLAUDE-ANSWER for %s\n(stub)\n' "\$(basename "\$2")" > "\$2"
exit 0
EOF

  # run_codex.sh <prompt> <out> <effort>  — record call + write a fake answer.
  # A judge call (out=judge_out.md) is force-failed when STUB_CODEX_JUDGE_FAIL is set, to exercise the
  # cross-family judge fallback. The GPT-5.5 *panelist* call (out=gpt.md) is unaffected.
  cat > "$SCR/run_codex.sh" <<EOF
#!/usr/bin/env bash
echo "run_codex out=\$(basename "\$2") effort=\$3 prompt=\$(basename "\$1")" >> "$CALLOG"
if [ "\$(basename "\$2")" = judge_out.md ] && [ -n "\${STUB_CODEX_JUDGE_FAIL:-}" ]; then
  echo "stub: codex judge forced-fail" >&2; exit 1
fi
printf 'FAKE-CODEX-ANSWER for %s\n(stub)\n' "\$(basename "\$2")" > "\$2"
exit 0
EOF

  # save_run.sh <slug> <q> <analysis> <final> [LABEL=path...] — record slug + judge label, print a fake path.
  cat > "$SCR/save_run.sh" <<EOF
#!/usr/bin/env bash
echo "save slug=\$1 note=\${FUSION_PANEL_NOTE:-} judgelabel=\${FUSION_JUDGE_LABEL:-} nargs=\$#" >> "$CALLOG"
echo "$STUB/fake-provenance.md"
EOF

  chmod +x "$SCR"/*.sh
}

run_runner() {  # run_runner <stdout_file> <task...>  ; uses current STUB
  FUSION_SCRIPTS="$SCR" FUSION_PROGRESS_INTERVAL=1 FUSION_NO_SAVE= \
    bash "$RUNNER" "$@" > "$1.out" 2> "$1.err"
  echo $?
}

echo "== syntax check =="
check "fusion-runner.sh parses" "bash -n '$RUNNER'"

echo
echo "== Test 1: full panel (claude+codex ready) =="
make_stubs ready ready
OUT="$STUB/t1"
rc="$(FUSION_SCRIPTS="$SCR" FUSION_PROGRESS_INTERVAL=1 bash "$RUNNER" "do the thing" >"$OUT.out" 2>"$OUT.err"; echo $?)"
check "exit 0"                              "[ '$rc' = 0 ]"
check "stdout has FINAL ANSWER banner"      "grep -q 'FUSION FINAL ANSWER' '$OUT.out'"
check "stdout has AUDIT TRAIL banner"       "grep -q 'FUSION AUDIT TRAIL' '$OUT.out'"
check "final answer is the synth output"    "grep -q 'FAKE-CLAUDE-ANSWER for synth_out.md' '$OUT.out'"
check "detect_panel was called"             "grep -q '^detect' '$CALLOG'"
check "preflight was called"                "grep -q '^preflight' '$CALLOG'"
check "panelist opus1 ran via run_claude"   "grep -q 'run_claude out=opus1.md effort=max' '$CALLOG'"
check "panelist opus2 ran via run_claude"   "grep -q 'run_claude out=opus2.md effort=max' '$CALLOG'"
check "panelist gpt ran via run_codex"      "grep -q 'run_codex out=gpt.md effort=xhigh' '$CALLOG'"
check "judge ran via run_codex (xhigh)"     "grep -q 'run_codex out=judge_out.md effort=xhigh' '$CALLOG'"
check "synth ran via run_claude (max)"      "grep -q 'run_claude out=synth_out.md effort=max' '$CALLOG'"
check "save slug = opus4.8x2-gpt5.5"        "grep -q 'save slug=opus4.8x2-gpt5.5 ' '$CALLOG'"
# order: judge must come AFTER all three panelists; synth AFTER the judge.
jline="$(grep -n 'out=judge_out.md' "$CALLOG" | head -1 | cut -d: -f1)"
sline="$(grep -n 'out=synth_out.md' "$CALLOG" | head -1 | cut -d: -f1)"
gline="$(grep -n 'out=gpt.md' "$CALLOG" | head -1 | cut -d: -f1)"
o1line="$(grep -n 'out=opus1.md' "$CALLOG" | head -1 | cut -d: -f1)"
o2line="$(grep -n 'out=opus2.md' "$CALLOG" | head -1 | cut -d: -f1)"
check "judge after opus1"  "[ '$jline' -gt '$o1line' ]"
check "judge after opus2"  "[ '$jline' -gt '$o2line' ]"
check "judge after gpt"    "[ '$jline' -gt '$gline' ]"
check "synth after judge"  "[ '$sline' -gt '$jline' ]"
rm -rf "$STUB"

echo
echo "== Test 2: empty task is rejected =="
make_stubs ready ready
rc="$(FUSION_SCRIPTS="$SCR" bash "$RUNNER" "   " >/dev/null 2>&1; echo $?)"
check "empty task exits 2"                  "[ '$rc' = 2 ]"
check "no seat was launched"                "[ ! -s '$CALLOG' ] || ! grep -q 'run_claude\\|run_codex' '$CALLOG'"
rm -rf "$STUB"

echo
echo "== Test 3: degraded — claude missing => GPT-5.5-only panel + GPT-5.5 synth =="
make_stubs missing ready
OUT="$STUB/t3"
rc="$(FUSION_SCRIPTS="$SCR" FUSION_PROGRESS_INTERVAL=1 bash "$RUNNER" "research X" >"$OUT.out" 2>"$OUT.err"; echo $?)"
check "exit 0"                              "[ '$rc' = 0 ]"
check "no opus panelist launched"           "! grep -q 'out=opus1.md' '$CALLOG'"
check "gpt panelist ran"                     "grep -q 'run_codex out=gpt.md' '$CALLOG'"
check "synth ran via run_codex (no claude)" "grep -q 'run_codex out=synth_out.md effort=xhigh' '$CALLOG'"
check "slug = gpt5.5-only"                  "grep -q 'save slug=gpt5.5-only' '$CALLOG'"
check "note mentions claude missing"        "grep -q 'note=.*claude missing' '$CALLOG'"
check "final answer present (codex synth)"  "grep -q 'FAKE-CODEX-ANSWER for synth_out.md' '$OUT.out'"
rm -rf "$STUB"

echo
echo "== Test 4: FUSION_SYNTH_MODEL is passed to the synth seat only =="
make_stubs ready ready
OUT="$STUB/t4"
rc="$(FUSION_SCRIPTS="$SCR" FUSION_PROGRESS_INTERVAL=1 FUSION_SYNTH_MODEL='claude-opus-4-8[1m]' bash "$RUNNER" "big merge" >"$OUT.out" 2>"$OUT.err"; echo $?)"
check "exit 0"                              "[ '$rc' = 0 ]"
check "synth got the 1M model"              "grep -q 'run_claude out=synth_out.md effort=max model=claude-opus-4-8\\[1m\\]' '$CALLOG'"
check "panelists did NOT get the 1M model"  "! grep -q 'run_claude out=opus1.md.*model=claude-opus-4-8\\[1m\\]' '$CALLOG'"
rm -rf "$STUB"

echo
echo "== Test 5: codex judge fails -> claude judge retry -> judge OK, no degradation note =="
make_stubs ready ready
OUT="$STUB/t5"
rc="$(FUSION_SCRIPTS="$SCR" FUSION_PROGRESS_INTERVAL=1 STUB_CODEX_JUDGE_FAIL=1 bash "$RUNNER" "do the thing" >"$OUT.out" 2>"$OUT.err"; echo $?)"
check "exit 0"                                "[ '$rc' = 0 ]"
check "codex judge was attempted"             "grep -q 'run_codex out=judge_out.md' '$CALLOG'"
check "claude judge retried (max)"            "grep -q 'run_claude out=judge_out.md effort=max' '$CALLOG'"
check "audit names the Opus judge fallback"   "grep -q 'codex judge unavailable' '$OUT.out'"
check "synth still ran after retry"           "grep -q 'run_claude out=synth_out.md effort=max' '$CALLOG'"
check "final answer = synth output"           "grep -q 'FAKE-CLAUDE-ANSWER for synth_out.md' '$OUT.out'"
check "NO judge-failure degradation note"     "! grep -q 'judge seat failed' '$OUT.out'"
check "slug stays full panel"                 "grep -q 'save slug=opus4.8x2-gpt5.5 ' '$CALLOG'"
check "provenance judge label = Opus retry"   "grep -q 'judgelabel=.*codex judge unavailable' '$CALLOG'"
# the cross-family retry must keep judge-after-panel / synth-after-judge ordering intact
jline="$(grep -n 'run_claude out=judge_out.md' "$CALLOG" | head -1 | cut -d: -f1)"
sline="$(grep -n 'out=synth_out.md' "$CALLOG" | head -1 | cut -d: -f1)"
gline="$(grep -n 'out=gpt.md' "$CALLOG" | head -1 | cut -d: -f1)"
check "claude judge after gpt panelist"       "[ '$jline' -gt '$gline' ]"
check "synth after the (retried) judge"       "[ '$sline' -gt '$jline' ]"
rm -rf "$STUB"

echo
echo "== Test 6: codex judge + claude judge both fail -> placeholder + visible degradation note =="
make_stubs ready ready
OUT="$STUB/t6"
rc="$(FUSION_SCRIPTS="$SCR" FUSION_PROGRESS_INTERVAL=1 STUB_CODEX_JUDGE_FAIL=1 STUB_CLAUDE_JUDGE_FAIL=1 bash "$RUNNER" "do the thing" >"$OUT.out" 2>"$OUT.err"; echo $?)"
check "exit 0"                                "[ '$rc' = 0 ]"
check "codex judge was attempted"             "grep -q 'run_codex out=judge_out.md' '$CALLOG'"
check "claude judge was attempted"            "grep -q 'run_claude out=judge_out.md effort=max' '$CALLOG'"
check "judge placeholder used"                "grep -q 'judge analysis unavailable' '$OUT.out'"
check "degradation note VISIBLE in output"    "grep -q 'judge seat failed' '$OUT.out'"
check "note says WITHOUT the judge analysis"  "grep -q 'WITHOUT the judge analysis' '$OUT.out'"
check "final answer still synthesized"        "grep -q 'FAKE-CLAUDE-ANSWER for synth_out.md' '$OUT.out'"
check "provenance note carries judge failure" "grep -q 'note=.*judge seat failed' '$CALLOG'"
rm -rf "$STUB"

echo
echo "== Test 7: FUSION_JUDGE_CLI=claude -> codex judge never attempted, Opus judges =="
make_stubs ready ready
OUT="$STUB/t7"
rc="$(FUSION_SCRIPTS="$SCR" FUSION_PROGRESS_INTERVAL=1 FUSION_JUDGE_CLI=claude bash "$RUNNER" "do the thing" >"$OUT.out" 2>"$OUT.err"; echo $?)"
check "exit 0"                                "[ '$rc' = 0 ]"
check "codex judge NEVER attempted"           "! grep -q 'run_codex out=judge_out.md' '$CALLOG'"
check "claude judge ran (max)"                "grep -q 'run_claude out=judge_out.md effort=max' '$CALLOG'"
check "GPT-5.5 panelist still ran via codex"  "grep -q 'run_codex out=gpt.md' '$CALLOG'"
check "audit judge label = clean Opus"        "grep -q 'judge: Opus 4.8 (claude -p, max);' '$OUT.out'"
check "no codex-unavailable suffix"           "! grep -q 'codex judge unavailable' '$OUT.out'"
check "final answer = synth output"           "grep -q 'FAKE-CLAUDE-ANSWER for synth_out.md' '$OUT.out'"
rm -rf "$STUB"

echo
echo "== Test 8: FUSION_OPUS_SEATS=1 -> single Opus seat, slug opus4.8x1-gpt5.5, no phantom drop =="
make_stubs ready ready
OUT="$STUB/t8"
rc="$(FUSION_SCRIPTS="$SCR" FUSION_PROGRESS_INTERVAL=1 FUSION_OPUS_SEATS=1 bash "$RUNNER" "do the thing" >"$OUT.out" 2>"$OUT.err"; echo $?)"
check "exit 0"                          "[ '$rc' = 0 ]"
check "opus1 launched"                  "grep -q 'run_claude out=opus1.md' '$CALLOG'"
check "opus2 NOT launched"              "! grep -q 'run_claude out=opus2.md' '$CALLOG'"
check "GPT-5.5 panelist ran"            "grep -q 'run_codex out=gpt.md' '$CALLOG'"
check "slug = opus4.8x1-gpt5.5"         "grep -q 'save slug=opus4.8x1-gpt5.5 ' '$CALLOG'"
check "no phantom 'dropped' note"       "! grep -qi 'dropped' '$CALLOG'"
rm -rf "$STUB"

echo
echo "== Test 9: Opus synth fails at runtime -> codex synth fallback (cross-family) =="
make_stubs ready ready
OUT="$STUB/t9"
rc="$(FUSION_SCRIPTS="$SCR" FUSION_PROGRESS_INTERVAL=1 STUB_CLAUDE_SYNTH_FAIL=1 bash "$RUNNER" "do the thing" >"$OUT.out" 2>"$OUT.err"; echo $?)"
check "exit 0"                              "[ '$rc' = 0 ]"
check "Opus synth attempted"                "grep -q 'run_claude out=synth_out.md' '$CALLOG'"
check "codex synth fallback attempted"      "grep -q 'run_codex out=synth_out.md' '$CALLOG'"
check "final answer = codex synth output"   "grep -q 'FAKE-CODEX-ANSWER for synth_out.md' '$OUT.out'"
check "synth NOT reported as failed"        "! grep -q 'synthesizer seat failed' '$OUT.out'"
rm -rf "$STUB"

echo
echo "== Test 10: both Opus panelists drop + GPT survives -> slug gpt5.5-only =="
make_stubs ready ready
OUT="$STUB/t10"
rc="$(FUSION_SCRIPTS="$SCR" FUSION_PROGRESS_INTERVAL=1 STUB_CLAUDE_PANEL_FAIL=1 bash "$RUNNER" "do the thing" >"$OUT.out" 2>"$OUT.err"; echo $?)"
check "exit 0 (GPT carried the panel)"  "[ '$rc' = 0 ]"
check "opus1 attempted"                 "grep -q 'run_claude out=opus1.md' '$CALLOG'"
check "opus2 attempted (serial)"        "grep -q 'run_claude out=opus2.md' '$CALLOG'"
check "slug = gpt5.5-only"              "grep -q 'save slug=gpt5.5-only ' '$CALLOG'"
check "drop surfaced in note"           "grep -qi 'all Opus panelists dropped' '$CALLOG'"
rm -rf "$STUB"

echo
echo "== Test 11: run_claude.sh rate-limit retry then recover (real script, fake claude) =="
RCL="$(cd "$(dirname "$RUNNER")/../skills/fusion/scripts" && pwd)/run_claude.sh"
T11="$(mktemp -d "${TMPDIR:-/tmp}/fusion-rc11.XXXXXX")"
mkdir -p "$T11/bin" "$T11/work"; cnt="$T11/attempts"; : > "$cnt"
cat > "$T11/bin/claude" <<EOF
#!/usr/bin/env bash
echo x >> "$cnt"
if [ "\$(wc -l < "$cnt" | tr -d ' ')" -lt 2 ]; then
  echo "API Error: 429 Server is temporarily limiting requests" >&2; exit 1
fi
printf 'RECOVERED-ANSWER\n'; exit 0
EOF
chmod +x "$T11/bin/claude"; printf 'tiny task\n' > "$T11/prompt.md"
( cd "$T11/work" && PATH="$T11/bin:$PATH" FUSION_SEAT_RETRY_BACKOFF=0 FUSION_SEAT_RETRIES=2 \
    bash "$RCL" "$T11/prompt.md" "$T11/out.md" max >/dev/null 2>"$T11/err" )
rc11=$?; n11="$(wc -l < "$cnt" | tr -d ' ')"
check "run_claude exit 0 after retry"   "[ '$rc11' = 0 ]"
check "made exactly 2 claude attempts"  "[ '$n11' = 2 ]"
check "recovered answer written"        "grep -q 'RECOVERED-ANSWER' '$T11/out.md'"
check "logged a rate-limit retry"       "grep -qi 'rate-limited' '$T11/err'"
rm -rf "$T11"

echo
echo "== Test 12: run_claude.sh does NOT retry a non-rate-limit crash =="
T12="$(mktemp -d "${TMPDIR:-/tmp}/fusion-rc12.XXXXXX")"
mkdir -p "$T12/bin" "$T12/work"; cnt2="$T12/attempts"; : > "$cnt2"
cat > "$T12/bin/claude" <<EOF
#!/usr/bin/env bash
echo x >> "$cnt2"
echo "TypeError: something genuinely broke" >&2; exit 1
EOF
chmod +x "$T12/bin/claude"; printf 'tiny task\n' > "$T12/prompt.md"
( cd "$T12/work" && PATH="$T12/bin:$PATH" FUSION_SEAT_RETRY_BACKOFF=0 FUSION_SEAT_RETRIES=2 \
    bash "$RCL" "$T12/prompt.md" "$T12/out.md" max >/dev/null 2>"$T12/err" )
rc12=$?; n12="$(wc -l < "$cnt2" | tr -d ' ')"
check "run_claude exit 1 (real failure)"  "[ '$rc12' = 1 ]"
check "made exactly 1 attempt (no retry)" "[ '$n12' = 1 ]"
rm -rf "$T12"

echo
echo "== Test 13: slow-but-alive serial Opus emits a strong heartbeat (not treated as stuck) =="
make_stubs ready ready
OUT="$STUB/t13"
rc="$(FUSION_SCRIPTS="$SCR" FUSION_PROGRESS_INTERVAL=1 STUB_CLAUDE_PANEL_SLEEP=3 bash "$RUNNER" "do the thing" >"$OUT.out" 2>"$OUT.err"; echo $?)"
check "exit 0"                               "[ '$rc' = 0 ]"
check "heartbeat 'still working' printed"    "grep -q 'still working:' '$OUT.err'"
check "heartbeat names the live seat"        "grep -q 'still working: Opus run 1' '$OUT.err'"
check "heartbeat carries an elapsed stamp"   "grep -qE 'still working: Opus run 1 \([0-9]+m[0-9][0-9]s elapsed\)' '$OUT.err'"
check "heartbeat reassures (not frozen)"     "grep -q 'no interim output is normal' '$OUT.err'"
check "heartbeat lands in the serial window" "grep -q 'launched Opus run 1' '$OUT.err' && grep -q 'Opus run 1 finished (serial)' '$OUT.err'"
check "slow Opus collected OK (not ABSENT)"  "grep -q 'Opus run 1: OK' '$OUT.err'"
check "slug is still the full panel"         "grep -q 'save slug=opus4.8x2-gpt5.5 ' '$CALLOG'"
check "no heartbeat leaks to stdout"         "! grep -q 'still working' '$OUT.out'"
rm -rf "$STUB"

echo
echo "== Test 14: parallel mode (FUSION_OPUS_SERIAL=0) also emits the strong heartbeat =="
make_stubs ready ready
OUT="$STUB/t14"
rc="$(FUSION_SCRIPTS="$SCR" FUSION_PROGRESS_INTERVAL=1 FUSION_OPUS_SERIAL=0 STUB_CLAUDE_PANEL_SLEEP=3 bash "$RUNNER" "do the thing" >"$OUT.out" 2>"$OUT.err"; echo $?)"
check "exit 0"                               "[ '$rc' = 0 ]"
check "heartbeat printed in parallel mode"   "grep -q 'still working: Opus run' '$OUT.err'"
check "no serial-handoff line in parallel"   "! grep -q 'finished (serial)' '$OUT.err'"
check "both Opus collected OK"               "grep -q 'Opus run 1: OK' '$OUT.err' && grep -q 'Opus run 2: OK' '$OUT.err'"
rm -rf "$STUB"

echo
echo "================================"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" = 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
