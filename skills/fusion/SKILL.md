---
name: fusion
description: >-
  Answer a hard task by fanning it out to a PANEL of three models running in parallel and blind —
  2× Claude Opus 4.8 + 1× GPT-5.5 (via codex, xhigh), each answering the task verbatim with web search and
  bash, none seeing the others' work. Then GPT-5.5 (via codex, xhigh) JUDGES all three answers
  into a structured analysis (consensus, contradictions, partial coverage, unique insights, blind spots),
  and a separate Claude Opus 4.8 SYNTHESIZER (via claude -p, max) writes the one final answer grounded in that analysis.
  Use whenever the user asks to "run it through Fusion", wants a multi-model / panel / ensemble answer,
  wants a question cross-checked across models, or wants a higher-confidence answer with consensus and
  blind spots surfaced — even if they don't say "fusion". Best for high-stakes research, design calls, and
  debugging where being confidently wrong is expensive.
---

# Fusion

Fusion turns one prompt into a panel. The task goes to several models **at the same time**, each answering
independently — with web search and bash, and with no knowledge of the others. Then GPT-5.5 (via codex) reads
every answer and extracts the structure of the panel's reasoning (what they agree on, where they conflict,
what only one saw, what they all missed), and a Claude Opus 4.8 synthesizer writes the final answer grounded
in that analysis.

The mechanism is **independence, then synthesis**. The diversity that makes a panel beat a single model is
harvested, not manufactured: running the same task independently yields different reasoning paths, tool
calls, and sources — even two cold runs of the *same* model diverge enough that synthesizing them beats
running it once. So there are no assigned "lenses" or personas; every panelist gets the user's task
verbatim and answers it straight. (See `references/panel.md`.)

## Fixed pipeline (this build)

| Seat | Model | CLI | Effort | Role |
|------|-------|-----|--------|------|
| Panelist 1 | Claude Opus 4.8 | `claude -p` (`run_claude.sh`) | `max` (locked) | independent answer |
| Panelist 2 | Claude Opus 4.8 | `claude -p` (`run_claude.sh`) | `max` (locked) | independent answer (2nd cold run) |
| Panelist 3 | GPT-5.5 | `codex` (`run_codex.sh`) | `xhigh` (locked) | independent answer |
| Judge | GPT-5.5 | `codex` (`run_codex.sh`) | `xhigh` (locked) | structured analysis — does NOT write the final answer |
| Synthesizer | Claude Opus 4.8 | `claude -p` (`run_claude.sh`) | `max` (locked) | writes the ONE final answer from the judge analysis |

> **Every reasoning seat is a locked subprocess; the orchestrator only coordinates.** All five seats run as
> wrapped runners at a fixed effort, so the Fusion session's own effort no longer affects output quality —
> the orchestrator just writes prompt files, launches the runners, and presents results; it does no judging
> or synthesis reasoning itself. The two Opus _panelists_ and the Opus _synthesizer_ are set to max
> explicitly: `run_claude.sh` exports `CLAUDE_CODE_EFFORT_LEVEL=max` (the **highest-precedence** effort knob
> — above the `--effort` flag and `settings.json`) **and** passes `--effort max`, so they hit max regardless
> of the session's inherited effort. (The `Agent` tool / agent-teams can't set a per-call effort, so the
> seats don't go through them.) The one thing that still wins over this is a `settings.json` `env` block
> pinning a different `CLAUDE_CODE_EFFORT_LEVEL`. The GPT-5.5 _panelist_ and the GPT-5.5 _judge_ are locked
> at `xhigh` in `run_codex.sh`. **Every seat is also time-bounded** — each runner wraps its CLI call in a
> per-seat timeout (`FUSION_TIMEOUT`, default 1800s) so one stuck seat can't hang the panel.

**The judge and the synthesizer are deliberately different seats.** GPT-5.5 (codex) analyzes the panel; a
separate Claude Opus 4.8 commits the final answer. Splitting "analyze" from "write" — and crossing model
families between them (GPT-5.5 judge / Opus synth) — keeps the final answer honest rather than one seat
defending its own draft. The judge can't be skipped and the synthesizer always runs last.

