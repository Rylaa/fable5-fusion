#!/usr/bin/env bash
# _fusion_lib.sh — shared helpers for the Fusion seat runners.
#
# Sourced (not executed) by run_codex.sh and run_claude.sh:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/_fusion_lib.sh"
#
# Why this exists: stock macOS has no `timeout`/`gtimeout` (those ship with GNU coreutils, which isn't
# installed by default). _run_with_timeout reproduces GNU `timeout` semantics with a small, self-contained
# perl fork+alarm wrapper: on the deadline it sends SIGTERM to the seat's whole process group, then SIGKILL
# after a 2s grace, returns the command's real exit status, and returns 124 ONLY when it actually had to kill
# the command for running over time. Both runners wrap their seat (`codex exec` / `claude -p`) in it, so a
# single stuck seat can't hang the whole panel — on exit 124 the orchestrator drops that seat and degrades.
#
# Bash 3.2 safe (macOS default): no associative arrays, no `local -n`, no process substitution.

# Default per-seat budget in seconds; override with FUSION_TIMEOUT (e.g. FUSION_TIMEOUT=900 for deep research).
FUSION_TIMEOUT="${FUSION_TIMEOUT:-300}"

# Validate it: must be a positive integer number of seconds. Anything else (empty, non-numeric, <=0, a
# decimal) falls back to 300 — we never silently accept 0/garbage, because alarm(0) means "no alarm" and
# would quietly DISABLE the per-seat deadline (the exact P1 invariant this helper exists to guarantee).
case "$FUSION_TIMEOUT" in
  ''|*[!0-9]*) _ft_ok=0 ;;
  *) if [ "$FUSION_TIMEOUT" -gt 0 ] 2>/dev/null; then _ft_ok=1; else _ft_ok=0; fi ;;
esac
if [ "${_ft_ok:-0}" -ne 1 ]; then
  echo "[_fusion_lib.sh] FUSION_TIMEOUT='${FUSION_TIMEOUT}' is not a positive integer of seconds; falling back to 300." >&2
  FUSION_TIMEOUT=300
fi
unset _ft_ok

# _run_with_timeout SECONDS cmd [args...]
# Runs `cmd args...` with stdin/stdout/stderr inherited from the caller (so the caller's redirections apply
# to the wrapped command). Exit status = the command's own status, or 124 if it was killed for timing out.
#
# Requires perl (preinstalled on macOS and virtually every Linux). If perl is genuinely absent we do NOT run
# the command unbounded — that would silently drop the timeout invariant and could hang the panel — instead
# we fail fast with a distinct code (125) and a clear message, so the orchestrator drops the seat as absent.
_run_with_timeout() {
  local secs="$1"; shift
  if ! command -v perl >/dev/null 2>&1; then
    echo "[_fusion_lib.sh] perl not found: cannot enforce the per-seat FUSION_TIMEOUT." >&2
    echo "[_fusion_lib.sh] refusing to run this seat UNBOUNDED (that would risk hanging the panel)." >&2
    echo "[_fusion_lib.sh] install perl (shipped with macOS & most Linux) or GNU coreutils to restore timeouts." >&2
    return 125
  fi
  perl -e '
    my $secs = shift @ARGV;
    $secs = 300 unless ($secs =~ /^[0-9]+$/ && $secs > 0);   # defensive: positive int seconds
    my $pid = fork();
    defined $pid or do { warn "fork failed: $!\n"; exit 127; };
    if ($pid == 0) {
      # Child: lead a NEW process group so the parent can signal the whole subtree (codex/claude spawn
      # their own children — web search, sandbox helper, bash). Then become the real command.
      setpgrp(0, 0);
      exec { $ARGV[0] } @ARGV;
      exit 127;                                   # exec failed (not found / not executable)
    }
    # Parent: also place the child in its own group (race-free with the child: whichever call wins, the
    # child ends up in group == its own pid). Safe to ignore failure if the child already exec`d.
    setpgrp($pid, $pid);

    my $stage = 0;                                # 0=running  1=TERM sent (grace)  2=KILL sent
    $SIG{ALRM} = sub {
      if    ($stage == 0) { $stage = 1; kill(-15, $pid); alarm(2); }   # SIGTERM to the group, then 2s grace
      elsif ($stage == 1) { $stage = 2; kill(-9,  $pid); alarm(2); }   # SIGKILL the group if it ignored TERM
    };
    alarm($secs);

    my $rc = 0;
    while (1) {
      my $w = waitpid($pid, 0);
      if ($w == $pid) { $rc = $?; last; }
      if ($w == -1)   { last unless $!{EINTR}; }   # EINTR = our own alarm -> keep waiting; else give up
    }
    alarm(0);

    if ($stage > 0) {
      kill(-9, $pid);                              # the group still has the (now-reaped child`s) members
                                                   # only if a TERM-ignoring grandchild lingers; KILL them.
      exit 124;                                    # WE timed it out
    }
    # Not a timeout: propagate. Signal death => 128+signo (shell convention); else the real exit code.
    exit($rc & 127 ? 128 + ($rc & 127) : ($rc >> 8));
  ' "$secs" "$@"
}
