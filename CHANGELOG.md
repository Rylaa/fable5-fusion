# Changelog

All notable changes to fable5-fusion are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [1.1.0] - 2026-06-21

Lock the Opus panelists at **max** reasoning effort — independent of the session.

### Changed
- **Opus panelists now run via `claude -p`, not the `Agent` tool.** A new `run_claude.sh` launches each of
  the two Opus 4.8 panelists as `claude -p --model claude-opus-4-8` against a throwaway copy of the repo,
  exporting `CLAUDE_CODE_EFFORT_LEVEL=max` (the **highest-precedence** effort knob — above the `--effort`
  flag and `settings.json`) **and** also passing `--effort max`. So the panelists hit **max** regardless of
  the session's inherited effort; the only thing that can override it is a `settings.json` `env` block
  pinning a different `CLAUDE_CODE_EFFORT_LEVEL`.

### Fixed
- **Panelists silently ran below max.** Under agent-teams (`teammateMode: tmux`), `Agent`-tool panelists
  spawn as fresh `claude` sessions whose effort comes from config (`CLAUDE_CODE_EFFORT_LEVEL`, else
  `settings.json` `effortLevel`), not from the orchestrator: its transient `/effort max` is "this session
  only" and does **not** propagate to tmux teammates, and the `Agent` tool exposes no per-call effort flag.
  Routing panelists through `run_claude.sh` — which sets the effort explicitly per call — makes max a
  parameter, not a hope. (The **judge** is still the orchestrator and follows the session's effort — run
  Fusion at `/effort max` for a max-depth judge.)

### Added
- `run_claude.sh` (mirrors `run_codex.sh`): runs one Opus seat at a locked effort against a throwaway repo
  copy; sets both the `CLAUDE_CODE_EFFORT_LEVEL` env var and `--effort`; blocks recursive sub-agent/teammate
  spawning with `--disallowedTools "Task Agent"`; override the model with `FUSION_CLAUDE_MODEL`.
- `detect_panel.sh` now checks **both** `claude` and `codex` (prints `CLAUDE=`, `CODEX=`, `PANEL=`).
- `run_codex.sh` warns when `FUSION_SERVICE_TIER` is set to a non-`priority` value (codex silently coerces
  unrecognized tiers to its default, dropping fast mode).

## [1.0.0] - 2026-06-19

Initial release — a Claude Code plugin for multi-model fusion.

### Added
- **Skill-driven panel:** one prompt fans out to **2× Claude Opus 4.8 + 1× GPT-5.5** (via codex),
  in parallel and blind — each answers the task verbatim with web search and bash, none seeing the
  others' work.
- **Judge:** Claude Opus 4.8 (the orchestrator) reads all three answers and produces a structured
  analysis (consensus, contradictions, partial coverage, unique insights, blind spots) — no vote, no
  average. It does not write the final answer.
- **Synthesizer:** a separate GPT-5.5 (codex, `xhigh`) writes the one final answer from the judge
  analysis. Track A (code — run the candidates and merge what works) / Track B (research — derive from
  the analysis).
- **`run_codex.sh`:** runs the GPT-5.5 seats sandboxed (`-s workspace-write`) against a throwaway copy
  of the repo — they see project context without touching your live checkout — on codex's **priority
  (fast) service tier**. Override with `FUSION_SERVICE_TIER` (empty falls back to `~/.codex/config.toml`).
- **Effort:** the GPT-5.5 seats are locked at `xhigh`; the Opus seats follow the **session's** reasoning
  effort (run Fusion at `/effort max` — the `Agent` tool has no per-call effort flag).
- `/fable5-fusion:fusion` slash command, `detect_panel.sh` (codex readiness check), structured
  references (`panel.md`, `judge_rubric.md`), and a Fable 5 `CLAUDE.md`.

### Requirements
- The `codex` CLI installed and logged in with GPT-5.5 access (tested against `codex-cli` 0.139). The two
  Opus panelists run as Claude Code `Agent` subagents and the judge is the orchestrator itself (the live
  Claude session) — the Opus seats need no extra CLI.

### Credit
- Architecture adapted from [duolahypercho/fusion-fable](https://github.com/duolahypercho/fusion-fable) (MIT).
