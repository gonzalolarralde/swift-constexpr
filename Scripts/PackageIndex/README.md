# Swift Package Index coverage harness

This harness downloads root manifests from the canonical
[`SwiftPackageIndex/PackageList`](https://github.com/SwiftPackageIndex/PackageList),
then asks the local SwiftPM checkout to evaluate them in one test process. Network
time and test-process startup are excluded from the per-manifest measurements.

Run a small development sample:

```sh
python3 Scripts/PackageIndex/run.py \
  --swiftpm /path/to/swift-package-manager \
  --limit 100
```

Run the complete index:

```sh
python3 Scripts/PackageIndex/run.py \
  --swiftpm /path/to/swift-package-manager \
  --all \
  --configuration release
```

Use `--sample 500 --seed 42` for a reproducible random development sample.
Set `SWIFTPM_ROOT` instead of passing `--swiftpm` on every invocation if
preferred.
`--crosscheck` shallow-clones 25 deterministically chosen repositories and asks
the SwiftPM test to compare the fast path with its executing loader. Pass a
count, or `--crosscheck 0` to crosscheck every selected package.
On a resumed scan, finite crosscheck samples prefer matching cached fast-path
successes, then manifests without a result for the current evaluator, and only
then known fallback rows. First-run samples are therefore deterministic samples
of the unexplored selection. The JSON and Markdown reports count each selection
basis so clone cost and semantic evidence are visible.
The default list is reproducibly pinned to PackageList commit
`32b0256f7de1ab6385b550f21a1e10aabf923a2e`. Use
`--package-list-commit <sha>` to select a different exact revision. The selected
list commit, downloaded manifest hashes, and cloned repository commits are
recorded; downloads are cached under `.build/package-index` by default.

Runs are resumable. A cached evaluator row is reused only when its repository
URL, manifest SHA-256, and evaluator fingerprint all match. The automatic
fingerprint covers the Swift toolchain version, build configuration, both Git
HEADs, and relevant tracked and untracked source changes in SwiftPM and
swift-constexpr. This prevents an implementation edit from silently reusing
stale coverage. The harness checks the identity again after evaluation and
quarantines fresh rows instead of caching them if source changed while the test
was running. CI can supply a stable identity with
`--evaluator-fingerprint`, but is then responsible for changing it whenever
the evaluator changes. The Swift test flushes every result row, and the harness
merges complete rows even when that test process fails, so the next invocation
evaluates only the unfinished rows. Use `--rerun` to deliberately ignore
matching evaluator results. Requesting a crosscheck also reruns a previously
successful fast-path row if its cached row does not contain a crosscheck result.

The harness writes:

- `summary.json` for automation;
- `summary.md` for a human-readable coverage and timing report;
- `failures.csv` for fallback analysis;
- `corpus-selection.jsonl` for selected URLs, fetched hashes, crosscheck
  preparation failures, and cloned repository commits;
- `corpus-evaluator.json` for the source/toolchain cache identity;
- `corpus-results.jsonl` for the current selection's timings and reason codes;
- `corpus-result-cache.jsonl` for resumable results keyed by URL, SHA-256, and
  evaluator fingerprint.

Coverage is reported against the selected index entries, successfully fetched
manifests, and manifests whose tools version parsed successfully inside the
loader's supported window. Fetch and tools-version parse failures are never
included in that last denominator. Reports distinguish the first attempted
evaluation from the first fast-path success, then report warm
mean/median/p90/p99. Per-manifest timings and throughput exclude downloading,
cloning, and process startup; test-process wall time and end-to-end harness wall
time are reported separately. On a resumed run, timing statistics cover only
the newly evaluated pending batch; reused rows still contribute to coverage.
Crosscheck preparation, success, mismatch,
fallback, execution error, and missing-result counts are reported explicitly
and every non-success is included in `failures.csv`.
