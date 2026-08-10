"""Result caching and reporting for the Package Index corpus harness."""

from __future__ import annotations

import csv
import json
from pathlib import Path
import random
import statistics
import sys
from typing import Iterable


ResultKey = tuple[str, str]


def result_key(row: dict[str, object]) -> ResultKey | None:
    url = row.get("url")
    sha256 = row.get("sha256")
    if not isinstance(url, str) or not isinstance(sha256, str):
        return None
    return url, sha256.lower()


def index_results(rows: Iterable[dict[str, object]]) -> dict[ResultKey, dict[str, object]]:
    """Keep the latest complete result for each immutable manifest identity."""
    indexed: dict[ResultKey, dict[str, object]] = {}
    for row in rows:
        key = result_key(row)
        if key is not None:
            indexed[key] = row
    return indexed


def partition_pending(
    fetched: list[dict[str, object]],
    cached: dict[ResultKey, dict[str, object]],
    selected_crosscheck_keys: set[ResultKey],
    rerun: bool,
    evaluator_fingerprint: str,
) -> tuple[dict[ResultKey, dict[str, object]], list[dict[str, object]]]:
    """Split the current selection into safely reusable and pending rows."""
    reusable: dict[ResultKey, dict[str, object]] = {}
    pending: list[dict[str, object]] = []
    for row in fetched:
        key = result_key(row)
        existing = cached.get(key) if key is not None else None
        needs_new_crosscheck = (
            key in selected_crosscheck_keys
            and existing is not None
            and existing.get("status") == "success"
            and not existing.get("crosscheck")
        )
        matches_evaluator = (
            existing is not None
            and existing.get("evaluatorFingerprint") == evaluator_fingerprint
        )
        if (
            not rerun
            and key is not None
            and existing is not None
            and matches_evaluator
            and not needs_new_crosscheck
        ):
            reusable[key] = existing
        else:
            pending.append(row)
    return reusable, pending


def select_crosscheck_rows(
    fetched: list[dict[str, object]],
    cached: dict[ResultKey, dict[str, object]],
    evaluator_fingerprint: str,
    requested_count: int,
    seed: int,
) -> list[dict[str, object]]:
    """Prefer known fast-path successes, then unknowns, for useful crosschecks."""
    pools: dict[str, list[dict[str, object]]] = {
        "cachedSuccess": [],
        "unknown": [],
        "cachedNonSuccess": [],
    }
    for row in fetched:
        key = result_key(row)
        result = cached.get(key) if key is not None else None
        if result is None or result.get("evaluatorFingerprint") != evaluator_fingerprint:
            basis = "unknown"
        elif result.get("status") == "success":
            basis = "cachedSuccess"
        else:
            basis = "cachedNonSuccess"
        pools[basis].append(row)

    count = len(fetched) if requested_count == 0 else min(requested_count, len(fetched))
    generator = random.Random(seed)
    selected: list[dict[str, object]] = []
    for basis in ("cachedSuccess", "unknown", "cachedNonSuccess"):
        remaining = count - len(selected)
        if remaining <= 0:
            break
        chosen = generator.sample(pools[basis], min(remaining, len(pools[basis])))
        for row in chosen:
            row["crosscheckSelectionBasis"] = basis
        selected.extend(chosen)
    return selected


def completed_pending_results(
    pending: list[dict[str, object]],
    streamed_rows: list[dict[str, object]],
) -> tuple[dict[ResultKey, dict[str, object]], list[dict[str, object]]]:
    """Filter streamed output to this pending batch and restore input order."""
    pending_keys = {key for row in pending if (key := result_key(row)) is not None}
    indexed = {
        key: value
        for key, value in index_results(streamed_rows).items()
        if key in pending_keys
    }
    ordered = [indexed[key] for row in pending if (key := result_key(row)) in indexed]
    return indexed, ordered


