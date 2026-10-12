#!/usr/bin/env python3
"""Run bounded live-model game tasks through this checkout's built fx binary."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "zig-out/bin/fx"
MODEL = "stealth/space-bunny-alpha"


def binary_identity(path):
    with path.open("rb") as binary:
        digest = hashlib.file_digest(binary, "sha256").hexdigest()
        stat = os.fstat(binary.fileno())
    return {"sha256": digest, "bytes": stat.st_size}


def provider_settings(model, base_url, key_env, effort="low", reasoning_format="openrouter"):
    return {
        "provider": "game-bench", "model": model, "auto_upgrade": False,
        "max_agent_steps": 24,
        "providers": {"game-bench": {
            "protocol": "openai-chat-completions", "base_url": base_url,
            "auth": {"type": "bearer", "env": key_env},
            "tool_choice_mode": "send", "reviewer_model": model,
            "reasoning_format": reasoning_format,
            "model_metadata": {model: {
                "context_window": 1000000, "max_output_tokens": 16384,
                "supports_tool_use": True, "supports_vision": False,
                "reasoning_efforts": [effort] if effort != "auto" else [],
            }},
        }},
    }


def read_io(pid):
    try:
        return {key: int(value) for key, value in
                (line.split(":", 1) for line in Path(f"/proc/{pid}/io").read_text().splitlines())}
    except (OSError, ValueError):
        return {}


def tree_size(path):
    files = [p for p in path.rglob("*") if p.is_file() and not p.is_symlink()]
    return {"files": len(files), "bytes": sum(p.stat().st_size for p in files)}


def run_task(task, output, timeout, model, base_url, key_env, effort="low", reasoning_format="openrouter", observe_io=False):
    run = output / task["id"]
    run.mkdir(mode=0o700)
    workspace, home = run / "workspace", run / "home"
    workspace.mkdir(mode=0o700)
    (home / ".fx").mkdir(parents=True, mode=0o700)
    settings = home / ".fx/settings.json"
    settings.write_text(json.dumps(provider_settings(model, base_url, key_env, effort, reasoning_format)))
    settings.chmod(0o600)
    subprocess.run(["git", "init", "-q", str(workspace)], check=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("FX_")}
    for key in ("AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN", "OPENPATHS_API_KEY", "OPENROUTER_API_KEY"):
        if key != key_env:
            env.pop(key, None)
    env.update(HOME=str(home), FX_PROVIDER="game-bench", FX_MODEL=model,
               FX_PERMISSION_MODE="auto", FX_DISABLE_KEYCHAIN="1", FX_AUTO_UPGRADE="0",
               FX_E2E_DISABLE_DOTENV="1",
               FX_SOUND="0", FX_TRACE_LOG=str(run / "trace.log"),
               FX_TRACE_SCOPES="agent,tool,session,context_compaction,permission", FX_MAX_AGENT_STEPS="24")
    if observe_io:
        env["FX_ALLOW_DEBUG"] = "1"
    prompt = task["prompt"] + (
        " Work only inside the current directory. Create index.html, game.mjs, and verify.mjs."
        " Use a pinned Three.js 0.180.0 ES-module CDN import in the browser; do not install packages."
        " Keep simulation logic separable from rendering so node verify.mjs tests movement,"
        " collision, scoring, and restart deterministically without a DOM or network."
        " Run node verify.mjs and fix failures. Do not leave a server running."
        " After the first successful rendered frame, set document.documentElement.dataset.gameReady='true'."
        " Finish with concise verification results; do not claim browser testing unless you actually ran it."
    )
    (run / "prompt.txt").write_text(prompt)
    identity = binary_identity(BINARY)
    started = time.monotonic()
    samples = {}
    successful_samples = missed_samples = 0
    timed_out = False
    with (run / "stdout.json").open("wb") as stdout, (run / "stderr.txt").open("wb") as stderr:
        child = subprocess.Popen([str(BINARY), "ask", "--json", "--quiet", "--auto", "--effort", effort, prompt],
                                 cwd=workspace, env=env, stdout=stdout, stderr=stderr,
                                 start_new_session=True)
        try:
            while child.poll() is None:
                observation = read_io(child.pid)
                if observation:
                    successful_samples += 1
                else:
                    missed_samples += 1
                for key, value in observation.items():
                    samples[key] = max(value, samples.get(key, 0))
                if time.monotonic() - started > timeout:
                    timed_out = True
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                    break
                time.sleep(0.05)
            child.wait()
        finally:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    result = {"task": task["id"], "model": model, "base_url": base_url,
              "effort": effort, "reasoning_format": reasoning_format,
              "exit_code": child.returncode, "timed_out": timed_out,
              "wall_seconds": time.monotonic() - started,
              "sampled_root_process_io_lower_bound": samples,
              "io_observation": {"allow_debug": observe_io, "successful_samples": successful_samples,
                                 "missed_samples": missed_samples, "complete": missed_samples == 0 and successful_samples > 0},
              "session_storage": tree_size(home / ".fx/sessions"),
              "workspace": tree_size(workspace), "binary": str(BINARY)}
    result["binary_identity_at_start"] = identity
    result["binary_path_changed_during_run"] = binary_identity(BINARY) != identity
    try:
        reply = json.loads((run / "stdout.json").read_text())
        result["reply"] = reply
    except (OSError, ValueError):
        result["reply"] = None
    result["required_files"] = {name: (workspace / name).is_file()
                                for name in ("index.html", "game.mjs", "verify.mjs")}
    if all(result["required_files"].values()):
        with (run / "verification.txt").open("wb") as log:
            try:
                verification = subprocess.run(["node", "verify.mjs"], cwd=workspace,
                                              env={"PATH": env.get("PATH", "/usr/bin:/bin"), "HOME": str(home)},
                                              stdout=log, stderr=subprocess.STDOUT, timeout=30)
                result["verification_exit_code"] = verification.returncode
            except subprocess.TimeoutExpired:
                result["verification_exit_code"] = "timeout"
    (run / "metrics.json").write_text(json.dumps(result, indent=2))
    print(json.dumps({k: v for k, v in result.items() if k != "reply"}), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task", default="orbit-dodger")
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("--model", default=MODEL)
    parser.add_argument("--base-url", default="https://openrouter.ai/api/v1")
    parser.add_argument("--key-env", default="OPENROUTER_API_KEY")
    parser.add_argument("--effort", default="low")
    parser.add_argument("--reasoning-format", choices=("omit", "effort", "openrouter"), default="openrouter")
    parser.add_argument("--observe-io", action="store_true", help="allow debugging of this private benchmark process for Linux I/O sampling")
    args = parser.parse_args()
    if args.reasoning_format == "omit" and args.effort != "auto":
        parser.error("use --effort auto when reasoning format is omit")
    if not BINARY.is_file():
        parser.error("run zig build first")
    if not os.environ.get(args.key_env):
        parser.error(f"set {args.key_env}")
    tasks = json.loads((ROOT / "games/tasks.json").read_text())
    selected = tasks if args.task == "all" else [task for task in tasks if task["id"] == args.task]
    if not selected or args.timeout <= 0:
        parser.error("choose a known task and positive timeout")
    output = ROOT / "games/runs" / datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    output.mkdir(parents=True, mode=0o700)
    print(f"artifacts: {output}", flush=True)
    results = [run_task(task, output, args.timeout, args.model, args.base_url, args.key_env, args.effort, args.reasoning_format, args.observe_io) for task in selected]
    return 0 if all(r["exit_code"] == 0 and r.get("verification_exit_code") == 0 for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
