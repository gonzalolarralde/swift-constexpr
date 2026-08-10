#!/usr/bin/env bash

set -euo pipefail

consumer_root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
examples_root="$(CDPATH= cd -- "$consumer_root/.." && pwd -P)"
stock_scratch="$consumer_root/.build/constexpr-stock-manifest"
stage=""

cleanup() {
    if [[ -n "$stage" ]]; then
        case "$stage" in
            "$examples_root"/.ConstExprConsumer.stage.*)
                rm -rf -- "$stage"
                ;;
        esac
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Validating the checked-in stock manifest"
swift package \
    --package-path "$consumer_root" \
    --scratch-path "$stock_scratch" \
    dump-package >/dev/null

echo "Running the complete staged rewrite/build workflow"
set +e
workflow_output="$("$consumer_root/build.sh" --keep-stage --run "$@")"
workflow_status=$?
set -e
printf '%s\n' "$workflow_output"

stage="$(printf '%s\n' "$workflow_output" | sed -n 's/^Preserved rewritten package: //p' | tail -n 1)"
case "$stage" in
    "$examples_root"/.ConstExprConsumer.stage.*) ;;
    *)
        echo "error: build.sh did not report a validated sibling stage" >&2
        exit 1
        ;;
esac
[[ -d "$stage" ]] || {
    echo "error: reported stage does not exist: $stage" >&2
    exit 1
}

if ((workflow_status != 0)); then
    echo "error: staged rewrite/build workflow failed with status $workflow_status" >&2
    exit "$workflow_status"
fi

diff -u \
    "$consumer_root/Expected/Package.rewritten.swift" \
    "$stage/Package.swift"
diff -u \
    "$consumer_root/Expected/main.rewritten.swift" \
    "$stage/Sources/ConstExprConsumer/main.swift"

runtime_output="$(printf '%s\n' "$workflow_output" | grep '^consumer=' | tail -n 1)"
diff -u \
    "$consumer_root/Expected/output.txt" \
    <(printf '%s\n' "$runtime_output")

echo "Verified staged manifest, staged source, and executable output"
