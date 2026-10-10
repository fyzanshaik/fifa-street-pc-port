#!/usr/bin/env python3
"""Bounded manual game check; collects metrics without operating the game UI."""
import argparse
import csv
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=root / "build/macos/performance-production/out/FIFA Street.app")
    parser.add_argument("--seconds", type=int, default=120)
    parser.add_argument("--runtime-diagnostics", action="store_true",
                        help="record opt-in audio and pipeline measurements to runtime.jsonl")
    parser.add_argument("--skip-stack-sample", action="store_true",
                        help="omit the scheduled stack sample to check for profiler interference")
    parser.add_argument("--frame-diagnostics", action="store_true",
                        help="enable shared-clock frame trace and GPU queries; implies runtime diagnostics and no stack sample")
    parser.add_argument("--moltenvk-submit-mode", choices=("inherit", "synchronous", "asynchronous"),
                        default="inherit", help="experimental per-run MoltenVK queue submission mode; does not change app defaults")
    parser.add_argument("--macos-unpaced-present", action="store_true",
                        help="experimental host-only immediate presentation; requires the matching SDK candidate")
    parser.add_argument("--macos-idle-toast-sleep", action="store_true",
                        help="experimental: stop redraw requests from the idle achievement toast")
    parser.add_argument("--macos-idle-exit-sleep", action="store_true",
                        help="experimental: wake the hidden exit overlay from input instead of continuous redraw")
    parser.add_argument("--audio-max-queued-frames", type=int,
                        help="per-run guest audio buffer limit (4-64 blocks, default inherited from app)")
    parser.add_argument("--macos-clock-no-scaling", action="store_true",
                        help="experimental per-run clock bypass; disables guest time scaling and system-time overrides")
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    if args.frame_diagnostics:
        args.runtime_diagnostics = True
        args.skip_stack_sample = True
    if not 15 <= args.seconds <= 300:
        parser.error("--seconds must be between 15 and 300")
    if args.audio_max_queued_frames is not None and not 4 <= args.audio_max_queued_frames <= 64:
        parser.error("--audio-max-queued-frames must be between 4 and 64")
    app = args.app.resolve()
    binary = app / "Contents/MacOS/fifastreet"
    data = (app / "Contents/MacOS/GameData").resolve()
    if not binary.is_file() or not (data / "default.xex").is_file():
        parser.error("app executable or linked GameData is missing")
    if args.check_only:
        print(f"Ready: {binary}\nGameData: {data}\nDuration: {args.seconds}s; no launch")
        return
    existing = subprocess.run(["pgrep", "-x", "fifastreet"], capture_output=True, text=True)
    if existing.returncode == 0:
        parser.error("a fifastreet process is already running; refusing a second instance")
    if existing.returncode != 1:
        parser.error("unable to check for an existing game process")
    session = root / "build/macos/logs/performance-check" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    session.mkdir(parents=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith("RESTREET_")}
    if args.moltenvk_submit_mode != "inherit":
        env["MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS"] = (
            "1" if args.moltenvk_submit_mode == "synchronous" else "0")
    if args.runtime_diagnostics:
        env["RESTREET_PERF_DIAG"] = str(session / "runtime.jsonl")
    command = [str(binary), f"--game_data_root={data}", "--vulkan_log_present_timing=true",
               f"--log_file={session / 'fifastreet.log'}",
               f"--perf_log_csv={session / 'guest-perf.csv'}"]
    if args.frame_diagnostics:
        command.append("--vulkan_log_sync_timing=true")
    if args.macos_unpaced_present:
        command.append("--vulkan_macos_unpaced_present=true")
    if args.macos_idle_toast_sleep:
        command.append("--macos_idle_toast_sleep=true")
    if args.macos_idle_exit_sleep:
        command.append("--macos_idle_exit_overlay_sleep=true")
    if args.audio_max_queued_frames is not None:
        command.append(f"--audio_maxqframes={args.audio_max_queued_frames}")
    if args.macos_clock_no_scaling:
        command.append("--clock_no_scaling=true")
    (session / "setup.json").write_text(json.dumps({
        "app": str(app), "command": command, "duration_seconds": args.seconds,
        "log_utc_offset_minutes": int(datetime.now().astimezone().utcoffset().total_seconds() / 60),
        "frame_capture": False, "virtual_input": False,
        "runtime_diagnostics": args.runtime_diagnostics,
        "stack_sample": not args.skip_stack_sample,
        "frame_diagnostics": args.frame_diagnostics,
        "moltenvk_submit_mode": args.moltenvk_submit_mode,
        "moltenvk_synchronous_queue_submits_env": env.get("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS"),
        "macos_unpaced_present": args.macos_unpaced_present,
        "macos_idle_toast_sleep": args.macos_idle_toast_sleep,
        "macos_idle_exit_sleep": args.macos_idle_exit_sleep,
        "audio_max_queued_frames": args.audio_max_queued_frames,
        "clock_no_scaling_override": args.macos_clock_no_scaling,
        "cpu_note": "ps CPU percentages are reported by macOS; they are not thread sample counts",
        "guest_note": "CSV frame_time_us measures GPU guest-swap intervals, not simulation/audio clocks",
    }, indent=2) + "\n")
    print(f"SESSION={session}", flush=True)
    process = None
    shutdown_escalated = False
    start = time.monotonic()
    try:
        with (session / "console.log").open("w") as log, (session / "cpu.csv").open("w") as cpu_file:
            process = subprocess.Popen(command, cwd=binary.parent, env=env, stdout=log, stderr=subprocess.STDOUT)
            print(f"PID={process.pid}; use the keyboard mapping configured in this app", flush=True)
            writer = csv.writer(cpu_file)
            writer.writerow(["elapsed_seconds", "pid", "cpu_percent", "rss_kib", "state"])
            sampled = False
            while process.poll() is None and time.monotonic() - start < args.seconds:
                elapsed = time.monotonic() - start
                state = subprocess.run(["ps", "-p", str(process.pid), "-o", "pid=,%cpu=,rss=,stat="],
                                       capture_output=True, text=True, timeout=5)
                fields = state.stdout.split()
                if len(fields) == 4:
                    writer.writerow([f"{elapsed:.3f}", *fields])
                    cpu_file.flush()
                    if int(elapsed) % 10 == 0:
                        print(f"elapsed={elapsed:.1f}s cpu={fields[1]}% rss={fields[2]} KiB", flush=True)
                if elapsed >= 60 and not sampled and not args.skip_stack_sample:
                    sampled = True
                    subprocess.run(["sample", str(process.pid), "2", "1", "-file", str(session / "sample.txt")],
                                   capture_output=True, timeout=10)
                    threads = subprocess.run(["ps", "-M", "-p", str(process.pid)], capture_output=True, text=True, timeout=5)
                    (session / "threads.txt").write_text(threads.stdout + threads.stderr)
                time.sleep(1)
    finally:
        if process is not None:
            stop_reason = "natural_exit"
            if process.poll() is None:
                stop_reason = "time_limit" if time.monotonic() - start >= args.seconds else "script_interrupted"
                process.terminate()  # SDL translates SIGTERM into a quit event.
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    shutdown_escalated = True
                    process.kill()  # Only the process this script launched.
                    process.wait(timeout=5)
            result = {"pid": process.pid, "exit_code": process.returncode,
                      "stop_reason": stop_reason, "shutdown_escalated": shutdown_escalated,
                      "elapsed_seconds": round(time.monotonic() - start, 3)}
            (session / "exit.json").write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
