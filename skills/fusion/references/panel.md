# The panel

Fusion's power comes from **independent answers, synthesized** — not from a clever prompt or assigned
personas. You dispatch the same task to several models at once, each works the problem cold with no
knowledge of the others, a judge analyzes their answers, and a synthesizer writes the final one.
Independent agreement is high-confidence; independent disagreement is exactly the signal worth surfacing.

## No lenses, no personas

Do not assign panelists "roles" or "stances" (skeptic, optimizer, first-principles, etc.). That biases
*how* each one reasons artificially and corrupts the very independence that makes the panel work. Pass
every panelist the user's task **verbatim** and let each answer it straight.

The diversity is already there for free. Running the same task independently produces different reasoning
paths, different tool calls, and different source selections — even when it's the *same model answering
twice*. (Two independent Opus 4.8 cold runs diverge enough that synthesizing them, alongside a GPT-5.5
panelist, beats any single run.) You don't manufacture diversity; you harvest it from independence.

## Independence is the rule

Panelists must never see each other's work. Don't show one panelist another's answer, and don't let the
orchestrator pre-digest or summarize the task before handing it over. The answers meet only at the judge.
Cross-pollination before the judge defeats the entire mechanism.

## Panel composition (fixed for this build)

**2× Claude Opus 4.8 + 1× GPT-5.5 (codex)** — three independent answers to the same verbatim task:

- **Opus 4.8 panelists ×2 (`max`)** — two independent cold runs via `run_claude.sh`, which runs
  `claude -p --model claude-opus-4-8` against a throwaway copy of the repo (web + bash), exporting
  `CLAUDE_CODE_EFFORT_LEVEL=max` (the highest-precedence effort knob, above the `--effort` flag and
  `settings.json`) **and** passing `--effort max`, so each panelist hits max regardless of the session's
  inherited effort (only a `settings.json` `env` pin of a different value could override it). (This is why
  the panelists do **not** go through the `Agent` tool: agent-teams can't set a per-call effort, so teammates
  just inherit config.) Same prompt, two cold runs.
- **GPT-5.5 panelist ×1 (`xhigh`, locked)** — one run via `run_codex.sh`, at `xhigh` reasoning on codex's
  priority (fast) service tier, sandboxed against a throwaway copy of the repo (web + bash, no writes to
  your checkout). A different model family broadens the panel.

Every downstream seat is a locked subprocess too: the **judge** and the **synthesizer** each run as their
own wrapped runner at a fixed effort, so the Fusion session's own effort no longer affects output — the
orchestrator only coordinates.

The panelists are kept separate from the two downstream seats: **GPT-5.5 (codex, xhigh) judges** all three
(analysis only), and a separate **Claude Opus 4.8 synthesizer** (`claude -p`, max) writes the final answer.
Because the judge and synthesizer are distinct seats — and cross model families — the synthesis reads the
answers fresh rather than defending one it wrote itself.

## Prompt each panelist gets

Each panelist receives the user's task **verbatim**, plus a short instruction: *research with web search
and bash, then return a complete, self-contained answer; you are one of several independent experts and
will not see the others' work; reason at maximum depth before answering; answer it yourself — do not
delegate or spawn sub-agents.* Nothing more — no lens, no framing that nudges the conclusion.
