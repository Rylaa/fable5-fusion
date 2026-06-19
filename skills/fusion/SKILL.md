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
| Panelist 1 | Claude Opus 4.8 | `Agent` subagent | max † | independent answer |
| Panelist 2 | Claude Opus 4.8 | `Agent` subagent | max † | independent answer (2nd cold run) |
| Panelist 3 | GPT-5.5 | `codex` | `xhigh` (locked) | independent answer |
| Judge | Claude Opus 4.8 | orchestrator (you) | session effort † | structured analysis — does NOT write the final answer |
| Synthesizer | GPT-5.5 | `codex` | `xhigh` (locked) | writes the ONE final answer from the judge analysis |

> **† Opus effort is NOT parameter-locked.** The `Agent` tool has no per-call effort flag, and the judge is
> *you* (the orchestrator). The Opus seats run at whatever **reasoning effort the Fusion session is set to**
> — so to actually get max, **run the session at `/effort max`**. The panelist prompts also explicitly ask
> for maximum-depth reasoning, but that is a nudge, not a guarantee. Only the GPT-5.5 seats are truly
> locked (`xhigh`, set via `-c model_reasoning_effort=xhigh` in `run_codex.sh`).

**The judge and the synthesizer are deliberately different seats.** Opus 4.8 analyzes the panel; a separate
GPT-5.5 (codex) commits the final answer. Splitting "analyze" from "write" — and crossing model families
between them (Opus judge / GPT synth) — keeps the final answer honest rather than one seat defending its
own draft. The judge can't be skipped and the synthesizer always runs last.

## Step 0 — Verify the panel (and set effort)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/fusion/scripts/detect_panel.sh"
```

This panel needs the **`codex` CLI installed and authenticated** (it runs the 1 GPT-5.5 panelist + the
GPT-5.5 synthesizer). The detector prints `CODEX=ready` or `CODEX=missing`. If codex is missing, tell the
user the specified panel can't run (it requires codex for the GPT-5.5 seats) and offer the fallback of
running the panel as independent Opus 4.8 subagents only — but do not silently change the panel.

**Effort:** the Opus seats (panelists + judge) inherit the **session's** reasoning effort — the `Agent`
tool exposes no per-call effort flag. For top quality, the user should run Fusion at **`/effort max`**. If
the session is not at max, say so in the final output rather than implying the Opus seats ran at max.

## Step 1 — Fan out: 2 Opus 4.8 + 1 GPT-5.5 (xhigh), parallel and blind

Read `references/panel.md`. Build each seat's prompt as the user's task **verbatim** plus the short
instruction to research with web + bash and return a complete, self-contained answer as one of several
independent experts who won't see the others' work. Do not assign lenses; do not pre-digest the task.

Launch **all three panelists in a single turn** so they run concurrently:

- **Opus 4.8 panelists (×2)** → the `Agent` tool, `subagent_type: general-purpose` (web + bash built in).
  Spawn **two** independent Opus subagents with the *same* prompt — two cold runs. Prefix each panelist
  prompt with an explicit instruction to **reason at maximum depth** before answering (a nudge; the actual
  effort is the session's — see Step 0). Spawn them in the same message so they run at once; each returned
  answer is one panel response.
- **GPT-5.5 panelist (×1)** → run `run_codex.sh` once, in the background, at `xhigh`:
  ```bash
  d="$(mktemp -d "${TMPDIR:-/tmp}/fusion-panel.XXXXXX")"
  # write the verbatim panelist prompt to "$d/codex_prompt.md", then:
  bash "${CLAUDE_PLUGIN_ROOT}/skills/fusion/scripts/run_codex.sh" "$d/codex_prompt.md" "$d/codex_out.md" xhigh &
  ```
  Allocate a unique directory for the seat — never fixed paths like `/tmp/fusion_codex_out.md`; concurrent
  Fusion runs would otherwise read each other's prompts or answers. The runner copies the current
  repo/workdir into a throwaway dir and runs codex sandboxed (`-s workspace-write`) against that copy, so
  the GPT-5.5 panelist sees the project for context but never touches your live checkout. It runs at
  `xhigh` reasoning (parameter-locked) on codex's priority (fast) service tier. Read `codex_out.md` once it
  finishes; a non-empty file is that panelist's answer.

Keep panelists isolated: never paste one panelist's output into another's prompt. The two Opus runs are
independent cold runs (spawned subagents, not you); the GPT-5.5 run is a separate family — so when you
judge, you read all three fresh rather than grading your own draft.

## Step 2 — Judge (Claude Opus 4.8)

Once all three panelists have returned, **you** (the orchestrator, Opus 4.8) are the judge — reason as
hard as the session effort allows (run at `/effort max` for full depth). Read `references/judge_rubric.md`,
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
and verified; Track B: the five sections). Name the panel you ran (2× Opus 4.8 + 1× GPT-5.5, Opus judge,
GPT-5.5 synth) and the session effort the Opus seats ran at. If codex was missing and you ran an Opus-only
fallback, say so and how to enable the full panel (install + log in to the `codex` CLI).

## Cost & latency note

A panel costs roughly N× a single answer in tokens and runs as slow as its slowest seat, plus a judge and
a synthesizer pass. That's the deliberate trade: you spend more to stop being confidently wrong where that
is expensive. For quick or low-stakes questions, a single direct answer is the right call.
