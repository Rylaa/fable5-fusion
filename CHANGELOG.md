# Changelog

All notable changes to fable5-fusion are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [1.4.2] - 2026-07-01

Stabilize the panel when Opus seats are dropped by the shared Anthropic rate-limit pool (most visible as
"two Opus panelists stopped at ~44s with empty output while GPT-5.5 ran fine"). That is not the per-seat
timeout (exit 124) and not a hook — under several concurrent/overlapping `claude -p` seats (e.g. two panels
plus the interactive session) the pool returns 429, the CLI retries silently for tens of seconds, then the
seat dies empty; codex (a different provider) is unaffected.

### Added
- **Rate-limit-aware seat retry** in `run_claude.sh`: a seat that fails with a rate-limit signature
  (`temporarily limiting` / `429` / `overloaded` / `usage limit` …) backs off (exponential + jitter) and
  retries. A real timeout (124) or a non-rate-limit crash is never retried. Knobs: `FUSION_SEAT_RETRIES`
  (default 2; 0 disables), `FUSION_SEAT_RETRY_BACKOFF` (default 20s). Covers the synth seat too (same file).
- **Serial Opus launch** (`FUSION_OPUS_SERIAL`, default 1): the two Opus seats run one-at-a-time so a panel
  no longer bursts two concurrent Anthropic sessions; GPT-5.5 (codex, separate provider) still runs in
  parallel for free. `FUSION_OPUS_SERIAL=0` restores parallel launch.
- **`FUSION_OPUS_SEATS`** (1 or 2, default 2): run a single Opus panelist under a tight cap; the absent
  second seat is not misreported as a drop.

### Fixed
- **Cross-family synth fallback (real bug):** if the Opus synth seat fails AT RUNTIME (e.g. rate-limited)
  and codex is healthy, the synthesis now retries on GPT-5.5 — the symmetric twin of the v1.4.1 judge
  fallback. Previously synth fell back to codex only when `claude` was ABSENT, so a runtime Opus failure
  (common when both Opus panelists also dropped) lost the merged final answer.
- **Accurate panel slug from actual output:** two dropped Opus seats + a surviving GPT now read as
  `gpt5.5-only` (and one as `opus4.8x1-gpt5.5`) instead of a clean `opus4.8x2-gpt5.5`.
- The serial collect path waits each seat's PID exactly once (cached), avoiding a double-`wait` that would
  return 127 in bash and corrupt a seat's reported status.

### Notes
- The biggest real-world lever is behavioral: don't launch overlapping Fusion panels, and don't immediately
  re-fire a run that just dropped — that piles more onto the same pool. Under a heavy cap, `FUSION_JUDGE_CLI=claude`
  (v1.4.1) plus `FUSION_OPUS_SEATS=1` cut the per-run Anthropic draw further.

Tested: `codex/tests/fusion-runner.test.sh` is now 77/0 (55 original assertions unchanged; 22 new covering
serial launch, single-seat mode, cross-family synth fallback, slug accuracy, and the rate-limit retry /
no-retry-on-real-crash paths).

## [1.4.1] - 2026-06-30

### Fixed
- **Judge now has a cross-family fallback (the Codex-side stability fix).** Previously the Codex runner
  chose the judge CLI by *availability* only: if `codex` was present it ran the judge on codex, and a
  runtime failure (non-zero exit, empty output, or `FUSION_TIMEOUT` exit 124) dropped straight to a
  placeholder — the synthesizer then ran **without** the judge analysis while the run still looked like a
  full panel. This asymmetry (the synth already fell back `claude`→`codex`, the judge did not) is the
  "judge fell but synth kept going" symptom. The judge now retries on the other model family: `auto`
  (default) tries codex (GPT-5.5, xhigh) and, on failure or absence, **automatically retries on claude
  (Opus, max)** before any placeholder — only if *both* fail does the synth proceed judge-less.
- **A dropped judge is no longer invisible.** When both judges fail, the run prints a `Degradation:` line
  (`judge seat failed — final answer synthesized WITHOUT the judge analysis`) on stdout and in the
  provenance note, instead of presenting a judge-less synthesis as a clean full-panel run.
- **Provenance no longer hard-codes "GPT-5.5 judge".** `save_run.sh` records the judge that *actually*
  ran via `FUSION_JUDGE_LABEL` (the runner passes it); it still defaults to `GPT-5.5 judge` for the
  Claude Code path, whose judge is always GPT-5.5 (codex).
- **Under-reporting fixed.** A dropped Opus panelist (e.g. `opus1` down while `opus2` + GPT-5.5 survived)
  is now surfaced in the degradation note rather than passed off as a clean full panel.
