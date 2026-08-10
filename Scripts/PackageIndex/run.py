#!/usr/bin/env python3
"""Measure ConstExpr manifest coverage against the Swift Package Index."""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
import sys
import time
import urllib.error
import urllib.request

from corpus_report import (
    completed_pending_results,
    index_results,
    partition_pending,
    read_json_lines,
    result_key,
    select_crosscheck_rows,
    summarize,
    write_failure_csv,
    write_json_lines,
    write_markdown,
)
from evaluator_fingerprint import evaluator_identity, read_json_object, write_json_object


PACKAGE_LIST_RAW = "https://raw.githubusercontent.com/SwiftPackageIndex/PackageList"
DEFAULT_PACKAGE_LIST_COMMIT = "32b0256f7de1ab6385b550f21a1e10aabf923a2e"
USER_AGENT = "swift-constexpr-package-index-audit/1"


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--all", action="store_true", help="scan the complete index")
    scope.add_argument("--limit", type=int, help="scan the first N entries")
    scope.add_argument("--sample", type=int, help="scan a deterministic random sample")
    parser.add_argument(
        "--swiftpm",
        type=Path,
        default=Path(os.environ["SWIFTPM_ROOT"])
        if "SWIFTPM_ROOT" in os.environ
        else None,
        help="SwiftPM checkout (or set SWIFTPM_ROOT)",
    )
    parser.add_argument("--cache", type=Path)
    parser.add_argument(
        "--package-list-commit",
        default=DEFAULT_PACKAGE_LIST_COMMIT,
        help=f"use an exact PackageList commit (default: {DEFAULT_PACKAGE_LIST_COMMIT})",
    )
    parser.add_argument("--workers", type=int, default=24)
    parser.add_argument("--refresh", action="store_true", help="redownload cached manifests")
    parser.add_argument(
        "--rerun",
        action="store_true",
        help="ignore matching cached evaluator results and evaluate the selection again",
    )
    parser.add_argument("--seed", type=int, default=0, help="sampling seed")
    parser.add_argument(
        "--crosscheck",
        nargs="?",
        const=25,
        type=int,
        metavar="COUNT",
        help="shallow-clone and execute a deterministic sample (default: 25; 0: all)",
    )
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    parser.add_argument(
        "--evaluator-fingerprint",
        help="override automatic evaluator source-state fingerprint (advanced/CI use)",
    )
    return parser.parse_args()


def command_output(command: list[str]) -> str:
    return subprocess.run(command, check=True, text=True, capture_output=True).stdout.strip()


def package_list_commit(explicit: str | None) -> str:
    return explicit or DEFAULT_PACKAGE_LIST_COMMIT


def download(url: str, attempts: int = 3) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if 400 <= error.code < 500 and error.code != 429:
                raise
            if attempt + 1 == attempts:
                raise
            time.sleep(0.25 * (2**attempt))
        except (urllib.error.URLError, TimeoutError):
            if attempt + 1 == attempts:
                raise
            time.sleep(0.25 * (2**attempt))
    raise AssertionError("unreachable")


def repository_parts(url: str) -> tuple[str, str]:
    prefix = "https://github.com/"
    if not url.startswith(prefix):
        raise ValueError("only GitHub repositories are supported")
    path = url[len(prefix) :]
    if path.endswith(".git"):
        path = path[:-4]
    components = path.split("/")
    if len(components) != 2 or not all(components):
        raise ValueError("repository URL must contain owner and name")
    return components[0], components[1]


def fetch_manifest(url: str, root: Path, refresh: bool) -> dict[str, object]:
    try:
        owner, repository = repository_parts(url)
        destination = root / "manifests" / owner / repository / "Package.swift"
        if refresh or not destination.is_file():
            source = download(
                f"https://raw.githubusercontent.com/{owner}/{repository}/HEAD/Package.swift"
            )
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary = destination.with_suffix(".swift.tmp")
            temporary.write_bytes(source)
            temporary.replace(destination)
        source = destination.read_bytes()
        return {
            "url": url,
            "manifestPath": str(destination.resolve()),
            "sha256": hashlib.sha256(source).hexdigest(),
        }
    except Exception as error:  # Corpus failures are data, not harness failures.
        return {"url": url, "fetchError": f"{type(error).__name__}: {error}"}