## Step 0 — Verify the panel

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/fusion/scripts/detect_panel.sh"
```

This panel needs **both CLIs installed and authenticated**: `claude` (the 2 Opus 4.8 panelists **and** the
Opus 4.8 synthesizer run as `claude -p` subprocesses, locked at max) and `codex` (the 1 GPT-5.5 panelist
**and** the GPT-5.5 judge, locked at xhigh). The detector prints `CLAUDE=ready|missing`, `CODEX=ready|missing`,
and a final `PANEL=ready|degraded`. Handle a degraded panel explicitly (don't silently change it):
- If `claude` is missing from PATH: the Opus **panelists and the Opus synthesizer** can't run at locked max
  — fall back to spawning the panelists with the `Agent` tool (session effort, **not** max) and have the
  orchestrator write the final answer itself (the Step 4 synth fallback).
- If `codex` is missing: the GPT-5.5 **panelist and the GPT-5.5 judge** can't run — the **judge falls back to
  the orchestrator** (the Step 3 judge fallback) and you lose the GPT-5.5 panelist; tell the user and offer to
  proceed with the Opus-only seats.

**Effort:** every reasoning seat is a **locked subprocess**, so the Fusion session's own effort no longer
affects output. The two Opus *panelists* and the Opus *synthesizer* are set to max by `run_claude.sh`, which
exports `CLAUDE_CODE_EFFORT_LEVEL=max` (the highest-precedence effort knob) **and** passes `--effort max`
(only a `settings.json` `env` pin of a different effort could override it). The GPT-5.5 *panelist* and the
GPT-5.5 *judge* are locked at `xhigh` in `run_codex.sh`. The orchestrator only coordinates — it writes the
prompt files, launches the runners, and presents results; it does no judging or synthesis reasoning itself.

## Step 1 — Preflight (informational, never a gate)

Write the user's task **verbatim** to a scratch file (you'll reuse it for the panel and the provenance
record), then show the preflight estimate:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/fusion/scripts/preflight.sh" /tmp/fusion_question.txt
```

Show its output to the user (a rough token estimate for the fixed 5-seat panel, the per-seat timeout, and a
Codex cap reminder), then proceed. It **never blocks** — it always exits 0, it only informs. Each seat is
bounded by a per-seat timeout (`FUSION_TIMEOUT`, default 1800s) baked into the runners; raise it for heavy
deep-research questions or big code merges (prefix the runner calls with `FUSION_TIMEOUT=3600`).

## Step 2 — Fan out: 2 Opus 4.8 (max) + 1 GPT-5.5 (xhigh), parallel and blind

Read `references/panel.md`. Build the panelist prompt as the user's task **verbatim** plus a short
instruction to research with web + bash and return a complete, self-contained answer as one of several
independent experts who won't see the others' work, reasoning at maximum depth and answering it themselves
(no delegation). Do not assign lenses; do not pre-digest the task. The **same** prompt goes to all three
seats — diversity comes from independence, not from different prompts.

Allocate one scratch dir, write the panelist prompt **once**, then launch **all three seats in the same
turn** so they run concurrently:

```bash
mktemp -d "${TMPDIR:-/tmp}/fusion-panel.XXXXXX"   # prints the panel dir — call it PDIR
```

Take the **literal** path it printed (a shell variable would not survive into your next Bash call) and use
it everywhere below as `PDIR`. Write the verbatim panelist prompt to `PDIR/prompt.md` with the **Write
tool**, and also write the user's **verbatim question** (without the panelist instruction wrapper) to
`PDIR/question.md` — Step 5 records it. Then launch the three runners as **background tasks** — a panel at
max/xhigh routinely runs many minutes, well past a foreground Bash timeout, so do **not** block on them.
Start all three in the **same turn** (each its own backgrounded Bash call) so they run concurrently:

```bash
# run each of these as a separate background Bash task, in one turn (substitute the real PDIR):
bash "${CLAUDE_PLUGIN_ROOT}/skills/fusion/scripts/run_claude.sh" "PDIR/prompt.md" "PDIR/opus1.md" max
bash "${CLAUDE_PLUGIN_ROOT}/skills/fusion/scripts/run_claude.sh" "PDIR/prompt.md" "PDIR/opus2.md" max
bash "${CLAUDE_PLUGIN_ROOT}/skills/fusion/scripts/run_codex.sh"  "PDIR/prompt.md" "PDIR/gpt.md"   xhigh
```

Each runner wraps its CLI call in a **per-seat timeout** (`_fusion_lib.sh`'s `_run_with_timeout`,
`FUSION_TIMEOUT` default **1800s**), so no single seat can hang the panel. You'll be notified as each
background task finishes — whether it completed, exited non-zero, or hit its timeout (**exit 124**). Read
that seat's output file then. While they run, keep the user posted on which seats are still going so the run
never looks frozen. Proceed to judging once all three have finished **or are confirmed absent**. For a heavy
deep-research question, raise the budget before launching (`FUSION_TIMEOUT=3600 bash …/run_*.sh …`) so a
slow-but-valid seat isn't killed.