- **Docs: `FUSION_TIMEOUT=900` → `3600`** in all heavy-run examples (README, SKILL ×3, `commands/fusion.md`,
  `codex/README.md`, the runner header). The default is **1800s**, so `900` *halved* the budget — the
  opposite of the "raise it for a heavy run" advice the examples were giving.

### Added
- **`FUSION_JUDGE_CLI` knob** — `auto` (default; codex then claude), `codex` (codex only, no retry), or
  `claude` (Opus judge from the start, skipping codex). `claude` cuts a run's Codex calls from two to one
  (just the GPT-5.5 panelist), easing the rolling/weekly Codex cap at the cost of a same-family judge/synth.
- **Documented the `FUSION_SERVICE_TIER=` (empty) opt-out** in `codex/README.md`: on a subscription-auth'd
  Codex you may not be entitled to the `priority` tier, and clearing it (falling back to
  `~/.codex/config.toml`) trades the fast tier for steadier GPT-5.5 calls. The code already supported the
  empty value; only the docs were missing.
- **Judge-fallback tests.** `codex/tests/fusion-runner.test.sh` grows from 29 to **55** stubbed
  assertions: codex-judge-fail → claude-judge-retry (no degradation note, ordering preserved), both
  judges fail → placeholder + visible note + provenance, and `FUSION_JUDGE_CLI=claude` → codex judge never
  attempted while the GPT-5.5 panelist still runs.

### Notes
- The full-panel happy path is unchanged: when the codex judge succeeds, the run behaves exactly as
  before. The Claude Code path (`/fable5-fusion:fusion`) is unaffected apart from the shared `save_run.sh`
  judge-label and the doc fixes. No `--dangerously-bypass-approvals-and-sandbox` is added as a seat arg.

## [1.4.0] - 2026-06-30

### Added
- **Codex CLI support (additive).** A new `codex/` directory lets you run the same Fusion panel from the
  Codex CLI with `/fusion <task>`, mirroring the Claude Code `/fable5-fusion:fusion` experience. Codex
  (GPT-5.5) becomes the orchestrator; the panel is unchanged (2x Opus 4.8 + 1x GPT-5.5 panelists,
  GPT-5.5 judge, Opus 4.8 synth) and reuses the existing seat runners (`run_claude.sh`, `run_codex.sh`,
  `save_run.sh`, ...) verbatim.
  - `codex/fusion-runner.sh` — a deterministic Step 0-6 orchestrator (detect -> preflight -> fan out ->
    judge -> synth -> save -> present) so the codex prompt stays thin (it just pipes the task to the
    runner on stdin). Streams progress to stderr; prints `FUSION FINAL ANSWER` + `FUSION AUDIT TRAIL`.
  - `codex/prompts/fusion.md` — the `/fusion` custom prompt (installed to `~/.codex/prompts/`).
  - `codex/install.sh` — additive installer; never silently overwrites a different existing
    `fusion.md` / `fusion-runner.sh` (refuses without `--force`; backs the old file up with it).
  - `codex/tests/fusion-runner.test.sh` — 29 stubbed orchestration assertions (seat fan-out, ordering,
    degraded claude-missing path, provenance slugs, synth model routing).
  - `codex/README.md` — install / run / sandbox notes.
- The Codex orchestrator must run un-sandboxed (`codex --sandbox danger-full-access --ask-for-approval
  never`): macOS Seatbelt cannot be nested, and each GPT-5.5 seat applies its own `-s workspace-write`
  sandbox, so a sandboxed parent would kill the nested seats (verified empirically). The seats' own
  isolation is unchanged — only the orchestrator is unsandboxed. Nothing in the Claude Code plugin
  (`skills/`, `commands/`, `references/`) is touched.

## [1.3.1] - 2026-06-30

### Changed
- Raised the default per-seat timeout `FUSION_TIMEOUT` from **300s to 1800s** (30 min). The 300s default
  was too tight for an Opus 4.8 seat running at locked `max` on a heavy research or multi-file
  implementation task — such seats legitimately need ~15-30 min and were being killed at the deadline
  (exit 124) before finishing. The cap still prevents a genuinely stuck seat from hanging the panel;
  override per run with `FUSION_TIMEOUT` (e.g. `FUSION_TIMEOUT=600` to reclaim a stuck seat faster on
  quick runs, `FUSION_TIMEOUT=3600` for a very heavy merge). `_fusion_lib.sh` (default + garbage
  fallback + perl-side default), `preflight.sh`, and all docs updated to match.