def prepare_crosscheck(row: dict[str, object], root: Path) -> None:
    """Attach a real package checkout to a corpus row without changing failures."""
    try:
        url = str(row["url"])
        expected_sha256 = str(row["sha256"]).lower()
        owner, repository = repository_parts(url)
        checkout = root / "repositories" / owner / repository
        if not (checkout / ".git").is_dir():
            checkout.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                ["git", "clone", "--quiet", "--depth", "1", "--", url, str(checkout)],
                check=True,
            )
        manifest = checkout / "Package.swift"
        if not manifest.is_file():
            raise RuntimeError("checkout has no root Package.swift")
        source = manifest.read_bytes()
        checkout_sha256 = hashlib.sha256(source).hexdigest()
        if checkout_sha256 != expected_sha256:
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(checkout),
                    "fetch",
                    "--quiet",
                    "--depth",
                    "1",
                    "origin",
                    "HEAD",
                ],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(checkout), "checkout", "--quiet", "--detach", "FETCH_HEAD"],
                check=True,
            )
            source = manifest.read_bytes()
            checkout_sha256 = hashlib.sha256(source).hexdigest()
        if checkout_sha256 != expected_sha256:
            raise RuntimeError(
                "crosscheck checkout does not match the fetched manifest; rerun with --refresh"
            )
        row.update(
            {
                "packagePath": str(checkout.resolve()),
                "crosscheckManifestSha256": checkout_sha256,
                "repositoryCommit": command_output(
                    ["git", "-C", str(checkout), "rev-parse", "HEAD"]
                ),
            }
        )
    except Exception as error:
        row["crosscheckPreparationError"] = f"{type(error).__name__}: {error}"


