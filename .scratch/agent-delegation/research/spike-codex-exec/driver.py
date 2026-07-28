#!/usr/bin/env python3
"""
Spike driver for `codex exec --json` headless behaviour.

Launches the codex binary as its OWN process group (start_new_session=True)
so that any signal we send targets only that group, never our own shell.
Streams stdout/stderr to files as they arrive (so a killed/timed-out run
still leaves partial evidence on disk), then writes a meta.json with
timing, exit code, signal semantics, and a leftover-process check.

Usage:
  python3 driver.py <scenario_name> \
      --args '["exec","--json","-s","read-only","prompt text"]' \
      --env '{"FOO":"bar"}' \
      --strip-path \
      --timeout 60 \
      --interrupt-after 8 \
      --interrupt-signal SIGTERM

All paths are absolute. CODEX_HOME and cwd are fixed to the sandbox dirs
below unless overridden.
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time

CODEX_BIN = "/Users/heqianbin/.codex/plugins/.plugin-appserver/codex"
SPIKE_DIR = "/Users/Shared/Workspaces/PROJECT_AA/.claude/worktrees/research-next/.scratch/agent-delegation/research/spike-codex-exec"
SANDBOX_CWD = os.path.join(SPIKE_DIR, "sandbox")
CODEX_HOME = os.path.join(SPIKE_DIR, "codex_home")
SAMPLES_DIR = os.path.join(SPIKE_DIR, "samples")


def pids_under(pgid):
    """Return list of (pid, cmd) still alive in process group pgid via ps."""
    try:
        out = subprocess.check_output(
            ["ps", "-o", "pid,pgid,command", "-g", str(pgid)],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except subprocess.CalledProcessError:
        return []
    lines = out.strip().splitlines()[1:]  # skip header
    return [l.strip() for l in lines]


def stream_reader(pipe, out_path, chunks):
    with open(out_path, "wb") as f:
        for line in iter(pipe.readline, b""):
            f.write(line)
            f.flush()
            chunks.append(line)
    pipe.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario")
    ap.add_argument("--args", required=True, help="JSON array of argv (after the binary itself)")
    ap.add_argument("--env", default="{}", help="JSON object of extra env vars to set/override")
    ap.add_argument("--strip-path", action="store_true", help="Run with a minimal/empty PATH")
    ap.add_argument("--minimal-path", default=None, help="If set, PATH becomes exactly this value")
    ap.add_argument("--timeout", type=float, default=120, help="Hard wall-clock cap in seconds (<=180)")
    ap.add_argument("--interrupt-after", type=float, default=None,
                     help="If set, send --interrupt-signal to the process group after this many seconds")
    ap.add_argument("--interrupt-signal", default="SIGTERM")
    ap.add_argument("--grace", type=float, default=10, help="Seconds to wait after interrupt before SIGKILL")
    args = ap.parse_args()

    assert args.timeout <= 180, "guardrail: timeout must be <=180s"

    argv = json.loads(args.args)
    extra_env = json.loads(args.env)

    env = dict(os.environ)
    env["CODEX_HOME"] = CODEX_HOME
    if args.strip_path:
        env["PATH"] = ""
    if args.minimal_path is not None:
        env["PATH"] = args.minimal_path
    env.update(extra_env)

    os.makedirs(SANDBOX_CWD, exist_ok=True)
    os.makedirs(SAMPLES_DIR, exist_ok=True)

    stdout_path = os.path.join(SAMPLES_DIR, f"{args.scenario}.stdout.jsonl")
    stderr_path = os.path.join(SAMPLES_DIR, f"{args.scenario}.stderr.txt")
    meta_path = os.path.join(SAMPLES_DIR, f"{args.scenario}.meta.json")

    full_cmd = [CODEX_BIN] + argv

    meta = {
        "scenario": args.scenario,
        "cmd": full_cmd,
        "cwd": SANDBOX_CWD,
        "codex_home": CODEX_HOME,
        "env_overrides_intentional": {
            "CODEX_HOME": CODEX_HOME,
            **({"PATH": env.get("PATH", "")} if (args.strip_path or args.minimal_path is not None) else {}),
            **extra_env,
        },
        "timeout_s": args.timeout,
        "interrupt_after_s": args.interrupt_after,
        "interrupt_signal": args.interrupt_signal if args.interrupt_after else None,
    }

    start = time.time()
    meta["start_iso"] = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(start))

    proc = subprocess.Popen(
        full_cmd,
        cwd=SANDBOX_CWD,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,  # own process group; pgid == pid
    )
    pgid = proc.pid  # leader pid == pgid because start_new_session

    out_chunks, err_chunks = [], []
    t_out = threading.Thread(target=stream_reader, args=(proc.stdout, stdout_path, out_chunks))
    t_err = threading.Thread(target=stream_reader, args=(proc.stderr, stderr_path, err_chunks))
    t_out.start()
    t_err.start()

    interrupted = False
    interrupt_sent_at = None
    killed = False

    def send_signal(sig_name):
        sig = getattr(signal, sig_name)
        try:
            os.killpg(pgid, sig)
            return True
        except ProcessLookupError:
            return False

    if args.interrupt_after is not None:
        # Wait up to interrupt_after seconds, or until process exits early.
        exited = False
        waited = 0.0
        step = 0.2
        while waited < args.interrupt_after:
            if proc.poll() is not None:
                exited = True
                break
            time.sleep(step)
            waited += step
        if not exited:
            interrupt_sent_at = time.time() - start
            interrupted = send_signal(args.interrupt_signal)
            # Grace period, then escalate to SIGKILL if still alive.
            grace_deadline = time.time() + args.grace
            while time.time() < grace_deadline:
                if proc.poll() is not None:
                    break
                time.sleep(0.2)
            if proc.poll() is None:
                killed = send_signal("SIGKILL")

    try:
        proc.wait(timeout=max(1.0, args.timeout - (time.time() - start)))
    except subprocess.TimeoutExpired:
        # Hard cap safety net: kill the group.
        send_signal("SIGTERM")
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            send_signal("SIGKILL")
            proc.wait(timeout=10)
        meta["hard_timeout_triggered"] = True

    t_out.join(timeout=5)
    t_err.join(timeout=5)

    end = time.time()
    # Check for leftover processes in the group shortly after exit.
    time.sleep(0.3)
    leftover = pids_under(pgid)

    returncode = proc.returncode
    meta.update({
        "end_iso": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(end)),
        "duration_s": round(end - start, 3),
        "returncode": returncode,
        "returncode_meaning": (
            f"terminated by signal {-returncode} ({signal.Signals(-returncode).name})"
            if returncode is not None and returncode < 0
            else "normal exit"
        ),
        "interrupt_actually_sent": interrupted,
        "interrupt_sent_at_s": interrupt_sent_at,
        "escalated_to_sigkill": killed,
        "leftover_processes_in_pgid_after_exit": leftover,
        "stdout_path": stdout_path,
        "stderr_path": stderr_path,
        "stdout_lines": len(out_chunks),
        "stderr_bytes": sum(len(c) for c in err_chunks),
    })

    with open(meta_path, "w") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)

    print(json.dumps(meta, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
