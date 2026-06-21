<div align="center">

# 🔀 fable5-fusion

### Stop being confidently wrong.

Fan one prompt out to a panel of frontier models, let them answer **independently and blind**,
then let Opus judge and GPT‑5.5 synthesize the one answer worth keeping.

[![License](https://img.shields.io/badge/License-MIT-1e6feb?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.1.0-2ea043?style=flat-square)](.claude-plugin/plugin.json)
[![Claude Code](https://img.shields.io/badge/Claude_Code-plugin-d97757?style=flat-square)](https://claude.com/claude-code)
[![Panel](https://img.shields.io/badge/panel-2×_Opus_4.8_+_GPT--5.5-8957e5?style=flat-square)](#-the-panel)
[![Codex](https://img.shields.io/badge/Codex-GPT--5.5-412991?style=flat-square&logo=openai&logoColor=white)](https://github.com/openai/codex)

</div>

---

A **Claude Code plugin** that turns one question into a **multi‑model panel**. Three models answer
the same task in parallel — none seeing the others' work — then **Claude Opus 4.8 judges** all of
them and a **GPT‑5.5 synthesizer** writes the final answer grounded in that analysis.

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
                  JUDGE · Opus 4.8            ◄─ session effort †
                  structured analysis            no vote · no average
                          │
                          ▼
                  SYNTH · GPT‑5.5             ◄─ xhigh
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
| ⚖️ Judge | **Claude Opus 4.8** | orchestrator | session † | structured analysis — *not* the final answer |
| ✍️ Synthesizer | **GPT‑5.5** | `codex` (`run_codex.sh`) | `xhigh` (locked) | writes the **one** final answer |

> **† Only the judge follows the session's effort.** The two Opus *panelists* are set to max explicitly —
> `run_claude.sh` exports `CLAUDE_CODE_EFFORT_LEVEL=max` (the highest‑precedence effort knob, above the
> `--effort` flag and `settings.json`) and also passes `--effort max`, so they hit max regardless of the
> session's inherited effort (only a `settings.json` `env` pin of a different value could override it). The
> judge is the orchestrator itself, so it runs at the **session's** effort — run Fusion at `/effort max` for
> a max‑depth judge. The GPT‑5.5 seats are locked at `xhigh`.

> **Why split judge and synthesizer?** Opus *analyzes* the panel; a separate
> GPT‑5.5 *writes* the answer. Splitting "analyze" from "write" — and crossing model families
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
| **1** | Fan out — 2× Opus 4.8 (`claude -p`, locked max) + 1× GPT‑5.5 (`codex`, xhigh), in parallel and blind, task verbatim. |
| **2** | **Judge** — Opus 4.8 reads all three and produces a structured analysis. |
| **3** | **Synthesize** — GPT‑5.5 (`xhigh`) writes the final answer from that analysis. |
| **4** | **Present** — final answer first, then the audit trail (attribution + analysis). |

Two tracks, chosen automatically:

- 🛠️ **Track A — code / artifact:** the synthesizer *runs the candidates*, keeps what works, and
  re‑runs the merge until it passes. Independent attempts expose each other's bugs, so the
  result ends up **more correct than either input**.
- 📚 **Track B — research / analysis:** the judge surfaces **Consensus · Contradictions · Partial
  coverage · Unique insights · Blind spots**, and the synthesizer grounds the answer in them.

---

## 🔒 Isolation — safe by default

**Every** runner seat — the panelists and the synthesizer — works against its own throwaway **copy** of
your repo, so candidate writes never touch your live checkout (the judge is the orchestrator and gets none):

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

## ⚙️ Requirements

| | |
|:--|:--|
| **`claude` CLI** | **Required, on your `PATH`.** The 2 Opus 4.8 panelists run as `claude -p --model claude-opus-4-8 --effort max` subprocesses — so they hit max regardless of the session. The judge is the orchestrator itself. |
| **`codex` CLI** | **Required.** Runs the GPT‑5.5 panelist + the synthesizer. Logged in with GPT‑5.5 access. Tested against `codex-cli` 0.139. |

If `claude` isn't on PATH, the skill falls back to spawning the Opus panelists with the `Agent` tool (they
inherit the session effort, not max). If `codex` is missing, it offers an Opus‑only fallback rather than
silently changing the panel.

---

## 💸 Cost & latency

A panel costs roughly **N× a single answer** in tokens and runs as slow as its slowest seat, plus a
judge and a synthesizer pass. That's the deliberate trade: you spend more to stop being confidently
wrong **where that's expensive** — high‑stakes research, design calls, gnarly debugging. For quick
or low‑stakes questions, a single direct answer is the right call.

Each seat also rsyncs its **own** throwaway copy of the repo (two Opus + one GPT panelist + one synth), so
a run makes several copies — bounded by repo size. Run Fusion from your project dir, not a huge unrelated
parent.

The GPT‑5.5 seats run on codex's **priority service tier** (`service_tier=priority`) — full `xhigh`
reasoning quality, served faster. Override with `FUSION_SERVICE_TIER`, or set it empty to fall back to your
`~/.codex/config.toml` default. Note: in codex 0.139 only `priority` is the confirmed fast tier —
unrecognized values are silently coerced to codex's default tier (the runner warns when you set a non‑`priority`
value). The Opus seats default to `claude-opus-4-8` (Opus 4.8, standard window — ample for panelist
prompts); override with `FUSION_CLAUDE_MODEL` (e.g. `claude-opus-4-8[1m]` for the 1M‑context variant).

---

## 🙏 Credit

Architecture adapted from **[duolahypercho/fusion-fable](https://github.com/duolahypercho/fusion-fable)** (MIT) —
re‑shaped into a `2× Opus 4.8 + 1× GPT‑5.5` panel with a split **Opus‑judge / GPT‑5.5‑synth**
pipeline, hardened runner isolation, and packaged as a Claude Code plugin.

## 📄 License

[MIT](LICENSE) © Rylaa

<div align="center">
<sub>Built for <a href="https://claude.com/claude-code">Claude Code</a> · powered by Claude Opus 4.8 + GPT‑5.5</sub>
</div>
