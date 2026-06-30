# Fusion for Codex CLI

Run the exact same Fusion panel you use in Claude Code — `/fusion <task>` — from **Codex CLI** too.
Everything here is **additive**: it adds a `codex/` directory and (after you run the installer) two
files under `~/.codex/`. It changes **nothing** in the Claude Code plugin (`skills/`, `commands/`,
`references/`), and it reuses the plugin's five seat-runner scripts **verbatim**.

Same panel either way: 2× Claude Opus 4.8 panelists (`max`) + 1× GPT-5.5 panelist (`xhigh`), a GPT-5.5
judge (`xhigh`), and an Opus 4.8 synthesizer (`max`).

## What's in here

- `fusion-runner.sh` — the Codex-side orchestrator. A single deterministic bash program that runs
  SKILL.md Steps 0–6 (detect → preflight → fan-out → judge → synth → save → present), reusing the
  plugin's `detect_panel/preflight/run_claude/run_codex/save_run.sh`. The runner is the "orchestrator";
  the reasoning all lives in the locked seats it launches.
- `prompts/fusion.md` — the thin Codex custom prompt. `/fusion <task>` just feeds the task to the
  runner on stdin and presents its output. It does no orchestration itself.
- `install.sh` — copies those two files into `~/.codex/` (safely — see below).
- `tests/fusion-runner.test.sh` — stubbed test of the runner's orchestration (no real model calls).

## Why a runner instead of driving it from the prompt

The Claude Code path uses a **model** orchestrator (Claude) with a Write tool and a
background-task+notification layer. Codex has neither — a Codex agent only runs shell commands. Asking
a GPT-5.5 orchestrator to hand-run all six steps each turn (multiple heredocs, carrying random `mktemp`
paths across stateless shell calls) is fragile. Encoding Steps 0–6 as one bash program makes the Codex
side deterministic and keeps the slash command trivial. The intelligence was never in the orchestrator
— it's in the seats — so nothing is lost.

## Install

```bash
bash codex/install.sh           # writes ~/.codex/fusion/fusion-runner.sh and ~/.codex/prompts/fusion.md
```

The installer **never silently overwrites**. If `~/.codex/prompts/fusion.md` (or the runner) already
exists and differs — e.g. a prior Fusion-for-Codex install or your own edit — it refuses and tells you
to re-run with `--force`, which backs up the old file (`.bak.<timestamp>`) before replacing it. An
identical file is left untouched. It does **not** edit `~/.codex/config.toml`, your shell rc, or any
plugin file.

Then **restart Codex once** so it loads the new prompt.

## Use it

Launch Codex with the sandbox **off**, then call `/fusion`:

```bash
codex --sandbox danger-full-access --ask-for-approval never
# inside codex:
/fusion compare Postgres vs SQLite for a single-node analytics service
```

Optional one-word launcher in `~/.zshrc`:

```bash
alias fusion-codex='codex --sandbox danger-full-access --ask-for-approval never'
```

If your Codex build namespaces custom prompts, the command may appear as `/prompts:fusion` — type `/`
then `fusion` and the menu finds it.

### Headless one-shot (no TUI, no slash command)

The runner is plain bash, so you can run it directly from a normal shell. A plain shell is already
un-sandboxed, so no codex flags are needed:

```bash
bash codex/fusion-runner.sh "your question or task"
bash codex/fusion-runner.sh < task.txt          # task from stdin (best for very large tasks)
FUSION_TIMEOUT=900 bash codex/fusion-runner.sh "heavy deep-research question"
```

Run it from the project directory you want the panel to see — the seat runners rsync `$(pwd)` into each
seat's throwaway copy for context.

## Why the orchestrator must be un-sandboxed (tested, not assumed)

The panel spawns `claude -p` and `codex exec` children that need network (model APIs + web search), and
`run_codex.sh` applies its **own** `-s workspace-write` sandbox to each GPT-5.5 seat. On macOS, Seatbelt
**cannot be nested**. Verified on this machine (codex 0.142.4):

