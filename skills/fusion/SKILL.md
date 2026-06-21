---
name: fusion
description: >-
  Answer a hard task by fanning it out to a PANEL of three models running in parallel and blind —
  2× Claude Opus 4.8 + 1× GPT-5.5 (via codex, xhigh), each answering the task verbatim with web search and
  bash, none seeing the others' work. Then Claude Opus 4.8 JUDGES all three answers
  into a structured analysis (consensus, contradictions, partial coverage, unique insights, blind spots),
  and a separate GPT-5.5 SYNTHESIZER (codex, xhigh) writes the one final answer grounded in that analysis.
  Use whenever the user asks to "run it through Fusion", wants a multi-model / panel / ensemble answer,
  wants a question cross-checked across models, or wants a higher-confidence answer with consensus and
  blind spots surfaced — even if they don't say "fusion". Best for high-stakes research, design calls, and
  debugging where being confidently wrong is expensive.
---

# Fusion

Fusion turns one prompt into a panel. The task goes to several models **at the same time**, each answering
independently — with web search and bash, and with no knowledge of the others. Then Opus 4.8 reads every
answer and extracts the structure of the panel's reasoning (what they agree on, where they conflict, what
only one saw, what they all missed), and a GPT-5.5 synthesizer writes the final answer grounded in that
analysis.

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
| Judge | Claude Opus 4.8 | orchestrator (you) | session effort † | structured analysis — does NOT write the final answer |
| Synthesizer | GPT-5.5 | `codex` (`run_codex.sh`) | `xhigh` (locked) | writes the ONE final answer from the judge analysis |

