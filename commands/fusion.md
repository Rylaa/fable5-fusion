---
description: Run Fusion — panel of 2× Opus 4.8 + 1× GPT-5.5, GPT-5.5 judges, Opus 4.8 synthesizes
argument-hint: <your question or task>
---
Invoke the **fusion** skill on the task below. This is a direct execution request, not a suggestion:
do NOT judge whether fusion "fits" the task, do NOT ask for clarification, and do NOT refuse —
`$ARGUMENTS` is the task, run it (code or research, whatever it is).

Follow the skill's SKILL.md exactly:
1. **Step 0** — run `detect_panel.sh` to confirm both `claude` and `codex` are available (the panel needs
   `claude` for the Opus seats and `codex` for the GPT-5.5 seats). If either is missing, say so before proceeding.
2. **Step 1** — fan out the panel in parallel and blind: 2× Claude Opus 4.8 (`run_claude.sh`, locked
   `--effort max`) and 1× GPT-5.5 (`run_codex.sh`, `xhigh`). Task verbatim, no lenses.
3. **Step 2** — judge all three answers with a fresh GPT-5.5 seat (`run_codex.sh`, `xhigh`) per
   `judge_rubric.md`: write a judge prompt (verbatim task + all panel answers + judge instructions) and run
   it. Analysis only, do not write the final answer.
4. **Step 3** — synthesize the final answer with a separate Claude Opus 4.8 seat (`run_claude.sh`, locked
   `max`) from the judge analysis + panel answers.
5. **Step 4** — present the final answer first, then the audit trail (per-seat attribution + judge analysis).

Task: $ARGUMENTS
