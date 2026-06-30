<div align="center">

# 🔀 fable5-fusion

### Stop being confidently wrong.

Fan one prompt out to a panel of frontier models, let them answer **independently and blind**,
then let GPT‑5.5 judge and Opus synthesize the one answer worth keeping.

[![License](https://img.shields.io/badge/License-MIT-1e6feb?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.4.2-2ea043?style=flat-square)](.claude-plugin/plugin.json)
[![Claude Code](https://img.shields.io/badge/Claude_Code-plugin-d97757?style=flat-square)](https://claude.com/claude-code)
[![Panel](https://img.shields.io/badge/panel-2×_Opus_4.8_+_GPT--5.5-8957e5?style=flat-square)](#-the-panel)
[![Codex](https://img.shields.io/badge/Codex-GPT--5.5-412991?style=flat-square&logo=openai&logoColor=white)](https://github.com/openai/codex)

</div>

---

A **Claude Code plugin** that turns one question into a **multi‑model panel**. Three models answer
the same task in parallel — none seeing the others' work — then **GPT‑5.5 judges** all of
them and a **Claude Opus 4.8 synthesizer** writes the final answer grounded in that analysis.

> Independent agreement is your highest‑confidence signal.
> Independent disagreement is exactly what a single model's self‑review hides.

---

## 🧭 The pipeline

```text
                      YOUR TASK
                          │
                          │   verbatim · no lenses · blind
        ┌─────────────────┼─────────────────┐
        ▼                 ▼                 ▼
    Opus 4.8 ①        Opus 4.8 ②        GPT‑5.5          ╮  PANEL · parallel
   (claude -p)        (claude -p)        (codex)         │  & independent
   max · locked       max · locked      xhigh · locked   ╯  web+bash · blind
        └─────────────────┼─────────────────┘
                          ▼
                  JUDGE · GPT‑5.5             ◄─ xhigh · fast
                  structured analysis            no vote · no average
                          │
                          ▼
                  SYNTH · Opus 4.8           ◄─ max
                  writes the final answer        (runs & merges code)
                          │
                          ▼
                     FINAL ANSWER
              (answer first, then audit trail)
```

Even two **cold runs of the same model** diverge enough — different reasoning paths, tool calls,
and sources — that synthesizing them beats running it once. The diversity is *harvested from
independence*, not manufactured with personas.

---

## 🎛️ The panel

| Seat | Model | Runs via | Effort | Job |
|:--|:--|:--|:--:|:--|
| 🟠 Panelist 1 | **Claude Opus 4.8** | `claude -p` (`run_claude.sh`) | `max` (locked) | independent answer |
| 🟠 Panelist 2 | **Claude Opus 4.8** | `claude -p` (`run_claude.sh`) | `max` (locked) | independent answer (2nd cold run) |
| 🟣 Panelist 3 | **GPT‑5.5** | `codex` (`run_codex.sh`) | `xhigh` (locked) | independent answer |
| ⚖️ Judge | **GPT‑5.5** | `codex` (`run_codex.sh`) | `xhigh` (locked) | structured analysis — *not* the final answer |
| ✍️ Synthesizer | **Claude Opus 4.8** | `claude -p` (`run_claude.sh`) | `max` (locked) | writes the **one** final answer |

> **All reasoning seats are locked subprocesses; the orchestrator only coordinates.** Every seat runs as a
> wrapped runner at a fixed effort, so the Fusion session's own effort no longer affects output. The two Opus
> *panelists* and the Opus *synthesizer* are set to max explicitly — `run_claude.sh` exports
> `CLAUDE_CODE_EFFORT_LEVEL=max` (the highest‑precedence effort knob, above the `--effort` flag and
> `settings.json`) and also passes `--effort max`, so they hit max regardless of the session's inherited
> effort (only a `settings.json` `env` pin of a different value could override it). The GPT‑5.5 *panelist*
> and the GPT‑5.5 *judge* are locked at `xhigh` in `run_codex.sh`.

> **Why split judge and synthesizer?** GPT‑5.5 *analyzes* the panel; a separate
> Claude Opus 4.8 *writes* the answer. Splitting "analyze" from "write" — and crossing model families
> between them — keeps the final answer honest instead of one seat defending its own draft.

---

## 🚀 Quickstart

```bash
# 1. add the marketplace + install
claude plugin marketplace add https://github.com/Rylaa/fable5-fusion
claude plugin install fable5-fusion

# 2. run it
/fable5-fusion:fusion <your question or task>
```

That's it. The skill auto‑detects the panel, fans out, judges, synthesizes, and hands you the
final answer followed by a per‑seat audit trail.

---

## 🧠 How it works

| Step | What happens |
|:--:|:--|
| **0** | `detect_panel.sh` confirms `claude` + `codex` are ready (panelists need `claude`; the GPT‑5.5 seats need `codex`). |
| **1** | **Preflight** — `preflight.sh` prints a non‑blocking token / latency / timeout estimate for the 5‑seat panel. |
| **2** | Fan out — 2× Opus 4.8 (`claude -p`, locked max) + 1× GPT‑5.5 (`codex`, xhigh), in parallel and blind, task verbatim. |
| **3** | **Judge** — GPT‑5.5 (`codex`, `xhigh`) reads all three and produces a structured analysis. |
| **4** | **Synthesize** — Opus 4.8 (`claude -p`, `max`) writes the final answer from that analysis. |
| **5** | **Provenance** — `save_run.sh` records question + raw answers + analysis + final to `~/.claude/fusion-runs/` (`0600`; skip with `FUSION_NO_SAVE`). |
| **6** | **Present** — final answer first, then the audit trail (attribution + analysis). |

Two tracks, chosen automatically:

- 🛠️ **Track A — code / artifact:** the synthesizer *runs the candidates*, keeps what works, and
  re‑runs the merge until it passes. Independent attempts expose each other's bugs, so the
  result ends up **more correct than either input**.
- 📚 **Track B — research / analysis:** the judge surfaces **Consensus · Contradictions · Partial
  coverage · Unique insights · Blind spots**, and the synthesizer grounds the answer in them.

---

## 🔒 Isolation — safe by default

**Every** runner seat — the panelists, the judge, and the synthesizer — works against its own throwaway
**copy** of your repo, so candidate writes never touch your live checkout:

```text
your repo  ──(rsync copy)──►  /tmp/fusion-*.XXXX/workdir   ◄── each seat works HERE
   ▲                                                            (sees context, writes in the copy)
   └── never touched · live checkout stays clean
```

- **GPT‑5.5 seats (`codex`)** are additionally **OS‑sandboxed** (`-s workspace-write`): codex may read and
  write only inside its copy. This deliberately avoids `--dangerously-bypass-approvals-and-sandbox`, which
  codex's own help flags as *"EXTREMELY DANGEROUS … solely for environments that are externally sandboxed"*.
- **Opus seats (`claude -p`)** run with the copy as their working directory, so candidate files land in the
  copy. This is CWD isolation — the same trust level as the `Agent`‑tool teammates it replaces, not a hard
  filesystem sandbox.

✅ Sees your project for context &nbsp; ✅ web + bash &nbsp; ✅ live checkout stays clean

---

## 🛡️ Resilience & provenance

A five‑subprocess panel needs guardrails so one stuck seat can't hang the run and so you can audit
what each seat actually said. This build adds:

- **⏱️ Per‑seat timeout.** Stock macOS has no `timeout`/`gtimeout`, so `_fusion_lib.sh` ships a
  self‑contained perl fork+alarm wrapper. **Every** runner (`run_codex.sh` *and* `run_claude.sh`) wraps its
  CLI call in it: `FUSION_TIMEOUT` (default **1800s**) bounds each seat, and a seat that runs over exits
  **124** — the orchestrator treats it as **absent** and degrades the panel instead of waiting forever. The
  wrapper kills the seat's **whole process group** (SIGTERM → 2s grace → SIGKILL) so codex/claude children
  don't linger, returns 124 only for a *real* timeout (a seat that dies of its own signal is reported as
  `128+signo`), and validates `FUSION_TIMEOUT` as a positive integer so a stray `0`/garbage value can't
  silently disable the deadline. Raise it for deep research or a big code merge: `FUSION_TIMEOUT=3600`.
- **🧾 Provenance record.** After synthesis, `save_run.sh` writes a timestamped
  `~/.claude/fusion-runs/<ts>_opus4.8x2-gpt5.5.md`: the **verbatim question**, every **raw panelist answer**
  (`opus-A` / `opus-B` / `gpt5.5`), the **judge analysis**, and the **final answer** — with a placeholder for
  any absent seat, so a degraded run still produces a complete audit trail. Written **`0600`** under a
  `0700` dir. It records raw prompts and answers in cleartext, so for sensitive work set **`FUSION_NO_SAVE=1`**
  to skip it entirely (nothing hits disk).
- **📋 Preflight.** `preflight.sh` prints a non‑blocking (always `exit 0`) token / latency / timeout estimate
  for the fixed 5‑seat panel before fan‑out, so a heavy question doesn't surprise you.
- **🔑 `gh` auth precheck.** `run_codex.sh` warns (never blocks) if `gh` is installed but unauthenticated in
  the parent environment. The codex seat stays **sandboxed** (`-s workspace-write`) regardless — this build
  never adds `--dangerously-bypass-approvals-and-sandbox`.

---

## ⚙️ Requirements

| | |
|:--|:--|
| **`claude` CLI** | **Required, on your `PATH`.** Runs the 2 Opus 4.8 panelists **and** the Opus 4.8 synthesizer as `claude -p --model claude-opus-4-8 --effort max` subprocesses — so they hit max regardless of the session. |
| **`codex` CLI** | **Required.** Runs the GPT‑5.5 panelist **and** the GPT‑5.5 judge. Logged in with GPT‑5.5 access. Tested against `codex-cli` 0.139. |

If `claude` isn't on PATH, the Opus panelists **and the synthesizer** lose locked max — the skill falls back
to `Agent`‑tool panelists (session effort, not max) and the orchestrator writes the final answer itself. If
`codex` is missing, the GPT‑5.5 panelist **and the judge** can't run — the judge falls back to the
orchestrator — so it offers an Opus‑only run rather than silently changing the panel.

---

## 💸 Cost & latency

A panel costs roughly **N× a single answer** in tokens and runs as slow as its slowest seat, plus a
judge and a synthesizer pass. That's the deliberate trade: you spend more to stop being confidently
wrong **where that's expensive** — high‑stakes research, design calls, gnarly debugging. For quick
or low‑stakes questions, a single direct answer is the right call.

Each seat also rsyncs its **own** throwaway copy of the repo (two Opus panelists + one GPT‑5.5 panelist +
the GPT‑5.5 judge + the Opus synthesizer — up to five), so a run makes several copies — bounded by repo
size. Run Fusion from your project dir, not a huge unrelated parent.

The GPT‑5.5 seats run on codex's **priority service tier** (`service_tier=priority`) — full `xhigh`
reasoning quality, served faster. Override with `FUSION_SERVICE_TIER`, or set it empty to fall back to your
`~/.codex/config.toml` default. Note: in codex 0.139 only `priority` is the confirmed fast tier —
unrecognized values are silently coerced to codex's default tier (the runner warns when you set a non‑`priority`
value). The Opus seats default to `claude-opus-4-8` (Opus 4.8, standard window — ample for panelist
prompts); override with `FUSION_CLAUDE_MODEL` (e.g. `claude-opus-4-8[1m]` for the 1M‑context variant). Every
seat is time‑bounded by `FUSION_TIMEOUT` (default 1800s) — raise it for deep research or a big Track‑A merge
so a slow‑but‑valid seat isn't killed at the deadline, and skip the provenance record for sensitive runs with
`FUSION_NO_SAVE=1`.

---

## 🙏 Credit

Architecture adapted from **[duolahypercho/fusion-fable](https://github.com/duolahypercho/fusion-fable)** (MIT) —
re‑shaped into a `2× Opus 4.8 + 1× GPT‑5.5` panel with a split **GPT‑5.5‑judge / Opus‑synth**
pipeline, hardened runner isolation, and packaged as a Claude Code plugin.

## 📄 License

[MIT](LICENSE) © Rylaa

<div align="center">
<sub>Built for <a href="https://claude.com/claude-code">Claude Code</a> · powered by Claude Opus 4.8 + GPT‑5.5</sub>
</div>
