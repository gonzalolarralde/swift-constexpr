#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 /path/to/swift-package-manager [iterations]" >&2
  exit 2
fi

SWIFTPM_ROOT="$1"
ITERATIONS="${2:-50}"
ALLOCATION_ITERATIONS="${SWIFTPM_CONSTEXPR_ALLOCATION_ITERATIONS:-10}"
SELECTOR="PackageLoadingTests.ConstExprManifestLoaderPerformanceTests/testRepresentativeManifestBenchmark"
FILTER="ConstExprManifestLoaderPerformanceTests.testRepresentativeManifestBenchmark"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="${SWIFTPM_CONSTEXPR_PROFILE_OUTPUT:-${SWIFTPM_ROOT}/.build/constexpr-profile/${TIMESTAMP}}"

if [[ ! -f "${SWIFTPM_ROOT}/Package.swift" ]]; then
  echo "error: not a SwiftPM checkout: ${SWIFTPM_ROOT}" >&2
  exit 2
fi

mkdir -p "${OUTPUT_ROOT}"

swift test \
  --package-path "${SWIFTPM_ROOT}" \
  -c release \
  --filter "${FILTER}"

BIN_PATH="$(swift build --package-path "${SWIFTPM_ROOT}" -c release --show-bin-path)"
TEST_BUNDLE="${BIN_PATH}/SwiftPMPackageTests.xctest"
if [[ ! -d "${TEST_BUNDLE}" ]]; then
  echo "error: release XCTest bundle not found: ${TEST_BUNDLE}" >&2
  exit 2
fi

record() {
  local template="$1"
  local count="$2"
  local base="$3"
  xcrun xctrace record \
    --template "${template}" \
    --output "${OUTPUT_ROOT}/${base}.trace" \
    --run-name "constexpr-release-${count}" \
    --time-limit 120s \
    --no-prompt \
    --env SWIFTPM_CONSTEXPR_BENCHMARK=1 \
    --env SWIFTPM_CONSTEXPR_BENCHMARK_ITERATIONS="${count}" \
    --env SWIFTPM_CONSTEXPR_SIGNPOSTS=1 \
    --target-stdout "${OUTPUT_ROOT}/${base}.stdout.txt" \
    --launch -- \
    "$(xcrun --find xctest)" \
    -XCTest "${SELECTOR}" \
    "${TEST_BUNDLE}"
  xcrun xctrace export \
    --input "${OUTPUT_ROOT}/${base}.trace" \
    --toc \
    --output "${OUTPUT_ROOT}/${base}-toc.xml"
}

record "Time Profiler" "${ITERATIONS}" "time-profiler"
record "Allocations" "${ALLOCATION_ITERATIONS}" "allocations"

xcrun xctrace export \
  --input "${OUTPUT_ROOT}/time-profiler.trace" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  --output "${OUTPUT_ROOT}/time-profile.xml" || true

echo "Instruments artifacts: ${OUTPUT_ROOT}"