## [1.3.0] - 2026-06-30

Operational hardening ported from upstream ([duolahypercho/fusion-fable](https://github.com/duolahypercho/fusion-fable)),
adapted to this build's fixed 5-seat panel — **without** touching the locked-max panelists, the cross-family
GPT-5.5-judge / Opus-synth split, the priority service tier, or the codex sandbox.

### Added
- **Per-seat timeout.** New `_fusion_lib.sh` provides `_run_with_timeout` — a self-contained perl fork+alarm
  wrapper, since stock macOS ships no `timeout`/`gtimeout`. **Both** `run_codex.sh` and `run_claude.sh` now
  wrap their CLI call in it: `FUSION_TIMEOUT` (default 300s) bounds every reasoning seat, and a seat that runs
  over exits **124** so the orchestrator treats it as absent and degrades the panel instead of hanging. The
  wrapper kills the seat's **whole process group** (SIGTERM → 2s grace → SIGKILL), so codex/claude child
  processes don't survive a timeout; it returns 124 **only** for a real timeout (a seat that dies of its own
  signal is reported as `128+signo`, not mis-flagged as a timeout); `FUSION_TIMEOUT` is validated as a
  positive integer (anything else falls back to 300 — a 0/garbage value can't silently disable the deadline);
  and if `perl` is somehow absent it **fails fast** (exit 125) rather than running the seat unbounded. The
  codex seat keeps `-s workspace-write` + `service_tier=priority`; the claude seats keep locked `--effort max`
  + `--disallowedTools "Task Agent"`.
- **Provenance recording.** New `save_run.sh` writes a timestamped `~/.claude/fusion-runs/<ts>_<slug>.md` per
  run — the verbatim question + all raw panelist answers (`opus-A` / `opus-B` / `gpt5.5`) + the judge analysis
  + the final answer, with placeholders for any absent seat. Written `0600` under a `0700` dir (a pre-existing
  runs dir is tightened to `0700`); the verbatim question is wrapped in a backtick fence sized longer than any
  backtick run it contains, so a question with ``` in it can't corrupt the audit file. Opt out entirely with
  `FUSION_NO_SAVE=1`.
- **Preflight.** New `preflight.sh` prints a non-blocking (always `exit 0`, even with no argument or a missing
  file) token / latency / timeout estimate for the fixed 5-seat panel before fan-out.
- **`gh auth` precheck** in `run_codex.sh`: warns (never blocks) if `gh` is installed but unauthenticated in
  the parent environment. The codex seat stays sandboxed — this build does **not** add
  `--dangerously-bypass-approvals-and-sandbox`.
- **`.gitignore`** for OS/editor cruft and Fusion scratch.

### Changed
- SKILL flow renumbered to Step 0 verify → **1 preflight** → 2 fan out → 3 judge → 4 synthesize →
  **5 save provenance** → 6 present. The background-task "wait for notification" semantics now spell out that
  a seat hitting its `FUSION_TIMEOUT` (exit 124), exiting non-zero, or leaving an empty file is **absent** —
  judge/synthesize with the seats you have. `references/panel.md` and `references/judge_rubric.md` document the
  timeout/absent semantics.

### Fixed
- **License/author consistency.** The project is now attributed to **Rylaa** across `LICENSE` and
  `.claude-plugin/plugin.json` (both previously said "yusuf"), matching `README.md` and
  `.claude-plugin/marketplace.json`.

### Not ported (out of scope)
- All Gemini seats (`run_gemini.sh`, `agy_capture.py`, `_pty_run.py`, the Gemini slugs/commands) and the
  `--dangerously-bypass-approvals-and-sandbox` codex flag from upstream are deliberately excluded. The codex
  sandbox, the locked-max Opus panelists, and the cross-family GPT-5.5-judge / Opus-synth pipeline are
  preserved.

## [1.2.0] - 2026-06-21

Swap the judge and synthesizer model families.

### Changed
- Judge is now GPT-5.5 (codex, xhigh, priority/fast tier) instead of the Opus orchestrator; the orchestrator
  no longer judges.
- Synthesizer is now Claude Opus 4.8 (`claude -p` via `run_claude.sh`, locked max) instead of GPT-5.5.
- Consequence: every reasoning seat (2 Opus panelists, 1 GPT panelist, GPT judge, Opus synth) is now a
  parameter-locked subprocess; output no longer depends on the orchestrator's session effort. The
  orchestrator is a pure coordinator.

The judge/synth split stays cross-family — now GPT-5.5 analyzes and Opus writes, so the writer still isn't
grading its own draft.

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