> **† Only the judge follows the session's effort.** The judge is *you* (the orchestrator) and no script
> wraps it, so it runs at whatever the Fusion session is set to — run at **`/effort max`** for a max-depth
> judge. The two Opus _panelists_, by contrast, are set to max explicitly: `run_claude.sh` exports
> `CLAUDE_CODE_EFFORT_LEVEL=max` (the **highest-precedence** effort knob — above the `--effort` flag and
> `settings.json`) **and** passes `--effort max`, so they hit max regardless of the session's inherited
> effort. (The `Agent` tool / agent-teams can't set a per-call effort, so teammates just inherit config —
> which is exactly why panelists don't go through them.) The one thing that still wins over this is a
> `settings.json` `env` block pinning a different `CLAUDE_CODE_EFFORT_LEVEL`. The GPT-5.5 seats are locked
> at `xhigh` in `run_codex.sh`.

**The judge and the synthesizer are deliberately different seats.** Opus 4.8 analyzes the panel; a separate
GPT-5.5 (codex) commits the final answer. Splitting "analyze" from "write" — and crossing model families
between them (Opus judge / GPT synth) — keeps the final answer honest rather than one seat defending its
own draft. The judge can't be skipped and the synthesizer always runs last.

## Step 0 — Verify the panel (and set effort)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/fusion/scripts/detect_panel.sh"
```

This panel needs **both CLIs installed and authenticated**: `claude` (the 2 Opus 4.8 panelists run as
`claude -p` subprocesses, locked at max) and `codex` (the 1 GPT-5.5 panelist + the GPT-5.5 synthesizer).
The detector prints `CLAUDE=ready|missing`, `CODEX=ready|missing`, and a final `PANEL=ready|degraded`. If
`claude` is missing from PATH, fall back to spawning the Opus panelists with the `Agent` tool (they will
inherit the session effort, **not** max). If `codex` is missing, tell the user the GPT-5.5 seats can't run
and offer an Opus-only fallback — but do not silently change the panel.

**Effort:** the two Opus *panelists* are set to max by `run_claude.sh`, which exports
`CLAUDE_CODE_EFFORT_LEVEL=max` (the highest-precedence effort knob) **and** passes `--effort max`, so they
no longer depend on the session (only a `settings.json` `env` pin of a different effort could override it).
The **judge is the orchestrator (you)** and still follows the **session's** effort, so run Fusion at
**`/effort max`** for a max-depth judge. If the session is not at max, say so in the final output rather
than implying the judge ran at max.

## Step 1 — Fan out: 2 Opus 4.8 (max) + 1 GPT-5.5 (xhigh), parallel and blind

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
tool**. Then launch the three runners as **background tasks** — a panel at max/xhigh routinely runs many
minutes, well past a foreground Bash timeout, so do **not** block on them. Start all three in the **same
turn** (each its own backgrounded Bash call) so they run concurrently:

```bash
# run each of these as a separate background Bash task, in one turn (substitute the real PDIR):
bash "${CLAUDE_PLUGIN_ROOT}/skills/fusion/scripts/run_claude.sh" "PDIR/prompt.md" "PDIR/opus1.md" max
bash "${CLAUDE_PLUGIN_ROOT}/skills/fusion/scripts/run_claude.sh" "PDIR/prompt.md" "PDIR/opus2.md" max
bash "${CLAUDE_PLUGIN_ROOT}/skills/fusion/scripts/run_codex.sh"  "PDIR/prompt.md" "PDIR/gpt.md"   xhigh
```

You'll be notified as each background task finishes; read that seat's output file then. While they run, keep
the user posted on which seats are still going so the run never looks frozen. Proceed to judging once all
three have finished (or are confirmed absent).

- **Opus 4.8 panelists (×2)** → `run_claude.sh` runs `claude -p --model claude-opus-4-8` against a throwaway
  copy of the repo, exporting `CLAUDE_CODE_EFFORT_LEVEL=max` (highest-precedence effort knob) **and** passing
  `--effort max`, so each panelist hits **max** regardless of the session — this is the whole point of the
  runner (the `Agent` tool / agent-teams can't set per-call effort, so teammates just inherit config).
  `opus1.md` and `opus2.md` are two independent cold runs of the same prompt.
- **GPT-5.5 panelist (×1)** → `run_codex.sh` runs codex sandboxed (`-s workspace-write`) against its own
  throwaway copy, at `xhigh` on codex's priority (fast) service tier — sees the project for context but
  never touches your live checkout. A different model family broadens the panel.

Never use fixed paths like `/tmp/fusion_out.md`; concurrent Fusion runs would clobber each other. Each
`out` file is that seat's answer — a non-empty file is a success. A seat whose runner exits non-zero or
leaves an empty file is **absent** (note it; never treat it as silent agreement) — judge with the seats you
have. Keep panelists isolated: never paste one panelist's output into another's prompt. All three are
independent cold runs in separate processes (not you), so when you judge you read all three fresh rather
than grading your own draft.

## Step 2 — Judge (Claude Opus 4.8)

Once all three panelist files are written (`PDIR/opus1.md`, `PDIR/opus2.md`, `PDIR/gpt.md`), **you** (the
orchestrator, Opus 4.8) are the judge — reason as hard as the session effort allows (run at `/effort max`
for full depth, since the judge is the one Opus seat not locked by a script). Read `references/judge_rubric.md`,
read every answer in full, classify the deliverable (artifact → Track A, research → Track B), and produce
the structured analysis. **Do not write the final deliverable here** — your job is the analysis; the
synthesizer writes the answer. Attribute every point to its seat ("Opus run 1", "Opus run 2", "GPT-5.5").
A panelist that failed or was dropped is treated as **absent**, never as silent agreement.

## Step 3 — Synthesize (GPT-5.5 via codex, xhigh)

Hand the judge analysis to a fresh GPT-5.5 synthesizer. Write a synth prompt file containing, in order:
the original task verbatim, your full judge analysis, and all panel answers (labeled by seat); end it with
the synthesizer instruction from `references/judge_rubric.md` (Track A: run/merge the candidates in the
trusted copy until they pass; Track B: derive the answer from the judge's five sections). Then:

```bash
d="$(mktemp -d "${TMPDIR:-/tmp}/fusion-synth.XXXXXX")"
# write the synth prompt (task + judge analysis + panel answers + synth instruction) to "$d/synth_prompt.md"
bash "${CLAUDE_PLUGIN_ROOT}/skills/fusion/scripts/run_codex.sh" "$d/synth_prompt.md" "$d/synth_out.md" xhigh
```

`synth_out.md` is the final answer. For a code/artifact task the synthesizer runs and fixes the merged
result inside its trusted copy (workspace-write) before emitting it; for research it derives the answer
from the judge's sections. If the synthesizer fails, fall back to writing the final answer yourself from
the judge analysis and say so.

## Step 4 — Present

Lead with the **final answer** (the synthesizer's `synth_out.md`), then the audit trail beneath it: the
per-seat attribution and your judge analysis (Track A: what each candidate did when run + what was merged
and verified; Track B: the five sections). Name the panel you ran (2× Opus 4.8 at **locked max** + 1×
GPT-5.5 at `xhigh`, Opus judge at the **session** effort, GPT-5.5 synth) — and if the session was not at
`/effort max`, flag that the judge ran below max even though the panelists were locked at max. If `claude`
or `codex` was missing and you ran a degraded/fallback panel, say so and how to enable the full panel.

## Cost & latency note

A panel costs roughly N× a single answer in tokens and runs as slow as its slowest seat, plus a judge and
a synthesizer pass. Each Opus panelist and each codex seat also works against its **own throwaway copy** of
the repo (an rsync per seat), so a run makes several copies — bounded by repo size. That's the deliberate
trade: you spend more to stop being confidently wrong where that is expensive. For quick or low-stakes
questions, a single direct answer is the right call.