def read_json_lines(path: Path, tolerate_invalid: bool = False) -> list[dict[str, object]]:
    if not path.is_file():
        return []
    rows: list[dict[str, object]] = []
    with path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
                if not isinstance(value, dict):
                    raise ValueError("JSONL row is not an object")
                rows.append(value)
            except (json.JSONDecodeError, ValueError) as error:
                if not tolerate_invalid:
                    raise
                print(
                    f"warning: ignoring incomplete result row {path}:{line_number}: {error}",
                    file=sys.stderr,
                )
    return rows


def write_json_lines(path: Path, rows: Iterable[dict[str, object]]) -> None:
    """Atomically replace a JSONL file so an interrupted harness keeps its cache."""
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        for row in rows:
            json.dump(row, stream, sort_keys=True)
            stream.write("\n")
    temporary.replace(path)


def is_supported_tools_result(row: dict[str, object]) -> bool:
    """Whether SwiftPM parsed a tools version inside this loader's supported window."""
    tools_version = row.get("toolsVersion")
    return (
        isinstance(tools_version, str)
        and bool(tools_version)
        and row.get("reasonCode")
        not in ("unsupported-tools-version", "unsupported-language-mode")
    )


def crosscheck_summary(
    selected_rows: list[dict[str, object]],
    results: list[dict[str, object]],
) -> dict[str, object]:
    by_key = index_results(results)
    counts = {
        "requested": len(selected_rows),
        "prepared": 0,
        "preparationErrors": 0,
        "success": 0,
        "mismatch": 0,
        "fallback": 0,
        "error": 0,
        "missing": 0,
    }
    preparation_examples: list[dict[str, str]] = []
    selection_basis: dict[str, int] = {}
    for selected in selected_rows:
        basis = str(selected.get("crosscheckSelectionBasis", "unspecified"))
        selection_basis[basis] = selection_basis.get(basis, 0) + 1
        preparation_error = selected.get("crosscheckPreparationError")
        if preparation_error:
            counts["preparationErrors"] += 1
            if len(preparation_examples) < 5:
                preparation_examples.append(
                    {"url": str(selected.get("url", "")), "detail": str(preparation_error)}
                )
            continue
        if "packagePath" not in selected:
            counts["preparationErrors"] += 1
            continue
        counts["prepared"] += 1
        result = by_key.get(result_key(selected))
        if result is None:
            counts["missing"] += 1
            continue
        # A fast-path miss is a valid result but has nothing to crosscheck.
        if result.get("status") in ("fallback", "parseFailure"):
            counts["fallback"] += 1
            continue
        crosscheck = str(result.get("crosscheck", ""))
        if crosscheck == "success":
            counts["success"] += 1
        elif crosscheck == "mismatch" or result.get("status") == "crosscheckMismatch":
            counts["mismatch"] += 1
        elif crosscheck.startswith("fallback:"):
            counts["fallback"] += 1
        elif crosscheck == "error":
            counts["error"] += 1
        else:
            counts["missing"] += 1
    return {
        **counts,
        "selectionBasis": dict(sorted(selection_basis.items())),
        "preparationErrorExamples": preparation_examples,
    }


def percentile(values: list[int], percent: float) -> int | None:
    if not values:
        return None
    index = max(0, min(len(values) - 1, int((len(values) - 1) * percent + 0.5)))
    return sorted(values)[index]


def milliseconds(nanoseconds: int | float | None) -> float | None:
    return None if nanoseconds is None else round(float(nanoseconds) / 1_000_000, 3)