- **Opus 4.8 panelists (×2)** → `run_claude.sh` runs `claude -p --model claude-opus-4-8` against a throwaway
  copy of the repo, exporting `CLAUDE_CODE_EFFORT_LEVEL=max` (highest-precedence effort knob) **and** passing
  `--effort max`, so each panelist hits **max** regardless of the session — this is the whole point of the
  runner (the `Agent` tool / agent-teams can't set per-call effort, so teammates just inherit config).
  `opus1.md` and `opus2.md` are two independent cold runs of the same prompt.
- **GPT-5.5 panelist (×1)** → `run_codex.sh` runs codex sandboxed (`-s workspace-write`) against its own
  throwaway copy, at `xhigh` on codex's priority (fast) service tier — sees the project for context but
  never touches your live checkout. A different model family broadens the panel.

Never use fixed paths like `/tmp/fusion_out.md`; concurrent Fusion runs would clobber each other. Each
`out` file is that seat's answer — a non-empty file is a success. A seat whose runner **exits 124 (timed
out), exits non-zero, or leaves an empty file is absent** (note it; never treat it as silent agreement) —
judge with the seats you have. Keep panelists isolated: never paste one panelist's output into another's
prompt. All three panelists are independent cold runs in separate processes, and the judge and synthesizer
are separate processes again, so every answer is read fresh downstream rather than any seat grading its own
draft.

## Step 3 — Judge (GPT-5.5 via codex, xhigh)

Once all three panelist files are written (`PDIR/opus1.md`, `PDIR/opus2.md`, `PDIR/gpt.md`), hand them to a
fresh GPT-5.5 judge. Read `references/judge_rubric.md`, then **you** (the orchestrator) write a judge prompt
file containing, in order: the original task **verbatim**, all three panel answers (each labeled by seat —
"Opus run 1", "Opus run 2", "GPT-5.5"), and the judge instructions from `references/judge_rubric.md`.
Allocate a fresh scratch dir:

```bash
mktemp -d "${TMPDIR:-/tmp}/fusion-judge.XXXXXX"   # prints the judge dir — call it JDIR
```

