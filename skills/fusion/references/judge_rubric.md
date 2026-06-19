# Judge & synthesizer rubric

Two seats, two jobs:

- **Judge — Claude Opus 4.8 (the orchestrator) — at the session reasoning effort (run /effort max for full depth).** Reads every panelist response
  *after* all returned independently and produces a structured **analysis**. It does **not** write the
  final answer.
- **Synthesizer — GPT-5.5 (codex), xhigh.** Takes the judge analysis + the panel answers and writes the
  **one final deliverable**.

Neither votes or averages. **First classify the deliverable**, then both seats follow the matching track:

- **Artifact task** — a concrete buildable thing (code, script, config, schema, command). The panelists
  each produced a candidate implementation. → **Track A**.
- **Research / analysis task** — understanding, a recommendation, a written answer. → **Track B**.

When a task is mixed ("design and implement X"), the implementation is the deliverable: Track A for the
code, fold the reasoning in as brief rationale.

---

## Judge (Opus 4.8) — produce the analysis

Read every panelist response in full and attribute by seat ("Opus run 1", "Opus run 2", "GPT-5.5") so
the user can trace every decision. A panelist that failed or was dropped is **absent**, never silent
agreement.

### Track A — analyze the candidates (you don't run them; the synthesizer does)
For each candidate, build a real model of it: its approach, what it gets right, where it looks buggy,
incomplete, or fragile. Note the concrete differences — APIs, data structures, algorithms, file layout,
edge-case handling. Where candidates disagree on an API call, constant, algorithm, or control flow, say
which version is more likely correct and **why**. Recommend a foundation to build on and the specific
pieces worth grafting from the others. This recommendation is a hypothesis the synthesizer will confirm by
actually running the code.

### Track B — the five sections
- **Consensus** — points panelists independently agree on; independent agreement (across families, or two
  cold Opus 4.8 runs) is the highest-confidence signal. Flag any shared mistake.
- **Contradictions** — direct conflicts on fact or recommendation; state the positions, who holds them,
  and adjudicate where you can (who ran code / read a primary source). Never bury a real conflict.
- **Partial coverage** — important sub-questions only some panelists engaged.
- **Unique insights** — valuable points raised by exactly one seat. Format: `[seat]: <insight>`.
- **Blind spots** — what the panel as a whole missed, including shared assumptions; add any you see.

Hand this analysis to the synthesizer. Do not write the final answer yourself.

---

## Synthesizer (GPT-5.5 via codex, xhigh) — write the final answer

The synth prompt contains the original task, the judge analysis, and all panel answers. Produce **one**
final deliverable that merges the genuinely best parts — not an average, not one answer lightly edited.

### Track A — run the candidates, then merge (code / artifacts)
1. Understand each candidate from the answers + the judge's analysis.
2. **Run each candidate** in your trusted workspace copy (build, run, test, lint, feed representative
   inputs). Observed behavior is ground truth and outranks any reasoning about which "looks" better. (If it
   genuinely can't be executed here, fall back to careful seam-reasoning and mark the result unverified.)
3. **Resolve disagreements by what actually ran** — prefer the version that demonstrably worked. Never
   average or keep multiple variants "to be safe."
4. **Pick a foundation, then graft the parts that worked** — one coherent design, consistent style, never
   a Frankenstein of whole programs stitched together.
5. **Run the merged artifact and fix until it passes.** The seams (signatures, imports, types, indices)
   are where a merge silently breaks. Emit the whole thing — every file, ready to run as-is.
6. **Brief merge rationale** after the artifact: what each candidate did when run, what you took from each,
   what you verified.

The point of the panel for code: independent attempts expose each other's bugs, so the merge ends up
**more correct than any single input**.

### Track B — structured final answer (research / analysis)
Derive the answer from the judge's five sections: lead with high-confidence consensus, fold in the unique
insights that add value, flag what stays uncertain. It must follow *from* the analysis, not be one
panelist's answer lightly edited.

---

## Principles (all seats)

- Evidence over assertion: a seat that ran the code or read a primary source outranks one reasoning from
  memory, regardless of model.
- Be honest about confidence and disagreement — a result that hides a real conflict is worse than no panel.
- Keep attribution so any decision traces back to its seat.
- For artifacts, "verified to run" beats "looks plausible"; fall back to seam-reasoning only when execution
  is genuinely impossible, and say so.