def summarize(
    package_count: int,
    fetched: list[dict[str, object]],
    fetch_failures: list[dict[str, object]],
    results: list[dict[str, object]],
    fresh_results: list[dict[str, object]],
    crosscheck_rows: list[dict[str, object]],
    commit: str,
    test_process_wall_seconds: float,
    reused_count: int,
    pending_count: int,
    evaluator_fingerprint: str,
) -> dict[str, object]:
    statuses: dict[str, int] = {}
    reasons: dict[str, int] = {}
    reason_examples: dict[str, list[str]] = {}
    for result in results:
        status = str(result.get("status", "unknown"))
        statuses[status] = statuses.get(status, 0) + 1
        reason = result.get("reasonCode")
        if reason:
            reason_text = str(reason)
            reasons[reason_text] = reasons.get(reason_text, 0) + 1
            examples = reason_examples.setdefault(reason_text, [])
            url = str(result.get("url", ""))
            if url and len(examples) < 3:
                examples.append(url)

    successes = [row for row in results if row.get("status") == "success"]
    supported = [row for row in results if is_supported_tools_result(row)]
    supported_successes = [row for row in supported if row.get("status") == "success"]
    fresh_durations = [int(row.get("durationNanoseconds", 0)) for row in fresh_results]
    first_success_index = next(
        (index for index, row in enumerate(fresh_results) if row.get("status") == "success"),
        None,
    )
    first_success = (
        int(fresh_results[first_success_index].get("durationNanoseconds", 0))
        if first_success_index is not None
        else None
    )
    warm = [
        int(row.get("durationNanoseconds", 0))
        for row in fresh_results[(first_success_index + 1) if first_success_index is not None else 0 :]
        if row.get("status") == "success"
    ]
    timed_seconds = sum(fresh_durations) / 1_000_000_000
    return {
        "packageListCommit": commit,
        "evaluatorFingerprint": evaluator_fingerprint,
        "indexEntriesSelected": package_count,
        "manifestsFetched": len(fetched),
        "fetchFailures": len(fetch_failures),
        "manifestsWithResults": len(results),
        "manifestsMissingResults": max(0, len(fetched) - len(results)),
        "resultsReused": reused_count,
        "resultsRequestedThisRun": pending_count,
        "resultsProducedThisRun": len(fresh_results),
        "fastPathSuccesses": len(successes),
        "eligibleSupportedToolsVersions": len(supported),
        "indexCoveragePercent": round(100 * len(successes) / package_count, 3)
        if package_count
        else 0,
        "fetchedCoveragePercent": round(100 * len(successes) / len(fetched), 3)
        if fetched
        else 0,
        "supportedCoveragePercent": round(100 * len(supported_successes) / len(supported), 3)
        if supported
        else 0,
        "statuses": dict(sorted(statuses.items())),
        "fallbackReasons": dict(sorted(reasons.items(), key=lambda item: (-item[1], item[0]))),
        "fallbackExamples": reason_examples,
        "crosscheck": crosscheck_summary(crosscheck_rows, results),
        "timingMilliseconds": {
            "coldFirstAttempt": milliseconds(fresh_durations[0] if fresh_durations else None),
            "firstSuccess": milliseconds(first_success),
            "warmMean": milliseconds(statistics.fmean(warm) if warm else None),
            "warmMedian": milliseconds(statistics.median(warm) if warm else None),
            "warmP90": milliseconds(percentile(warm, 0.90)),
            "warmP99": milliseconds(percentile(warm, 0.99)),
            "successfulTotalThisRun": milliseconds(
                sum(
                    int(row.get("durationNanoseconds", 0))
                    for row in fresh_results
                    if row.get("status") == "success"
                )
            ),
        },
        "timedEvaluationSeconds": round(timed_seconds, 6),
        "testProcessWallSeconds": round(test_process_wall_seconds, 3),
        "throughputManifestsPerSecond": round(len(fresh_results) / timed_seconds, 3)
        if timed_seconds > 0
        else None,
    }