Take the **literal** path it printed (a shell variable would not survive into your next Bash call) and use it
everywhere below as `JDIR`. Write the judge prompt to `JDIR/judge_prompt.md` with the **Write tool**, then
run it as a **background task** (the judge reasons at xhigh and routinely runs minutes — don't block on it):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/fusion/scripts/run_codex.sh" "JDIR/judge_prompt.md" "JDIR/judge_out.md" xhigh
```

`judge_out.md` is the structured analysis: the judge classifies the deliverable (artifact → Track A,
research → Track B) and produces the analysis, attributing every point to its seat ("Opus run 1", "Opus
run 2", "GPT-5.5"). The judge does **analysis only** — it does **not** write the final deliverable; the
synthesizer does. A panelist that failed or was dropped is treated as **absent**, never as silent agreement.
The judge is bounded by `FUSION_TIMEOUT` too; if the judge runner fails or times out (**exit 124**), fall
back to producing the analysis yourself from the panel answers and say so.

## Step 4 — Synthesize (Claude Opus 4.8 via claude -p, max)

**Wait for the Step 3 judge background task to finish** (i.e. `JDIR/judge_out.md` is written) before
starting — the synth depends on the analysis. Then hand the judge analysis to a fresh Opus 4.8 synthesizer.
Write a synth prompt file containing, in order: the original task **verbatim**, the full judge analysis
(`judge_out.md`), and all panel answers (labeled by seat); end it with the synthesizer instruction from
`references/judge_rubric.md` (Track A: run/merge the candidates in the trusted copy until they pass; Track B:
derive the answer from the judge's five sections). Allocate a fresh scratch dir:

```bash
mktemp -d "${TMPDIR:-/tmp}/fusion-synth.XXXXXX"   # prints the synth dir — call it SDIR
```

Take the **literal** path it printed and use it as `SDIR`. Write the synth prompt (task + judge analysis +
panel answers + synth instruction) to `SDIR/synth_prompt.md`
with the **Write tool**, then run it as a **background task** (the synth reasons at max and routinely runs
minutes — don't block on it):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/fusion/scripts/run_claude.sh" "SDIR/synth_prompt.md" "SDIR/synth_out.md" max
```

`synth_out.md` is the final answer. For a code/artifact task the Opus synthesizer runs and fixes the merged
result inside its own throwaway repo copy (`run_claude.sh` works in a copy with `bypassPermissions`, so it
can build/run/test) before emitting it; for research it derives the answer from the judge's sections. The
synth ingests the pipeline's **largest** prompt (task + analysis + all three answers) and is bounded by
`FUSION_TIMEOUT` too, so for a big Track-A merge raise it (e.g. `FUSION_TIMEOUT=3600`) and set
`FUSION_CLAUDE_MODEL=claude-opus-4-8[1m]` to give this seat the 1M-context window. If the synthesizer runner
fails or times out (**exit 124**), the orchestrator falls back to writing the final answer itself from the
judge analysis and says so.

## Step 5 — Save provenance

Record the run to an internal provenance file under `~/.claude/fusion-runs/` (the verbatim question + all
raw panelist answers + the judge analysis + the final answer, timestamped, for auditing). Substitute the
**literal** `PDIR`/`JDIR`/`SDIR` paths from the steps above:

```bash
FUSION_PANEL_NOTE="<degradation note, or empty>" \
bash "${CLAUDE_PLUGIN_ROOT}/skills/fusion/scripts/save_run.sh" \
  opus4.8x2-gpt5.5 \
  "PDIR/question.md" "JDIR/judge_out.md" "SDIR/synth_out.md" \
  "opus-A=PDIR/opus1.md" "opus-B=PDIR/opus2.md" "gpt5.5=PDIR/gpt.md"
```

`save_run.sh` substitutes a placeholder for any answer file that is missing or empty, so a degraded panel
(an absent or timed-out seat) still produces a complete record. It prints the path it wrote — keep it for
Step 6. **Privacy:** the file holds the raw question and raw answers in cleartext; it's written `0600` under
a `0700` dir. For sensitive or confidential work, set `FUSION_NO_SAVE=1` (it skips the record entirely,
nothing hits disk) — surface that option if the task looks confidential. Set `FUSION_PANEL_NOTE` to the
one-line degradation note when a seat dropped (e.g. `"gpt5.5 dropped: codex timed out -> opus-only"`), or
leave it empty for a clean run. If the judge ran on a fallback CLI (e.g. the GPT-5.5 judge failed and you
produced the analysis on Opus instead), set `FUSION_JUDGE_LABEL` to the judge that actually ran so the
record doesn't mislabel it; it defaults to `GPT-5.5 judge` (the normal codex judge). Use a slug that
reflects what **actually** ran (`opus4.8x2-gpt5.5` for the full panel, or e.g. `opus4.8x2` if GPT-5.5 dropped).

## Step 6 — Present

Lead with the **final answer** (the synthesizer's `synth_out.md`), then the audit trail beneath it: the
per-seat attribution and the judge analysis (Track A: what each candidate did when run + what was merged
and verified; Track B: the five sections). Name the panel you ran (2× Opus 4.8 panelists at **locked max** +
1× GPT-5.5 panelist at `xhigh`, judge = GPT-5.5 (codex, `xhigh`/fast tier), synth = Opus 4.8 (`claude -p`,
`max`)) — every seat is a locked subprocess, so there's no session-effort caveat to flag. If a seat dropped
(missing CLI, non-zero exit, or `FUSION_TIMEOUT` exit 124) and you ran a degraded/fallback panel, say so and
how to enable the full panel. Unless `FUSION_NO_SAVE` was set, mention the provenance record path
`save_run.sh` printed (under `~/.claude/fusion-runs/`) so the user knows where the audit trail lives.

## Cost & latency note

A panel costs roughly N× a single answer in tokens and runs as slow as its slowest seat, plus a judge and
a synthesizer pass. Each seat is bounded by `FUSION_TIMEOUT` (default 1800s) so a stuck seat degrades the
panel instead of hanging it; raise it for deep research or big merges. **Every** reasoning seat now works
against its **own throwaway copy** of the repo (an rsync per seat) — the 2 Opus panelists, the 1 GPT-5.5
panelist, the GPT-5.5 judge, and the Opus synthesizer — so a run makes up to **five** copies, bounded by
repo size. That's the deliberate trade: you spend more to stop being confidently wrong where that is
expensive. For quick or low-stakes questions, a single direct answer is the right call.
