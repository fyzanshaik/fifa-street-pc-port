#!/usr/bin/env python3
"""Summarize a saved bounded performance session; never launches the game."""
import argparse
import csv
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
import statistics


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[int((len(ordered) - 1) * fraction)] if ordered else None


def analyze(session, log_utc_offset_minutes=None):
    start = datetime.strptime(session.name, "%Y%m%dT%H%M%S.%fZ").replace(tzinfo=timezone.utc)
    log = (session / "fifastreet.log").read_text()
    setup = json.loads((session / "setup.json").read_text())
    offset = log_utc_offset_minutes if log_utc_offset_minutes is not None else setup.get("log_utc_offset_minutes")
    if offset is None:
        raise ValueError("legacy session lacks its log UTC offset; pass --log-utc-offset-minutes explicitly")
    exit_info = json.loads((session / "exit.json").read_text())
    cadence = []
    present_timeouts = 0
    present_calls = 0
    for line in log.splitlines():
        timestamp = re.match(r"\[([^]]+)\]", line)
        match = re.search(r"VulkanFrameCadence: seconds=([\d.]+) presents=(\d+) repeated=(\d+) skipped=(\d+) new_frame_ms median=([\d.]+) p95=([\d.]+) max=([\d.]+)", line)
        if match and timestamp:
            local = datetime.fromisoformat(timestamp[1]).replace(tzinfo=timezone(timedelta(minutes=offset)))
            seconds, presents, repeated, skipped, median, p95, maximum = match.groups()
            interval = float(seconds)
            cadence.append({"elapsed_s": round((local - start).total_seconds(), 3),
                "window_s": interval, "presents": int(presents), "repeated": int(repeated),
                "skipped": int(skipped), "host_presents_per_s": round(int(presents) / interval, 3),
                "observed_new_outputs_per_s": round((int(presents) - int(repeated)) / interval, 3),
                "new_output_gap_max_ms": float(maximum), "new_output_gap_median_ms": float(median)})
        match = re.search(r"VulkanPresentTiming: calls=(\d+) timeouts=(\d+)", line)
        if match:
            present_calls += int(match[1])
            present_timeouts += int(match[2])
    if not cadence:
        raise ValueError("no frame cadence records; cannot summarize presentation")
    cpu = [{"elapsed_s": float(row["elapsed_seconds"]), "cpu_percent": float(row["cpu_percent"])}
           for row in csv.DictReader((session / "cpu.csv").open())]
    swaps = list(csv.DictReader((session / "guest-perf.csv").open()))
    swap_ms = [int(row["frame_time_us"]) / 1000 for row in swaps
               if row.get("frame_time_us") and int(row["frame_time_us"]) > 0]
    total_seconds = sum(row["window_s"] for row in cadence)
    longest = max(cadence, key=lambda row: row["new_output_gap_max_ms"])
    audio_endpoint = re.search(r"audio endpoint .*", log)
    return {"session": str(session), "setup": setup, "exit": exit_info,
        "cadence": cadence, "cpu": cpu,
        "summary": {"cadence_windows": len(cadence), "measured_seconds": round(total_seconds, 3),
            "host_presents": sum(row["presents"] for row in cadence),
            "host_presents_per_s": round(sum(row["presents"] for row in cadence) / total_seconds, 3),
            "repeated_outputs": sum(row["repeated"] for row in cadence),
            "skipped_outputs": sum(row["skipped"] for row in cadence),
            "present_calls": present_calls, "acquire_timeouts": present_timeouts,
            "longest_output_gap_ms": longest["new_output_gap_max_ms"],
            "longest_gap_observed_at_s": longest["elapsed_s"],
            "cpu_percent_median": statistics.median(row["cpu_percent"] for row in cpu),
            "cpu_percent_max": max(row["cpu_percent"] for row in cpu),
            "guest_swap_rows": len(swaps), "guest_swap_median_ms": statistics.median(swap_ms),
            "guest_swap_p95_ms": percentile(swap_ms, .95), "guest_swap_max_ms": max(swap_ms),
            "audio_endpoint": audio_endpoint[0] if audio_endpoint else None},
        "limits": ["Host presents are queued presentations, not physical scanout timestamps.",
            "New-output cadence observes guest-output sequence changes at host presents, not simulation or audio clocks.",
            "Gap statistics may include an interval crossing a five-second window boundary.",
            "CPU percentage comes from ps; 100% corresponds to one logical CPU and is not a wall-stack sample percentage.",
            "Guest CSV records GPU guest-swap intervals; it has no per-row wall timestamp and may lose buffered rows on hard exit.",
            "The Info/loading boundary was not timestamped; its exact position on the timeline is unknown.",
            ("Audio submission, inserted silence and callback timing are recorded separately in runtime.jsonl; "
             "run analyze-macos-runtime-diagnostics.py. Physical audio latency is not measured."
             if (session / "runtime.jsonl").exists() else
             "No audio submission, silence-insertion, queue latency or callback-duration measurement was captured."),
            "Profiling and timing overhead have not been calibrated; frame readback was disabled."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", type=Path)
    parser.add_argument("--log-utc-offset-minutes", type=int)
    args = parser.parse_args()
    session = args.session.resolve()
    result = analyze(session, args.log_utc_offset_minutes)
    (session / "analysis.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["summary"], indent=2))
    print("Exit:", result["exit"])
    print("Saved:", session / "analysis.json")


if __name__ == "__main__":
    main()