def main() -> int:
    overall_started = time.monotonic()
    options = arguments()
    repository_root = Path(__file__).resolve().parents[2]
    cache = (options.cache or repository_root / ".build" / "package-index").resolve()
    cache.mkdir(parents=True, exist_ok=True)
    if options.swiftpm is None:
        raise RuntimeError("pass --swiftpm or set SWIFTPM_ROOT to a SwiftPM checkout")
    swiftpm = options.swiftpm.resolve()
    if not (swiftpm / "Package.swift").is_file():
        raise RuntimeError(f"not a SwiftPM checkout: {swiftpm}")
    evaluator = evaluator_identity(
        repository_root,
        swiftpm,
        options.configuration,
        options.evaluator_fingerprint,
    )
    evaluator_fingerprint = str(evaluator["fingerprint"])
    write_json_object(cache / "corpus-evaluator.json", evaluator)
    evaluator_after_path = cache / "corpus-evaluator-after.json"
    evaluator_after_path.unlink(missing_ok=True)

    commit = package_list_commit(options.package_list_commit)
    package_list = json.loads(download(f"{PACKAGE_LIST_RAW}/{commit}/packages.json"))
    if not isinstance(package_list, list):
        raise RuntimeError("PackageList packages.json is not an array")
    if options.all:
        selected = package_list
    elif options.sample is not None:
        count = min(len(package_list), max(0, options.sample))
        selected = random.Random(options.seed).sample(package_list, count)
    else:
        selected = package_list[: max(0, options.limit if options.limit is not None else 100)]

    print(f"Fetching {len(selected)} manifests from PackageList {commit[:12]}…", flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, options.workers)) as pool:
        rows = list(
            pool.map(
                lambda url: fetch_manifest(str(url), cache, options.refresh),
                selected,
            )
        )
    fetched = [row for row in rows if "manifestPath" in row]
    fetch_failures = [row for row in rows if "fetchError" in row]

    selection_path = cache / "corpus-selection.jsonl"
    input_path = cache / "corpus-input.jsonl"
    output_path = cache / "corpus-results.jsonl"
    pending_output_path = cache / "corpus-pending-results.jsonl"
    pending_metadata_path = cache / "corpus-pending-run.json"
    result_cache_path = cache / "corpus-result-cache.jsonl"
    prior_path = result_cache_path if result_cache_path.is_file() else output_path
    cached_results = index_results(read_json_lines(prior_path, tolerate_invalid=True))
    # Recover synchronized rows left behind if the Python process itself was
    # terminated before it could merge the previous pending batch.
    recovered_metadata = read_json_object(pending_metadata_path)
    recovered_fingerprint = recovered_metadata.get("evaluatorFingerprint")
    recovered_rows = read_json_lines(pending_output_path, tolerate_invalid=True)
    if isinstance(recovered_fingerprint, str):
        for row in recovered_rows:
            row["evaluatorFingerprint"] = recovered_fingerprint
    cached_results.update(index_results(recovered_rows))

    crosscheck_rows: list[dict[str, object]] = []
    if options.crosscheck is not None:
        crosscheck_rows = select_crosscheck_rows(
            fetched,
            cached_results,
            evaluator_fingerprint,
            options.crosscheck,
            options.seed,
        )
        print(f"Preparing {len(crosscheck_rows)} shallow-clone crosschecks…", flush=True)
        for row in crosscheck_rows:
            prepare_crosscheck(row, cache)

    selected_crosscheck_keys = set()
    for row in crosscheck_rows:
        if "packagePath" in row and (key := result_key(row)) is not None:
            selected_crosscheck_keys.add(key)
    reusable, pending = partition_pending(
        fetched,
        cached_results,
        selected_crosscheck_keys,
        options.rerun,
        evaluator_fingerprint,
    )

    write_json_lines(selection_path, rows)
    write_json_lines(input_path, pending)
    pending_output_path.unlink(missing_ok=True)
    write_json_object(
        pending_metadata_path,
        {"evaluatorFingerprint": evaluator_fingerprint},
    )

    environment = os.environ.copy()
    environment.update(
        {
            "SWIFTPM_CONSTEXPR_CORPUS_INPUT": str(input_path),
            "SWIFTPM_CONSTEXPR_CORPUS_OUTPUT": str(pending_output_path),
            "SWIFTPM_CONSTEXPR_CORPUS_CROSSCHECK": "1"
            if options.crosscheck is not None
            else "0",
        }
    )
    command = [
        "swift",
        "test",
        "--package-path",
        str(swiftpm),
        "-c",
        options.configuration,
        "--filter",
        "ConstExprPackageIndexCorpusTests",
    ]
    return_code = 0
    test_process_wall_seconds = 0.0
    if pending:
        print(
            f"Running {len(pending)} pending manifests; reusing {len(reusable)} matching results…",
            flush=True,
        )
        evaluator_started = time.monotonic()
        try:
            completed = subprocess.run(command, env=environment)
            return_code = completed.returncode
        except KeyboardInterrupt:
            # Merge the rows the test synchronized before honoring the user's
            # interrupt; otherwise an interrupted full scan cannot resume.
            return_code = 130
        finally:
            test_process_wall_seconds = time.monotonic() - evaluator_started
    else:
        print(f"All {len(reusable)} fetched manifests have matching cached results.")

    evaluator_changed = False
    evaluator_check_error: str | None = None
    if options.evaluator_fingerprint is None:
        try:
            evaluator_after = evaluator_identity(
                repository_root,
                swiftpm,
                options.configuration,
                None,
            )
            evaluator_changed = evaluator_after["fingerprint"] != evaluator_fingerprint
        except Exception as error:
            evaluator_changed = True
            evaluator_check_error = f"{type(error).__name__}: {error}"
            evaluator_after = {"fingerprint": None, "error": evaluator_check_error}
        if evaluator_changed:
            write_json_object(evaluator_after_path, evaluator_after)
            if return_code == 0:
                return_code = 75
            print(
                "error: evaluator source state changed or could not be verified; fresh rows will not be cached",
                file=sys.stderr,
            )

    # The Swift test synchronizes each JSONL row. Even after a crash, merge all
    # complete pending rows before returning so the next invocation resumes at
    # the first manifest that did not finish.
    pending_rows = read_json_lines(pending_output_path, tolerate_invalid=True)
    if evaluator_changed:
        for row in pending_rows:
            row["invalidatedEvaluatorFingerprint"] = evaluator_fingerprint
        write_json_lines(cache / "corpus-invalidated-results.jsonl", pending_rows)
        pending_rows = []
    else:
        for row in pending_rows:
            row["evaluatorFingerprint"] = evaluator_fingerprint
    fresh_index, fresh_results = completed_pending_results(pending, pending_rows)
    cached_results.update(fresh_index)
    write_json_lines(result_cache_path, cached_results.values())
    pending_output_path.unlink(missing_ok=True)
    pending_metadata_path.unlink(missing_ok=True)

    current_results = dict(reusable)
    current_results.update(fresh_index)
    results = [current_results[key] for row in fetched if (key := result_key(row)) in current_results]
    write_json_lines(output_path, results)
    summary = summarize(
        len(selected),
        fetched,
        fetch_failures,
        results,
        fresh_results,
        crosscheck_rows,
        commit,
        test_process_wall_seconds,
        len(reusable),
        len(pending),
        evaluator_fingerprint,
    )
    summary["totalWallSeconds"] = round(time.monotonic() - overall_started, 3)
    summary["evaluatorChangedDuringRun"] = evaluator_changed
    summary["evaluatorCheckError"] = evaluator_check_error
    (cache / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    write_failure_csv(
        cache / "failures.csv",
        fetched,
        fetch_failures,
        results,
        crosscheck_rows,
    )
    write_markdown(cache / "summary.md", summary)
    print(json.dumps(summary, indent=2, sort_keys=True))
    print(f"Reports: {cache / 'summary.md'}")
    if return_code != 0:
        print(
            f"warning: evaluator exited with status {return_code}; merged {len(fresh_results)} of {len(pending)} pending rows",
            file=sys.stderr,
        )
        return return_code
    if len(results) != len(fetched):
        print(
            f"error: evaluator produced no complete result for {len(fetched) - len(results)} manifests",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
