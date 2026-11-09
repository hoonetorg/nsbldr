#!/usr/bin/env python3
"""compare_results.py <ansible.posix.json output> <ansible-runner job_events dir>
Compares per task/host status (ok/changed/failed/skipped/unreachable), the debug var results and the
play recap. Exit code 0 = same."""
import json
import sys
from pathlib import Path


def status(res, unreachable=False):
    if unreachable or res.get("unreachable"):
        return "unreachable"
    if res.get("failed"):
        return "failed"
    if res.get("skipped"):
        return "skipped"
    return "changed" if res.get("changed") else "ok"


def debug_value(task, res):
    var = (task.get("action") == "ansible.builtin.debug" or task.get("action") == "debug") and res.get("sample_filters")
    return json.dumps(var, sort_keys=True) if var else None


def from_json_callback(path):
    data = json.loads(Path(path).read_text())
    results = []
    for play in data["plays"]:
        for t in play["tasks"]:
            for host, res in t["hosts"].items():
                results.append((t["task"]["name"], host, status(res), json.dumps(res.get("sample_filters"), sort_keys=True) if "sample_filters" in res else None))
    stats = {h: {k: s.get(k, 0) for k in ("ok", "changed", "failures", "skipped", "unreachable")} for h, s in data["stats"].items()}
    return results, stats


def from_runner_events(path):
    events = sorted((json.loads(p.read_text()) for p in Path(path).glob("*.json")), key=lambda e: e["counter"])
    results, stats = [], {}
    for e in events:
        ev, d = e["event"], e.get("event_data", {})
        if ev in ("runner_on_ok", "runner_on_failed", "runner_on_skipped", "runner_on_unreachable"):
            res = d.get("res", {})
            if ev == "runner_on_skipped":
                res = {**res, "skipped": True}
            if ev == "runner_on_failed" and not d.get("ignore_errors"):
                res = {**res, "failed": True}
            results.append((d["task"], d["host"], status(res, ev == "runner_on_unreachable"),
                            json.dumps(res.get("sample_filters"), sort_keys=True) if "sample_filters" in res else None))
        elif ev == "playbook_on_stats":
            keys = {"ok": "ok", "changed": "changed", "failures": "failures", "skipped": "skipped", "unreachable": "dark"}
            hosts = set().union(*(d.get(v) or {} for v in keys.values()))
            stats = {h: {k: (d.get(v) or {}).get(h, 0) for k, v in keys.items()} for h in hosts}
    return results, stats


a_res, a_stats = from_json_callback(sys.argv[1])
b_res, b_stats = from_runner_events(sys.argv[2])
problems = []
if a_res != b_res:
    for i, (x, y) in enumerate(zip(a_res, b_res)):
        if x != y:
            problems.append(f"task #{i}: standalone={x} ee={y}")
    if len(a_res) != len(b_res):
        problems.append(f"task count: standalone={len(a_res)} ee={len(b_res)}")
if a_stats != b_stats:
    problems.append(f"recap: standalone={a_stats} ee={b_stats}")
if problems:
    print("; ".join(problems))
    sys.exit(1)
recap = next(iter(a_stats.values())) if a_stats else {}
print(f"{len(a_res)} task results, recap {recap}")
