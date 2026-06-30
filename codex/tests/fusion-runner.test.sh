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
  cat > "$SCR/run_claude.sh" <<EOF
#!/usr/bin/env bash
echo "run_claude out=\$(basename "\$2") effort=\$3 model=\${4:-_} prompt=\$(basename "\$1")" >> "$CALLOG"
printf 'FAKE-CLAUDE-ANSWER for %s\n(stub)\n' "\$(basename "\$2")" > "\$2"
exit 0
EOF

  # run_codex.sh <prompt> <out> <effort>  — record call + write a fake answer.
  cat > "$SCR/run_codex.sh" <<EOF
#!/usr/bin/env bash
echo "run_codex out=\$(basename "\$2") effort=\$3 prompt=\$(basename "\$1")" >> "$CALLOG"
printf 'FAKE-CODEX-ANSWER for %s\n(stub)\n' "\$(basename "\$2")" > "\$2"
exit 0
EOF

  # save_run.sh <slug> <q> <analysis> <final> [LABEL=path...] — record slug, print a fake path on stdout.
  cat > "$SCR/save_run.sh" <<EOF
#!/usr/bin/env bash
echo "save slug=\$1 note=\${FUSION_PANEL_NOTE:-} nargs=\$#" >> "$CALLOG"
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
echo "================================"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" = 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
