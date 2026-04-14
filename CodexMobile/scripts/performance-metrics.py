#!/usr/bin/env python3
import argparse
import json
import statistics
import subprocess
import sys
from pathlib import Path


SUITES = {
    "turnview": {
        "name": "TurnView",
        "default_max_regression_percent": 10.0,
        "metrics": {
            "scroll_duration_s": {
                "test_id": "testTurnTimelineScrollingPerformance",
                "metric_id": "com.apple.dt.XCTMetric_OSSignpost-Scroll_DraggingAndDeceleration.duration",
            },
            "stream_clock_s": {
                "test_id": "testTurnStreamingAppendPerformance",
                "metric_id": "com.apple.dt.XCTMetric_Clock.time.monotonic",
            },
            "stream_cpu_time_s": {
                "test_id": "testTurnStreamingAppendPerformance",
                "metric_id": "com.apple.dt.XCTMetric_CPU.time",
            },
            "stream_peak_memory_kb": {
                "test_id": "testTurnStreamingAppendPerformance",
                "metric_id": "com.apple.dt.XCTMetric_Memory.physical_peak",
            },
        },
    },
    "sidebar": {
        "name": "Sidebar run-badge",
        "default_max_regression_percent": 12.0,
        "metrics": {
            "snapshot_clock_s": {
                "test_id": "testSidebarRunBadgeSnapshotPerformance",
                "metric_id": "com.apple.dt.XCTMetric_Clock.time.monotonic",
            },
            "snapshot_cpu_time_s": {
                "test_id": "testSidebarRunBadgeSnapshotPerformance",
                "metric_id": "com.apple.dt.XCTMetric_CPU.time",
            },
            "large_timeline_clock_s": {
                "test_id": "testSidebarRunBadgeSnapshotWithLargeTimelinePerformance",
                "metric_id": "com.apple.dt.XCTMetric_Clock.time.monotonic",
            },
            "large_timeline_cpu_time_s": {
                "test_id": "testSidebarRunBadgeSnapshotWithLargeTimelinePerformance",
                "metric_id": "com.apple.dt.XCTMetric_CPU.time",
            },
        },
    },
}


def load_metrics(xcresult_path: Path):
    completed = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "metrics", "--path", str(xcresult_path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(completed.stdout)


def find_average(metrics, test_name_fragment: str, metric_identifier: str) -> float:
    for test_entry in metrics:
        test_identifier = test_entry.get("testIdentifier", "")
        if test_name_fragment not in test_identifier:
            continue
        for run in test_entry.get("testRuns", []):
            for metric in run.get("metrics", []):
                if metric.get("identifier") == metric_identifier:
                    samples = metric.get("measurements", [])
                    if not samples:
                        raise RuntimeError(
                            f"No measurements for {test_name_fragment} / {metric_identifier}"
                        )
                    return statistics.fmean(samples)
    raise RuntimeError(f"Metric not found for {test_name_fragment} / {metric_identifier}")


def collect_suite_metrics(metrics, suite_key: str):
    suite = SUITES[suite_key]
    collected = {}
    for key, target in suite["metrics"].items():
        collected[key] = find_average(metrics, target["test_id"], target["metric_id"])
    return collected


def write_baseline(args):
    suite = SUITES[args.suite]
    metrics = load_metrics(Path(args.xcresult))
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    baseline = {
        "suite": args.suite,
        "name": suite["name"],
        "max_regression_percent": args.max_regression_percent,
        "metrics": collect_suite_metrics(metrics, args.suite),
    }
    output_path.write_text(json.dumps(baseline, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote baseline: {output_path}")
    for key, value in baseline["metrics"].items():
        print(f"- {key}: {value:.6f}")


def compare_against_baseline(args):
    suite = SUITES[args.suite]
    metrics = load_metrics(Path(args.xcresult))
    baseline = json.loads(Path(args.baseline).read_text(encoding="utf-8"))
    current = collect_suite_metrics(metrics, args.suite)

    max_regression_percent = (
        args.max_regression_percent
        if args.max_regression_percent is not None
        else float(baseline.get("max_regression_percent", suite["default_max_regression_percent"]))
    )
    allowed_multiplier = 1.0 + (max_regression_percent / 100.0)

    print(f"{suite['name']} performance check")
    print(f"Allowed regression: {max_regression_percent:.2f}%")

    failures = []
    for key, current_value in current.items():
        baseline_value = float(baseline["metrics"][key])
        threshold_value = baseline_value * allowed_multiplier
        regression_percent = ((current_value - baseline_value) / baseline_value) * 100.0
        print(
            f"- {key}: baseline={baseline_value:.6f}, current={current_value:.6f}, "
            f"delta={regression_percent:+.2f}%"
        )
        if current_value > threshold_value:
            failures.append(
                f"{key} regressed by {regression_percent:.2f}% "
                f"(baseline {baseline_value:.6f}, current {current_value:.6f}, max {max_regression_percent:.2f}%)"
            )

    if failures:
        print("\nPerformance regression check failed:")
        for failure in failures:
            print(f"  * {failure}")
        sys.exit(1)

    print("\nPerformance regression check passed.")


def build_parser():
    parser = argparse.ArgumentParser(description="Summarize and compare Xcode performance metrics.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    baseline_parser = subparsers.add_parser("baseline", help="Write a baseline JSON file from an xcresult bundle.")
    baseline_parser.add_argument("--suite", choices=sorted(SUITES), required=True)
    baseline_parser.add_argument("--xcresult", required=True)
    baseline_parser.add_argument("--output", required=True)
    baseline_parser.add_argument("--max-regression-percent", type=float)
    baseline_parser.set_defaults(func=write_baseline)

    compare_parser = subparsers.add_parser("compare", help="Compare an xcresult bundle against a baseline JSON file.")
    compare_parser.add_argument("--suite", choices=sorted(SUITES), required=True)
    compare_parser.add_argument("--xcresult", required=True)
    compare_parser.add_argument("--baseline", required=True)
    compare_parser.add_argument("--max-regression-percent", type=float)
    compare_parser.set_defaults(func=compare_against_baseline)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    if getattr(args, "max_regression_percent", None) is None:
        args.max_regression_percent = SUITES[args.suite]["default_max_regression_percent"]
        if args.command == "compare":
            args.max_regression_percent = None
    args.func(args)


if __name__ == "__main__":
    main()