- `workspace-write` blocks outbound network by default; `-c sandbox_workspace_write.network_access=true`
  opens it. So network alone is *not* the blocker.
- But a nested sandbox under a `workspace-write` parent dies:
  `sandbox-exec: sandbox_apply: Operation not permitted` (exit 71). That is exactly what `run_codex.sh`
  would hit for the GPT-5.5 panelist and the GPT-5.5 judge if the orchestrator were sandboxed.
- Under an un-sandboxed parent (`danger-full-access`), the nested seat runs fine and reaches the
  network — confirmed with a real `run_codex.sh` GPT-5.5 seat completing end-to-end.

So the **orchestrator** runs un-sandboxed; that is the narrowest mode that actually works here, given
that the seats keep their own sandbox. The narrower `workspace-write + network_access=true` orchestrator
mode was tried and provably fails for the nested seats, so it is **not** the default. (`codex exec` is
non-interactive and has **no** `--ask-for-approval` flag — `codex exec --ask-for-approval never` errors
with `unexpected argument`; the exec equivalent is `--dangerously-bypass-approvals-and-sandbox`.)

The panel's seats are **not** affected by this: `run_codex.sh` still runs each GPT-5.5 seat in its own
`-s workspace-write` sandbox against a throwaway repo copy, and `run_claude.sh` still works in a
throwaway copy with `bypassPermissions`. Only the orchestrator is un-sandboxed.

## How the Codex path maps to the Claude Code path

| Claude Code (model orchestrator) | Codex (deterministic runner) |
|----------------------------------|------------------------------|
| Skill drives Steps 0–6; Claude reasons between them | `fusion-runner.sh` runs Steps 0–6 as one program |
| `Write` tool authors prompt files | `printf`/`cat` heredocs inside the runner |
| Each seat launched as a background task + harness notification | seats backgrounded with `&`, polled, then `wait` |
| `${CLAUDE_PLUGIN_ROOT}/skills/fusion/scripts` | resolved at run time (env → marketplace → repo) |
| Orchestrator writes the final answer if a seat fails | runner falls back across CLIs (judge: codex→claude; synth: claude→codex) |

## Knobs (environment variables)

- `FUSION_TIMEOUT` — per-seat budget in seconds. **Default 1800** on the Codex side (a panel at
  max/xhigh routinely runs minutes). Exported to every seat.
- `FUSION_SYNTH_MODEL` — model id for the **synth seat only**, e.g. `claude-opus-4-8[1m]` to give the
  synthesizer the 1M-context window on a big Track-A merge (the panelists keep the standard window).
- `FUSION_NO_SAVE=1` — skip the provenance record entirely (nothing hits disk). Use for confidential
  tasks.
- `FUSION_SCRIPTS` — override the plugin scripts directory if auto-resolution can't find it.
- `FUSION_PROGRESS_INTERVAL` — seconds between "still running" progress lines (default 20).

## Caveats / limits

- **One long-running command.** Codex shows the whole panel as a single command. The runner streams
  `[fusion] …` progress to stderr at every step, so it is visibly working, not frozen. Each seat is
  bounded by `FUSION_TIMEOUT`, so a stuck seat is killed and treated as absent rather than hanging the
  panel.
- **Restart Codex after install** so the new prompt loads.
- **Degraded panels.** If `claude` is missing, the panel runs GPT-5.5-only and GPT-5.5 also writes the
  final answer (slug `gpt5.5-only`); install + log in to `claude` for the full panel. If a single seat
  times out or errors, it is marked **absent** (never silent agreement) and the panel proceeds.
- **Provenance** is written to `~/.claude/fusion-runs/` (`0600`), the same place the Claude Code path
  uses. It contains the verbatim task and every raw answer in cleartext — use `FUSION_NO_SAVE=1` for
  sensitive work.