def write_failure_csv(
    path: Path,
    fetched: list[dict[str, object]],
    fetch_failures: list[dict[str, object]],
    results: list[dict[str, object]],
    crosscheck_rows: list[dict[str, object]],
) -> None:
    by_key = index_results(results)
    selected_crosschecks = {result_key(row): row for row in crosscheck_rows}
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(
            stream,
            fieldnames=(
                "url",
                "sha256",
                "status",
                "reasonCode",
                "toolsVersion",
                "crosscheck",
                "detail",
            ),
        )
        writer.writeheader()
        for row in fetch_failures:
            writer.writerow(
                {"url": row["url"], "status": "fetchFailure", "detail": row.get("fetchError", "")}
            )
        for row in crosscheck_rows:
            if error := row.get("crosscheckPreparationError"):
                writer.writerow(
                    {
                        "url": row.get("url", ""),
                        "sha256": row.get("sha256", ""),
                        "status": "crosscheckPreparationFailure",
                        "detail": error,
                    }
                )
        for manifest in fetched:
            key = result_key(manifest)
            result = by_key.get(key)
            if result is None:
                writer.writerow(
                    {
                        "url": manifest.get("url", ""),
                        "sha256": manifest.get("sha256", ""),
                        "status": "missingResult",
                        "detail": "the evaluator process did not produce a complete row",
                    }
                )
                continue
            crosscheck = str(result.get("crosscheck", ""))
            crosscheck_failed = key in selected_crosschecks and crosscheck not in ("", "success")
            crosscheck_missing = (
                key in selected_crosschecks
                and "packagePath" in selected_crosschecks[key]
                and result.get("status") == "success"
                and not crosscheck
            )
            if result.get("status") == "success" and not crosscheck_failed and not crosscheck_missing:
                continue
            writer.writerow(
                {
                    "url": result.get("url", ""),
                    "sha256": result.get("sha256", ""),
                    "status": "crosscheckMissing" if crosscheck_missing else result.get("status", "unknown"),
                    "reasonCode": result.get("reasonCode", ""),
                    "toolsVersion": result.get("toolsVersion", ""),
                    "crosscheck": crosscheck,
                    "detail": result.get("detail", ""),
                }
            )


def write_markdown(path: Path, summary: dict[str, object]) -> None:
    timing = summary["timingMilliseconds"]
    reasons = summary["fallbackReasons"]
    examples = summary["fallbackExamples"]
    crosscheck = summary["crosscheck"]
    lines = [
        "# Swift Package Index ConstExpr report",
        "",
        f"- PackageList commit: `{summary['packageListCommit']}`",
        f"- Evaluator fingerprint: `{summary['evaluatorFingerprint']}`",
        f"- Evaluator changed during run: {summary['evaluatorChangedDuringRun']}",
        f"- Selected / fetched / evaluated: {summary['indexEntriesSelected']} / {summary['manifestsFetched']} / {summary['manifestsWithResults']}",
        f"- Reused / requested / produced this run: {summary['resultsReused']} / {summary['resultsRequestedThisRun']} / {summary['resultsProducedThisRun']}",
        f"- Eligible supported-tools manifests: {summary['eligibleSupportedToolsVersions']}",
        f"- Fast-path successes: {summary['fastPathSuccesses']}",
        f"- Index / fetched / supported-tools coverage: {summary['indexCoveragePercent']}% / {summary['fetchedCoveragePercent']}% / {summary['supportedCoveragePercent']}%",
        f"- Timed evaluation / test-process wall time: {summary['timedEvaluationSeconds']} s / {summary['testProcessWallSeconds']} s",
        f"- End-to-end harness wall time: {summary['totalWallSeconds']} s",
        f"- Throughput (timed evaluator work): {summary['throughputManifestsPerSecond']} manifests/s",
        f"- First attempt / first success: {timing['coldFirstAttempt']} / {timing['firstSuccess']} ms",
        f"- Warm mean / median / p90 / p99: {timing['warmMean']} / {timing['warmMedian']} / {timing['warmP90']} / {timing['warmP99']} ms",
        "",
        "## Crosscheck",
        "",
        f"- Requested / prepared / preparation errors: {crosscheck['requested']} / {crosscheck['prepared']} / {crosscheck['preparationErrors']}",
        f"- Selection basis: {crosscheck['selectionBasis']}",
        f"- Success / mismatch / fallback / error / missing: {crosscheck['success']} / {crosscheck['mismatch']} / {crosscheck['fallback']} / {crosscheck['error']} / {crosscheck['missing']}",
        "",
        "## Fallback reasons",
        "",
        "| Reason | Count | Representative repositories |",
        "| --- | ---: | --- |",
    ]
    lines.extend(
        f"| `{reason}` | {count} | "
        + ", ".join(
            f"[{url.removesuffix('.git').rsplit('/', 1)[-1]}]({url})" for url in examples[reason]
        )
        + " |"
        for reason, count in reasons.items()
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
