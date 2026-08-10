#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./build.sh [--keep-stage] [--run] [--] [swift-build-options...]

Builds a consumer-specific ConstExpr driver, rewrites this package into an
isolated sibling directory, validates its Package.swift, and builds it. The
checked-in manifest and sources are never modified.

  --keep-stage  Preserve the rewritten sibling package and print its path.
  --run         Run the ConstExprConsumer executable after a successful build.
  --help        Show this help.
EOF
}

keep_stage=0
run_after_build=0
while (($# > 0)); do
    case "$1" in
        --keep-stage)
            keep_stage=1
            shift
            ;;
        --run)
            run_after_build=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done
build_arguments=("$@")

consumer_root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
examples_root="$(CDPATH= cd -- "$consumer_root/.." && pwd -P)"
const_expr_root="$(CDPATH= cd -- "$consumer_root/../.." && pwd -P)"
library_author_root="$examples_root/LibraryAuthor"
driver_template="$consumer_root/DriverTemplate"
driver_root="$consumer_root/.build/constexpr-driver-package"
driver_scratch="$consumer_root/.build/constexpr-driver-build"
consumer_scratch="$consumer_root/.build/constexpr-consumer-build"
dump_path="$consumer_root/.build/constexpr-package.json"

stage="$(mktemp -d "$examples_root/.ConstExprConsumer.stage.XXXXXX")"
case "$stage" in
    "$examples_root"/.ConstExprConsumer.stage.*) ;;
    *)
        echo "error: refusing unexpected staging path: $stage" >&2
        exit 1
        ;;
esac

cleanup() {
    if ((keep_stage == 0)); then
        case "$stage" in
            "$examples_root"/.ConstExprConsumer.stage.*)
                rm -rf -- "$stage"
                ;;
        esac
    else
        echo "Preserved rewritten package: $stage"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p -- "$consumer_root/.build"
case "$driver_root" in
    "$consumer_root"/.build/constexpr-driver-package) ;;
    *)
        echo "error: refusing unexpected driver path: $driver_root" >&2
        exit 1
        ;;
esac
rm -rf -- "$driver_root"
mkdir -p -- "$driver_root"
cp -R "$driver_template/." "$driver_root/"

echo "Building consumer-specific ConstExpr driver"
CONSTEXPR_ROOT="$const_expr_root" \
LIBRARY_AUTHOR_ROOT="$library_author_root" \
swift build \
    --package-path "$driver_root" \
    --scratch-path "$driver_scratch" \
    --product ConstExprConsumerDriver \
    -Xswiftc -warnings-as-errors \
    --explicit-target-dependency-import-check error

driver_bin_directory="$({
    CONSTEXPR_ROOT="$const_expr_root" \
    LIBRARY_AUTHOR_ROOT="$library_author_root" \
    swift build \
        --package-path "$driver_root" \
        --scratch-path "$driver_scratch" \
        --show-bin-path
})"
driver="$driver_bin_directory/ConstExprConsumerDriver"
if [[ ! -x "$driver" ]]; then
    echo "error: rewrite driver was not built at $driver" >&2
    exit 1
fi

rsync -a \
    --exclude '/.build/' \
    --exclude '/.swiftpm/' \
    --exclude '/.git/' \
    --exclude '/DriverTemplate/' \
    "$consumer_root/" "$stage/"

echo "Rewriting Package.swift"
"$driver" "$consumer_root/Package.swift" "$stage/Package.swift"

rewrite_roots=()
for candidate in "$consumer_root/Sources" "$consumer_root/Tests"; do
    if [[ -d "$candidate" ]]; then
        rewrite_roots+=("$candidate")
    fi
done

if ((${#rewrite_roots[@]} > 0)); then
    while IFS= read -r -d '' source; do
        relative_path="${source#"$consumer_root/"}"
        output="$stage/$relative_path"
        mkdir -p -- "$(dirname -- "$output")"
        "$driver" "$source" "$output"
    done < <(find "${rewrite_roots[@]}" -type f -name '*.swift' -print0)
fi

echo "Validating rewritten Package.swift"
swift package \
    --package-path "$stage" \
    --scratch-path "$consumer_scratch" \
    dump-package > "$dump_path"

echo "Building rewritten consumer"
if ((${#build_arguments[@]} > 0)); then
    swift build \
        --package-path "$stage" \
        --scratch-path "$consumer_scratch" \
        -Xswiftc -warnings-as-errors \
        --explicit-target-dependency-import-check error \
        "${build_arguments[@]}"
else
    swift build \
        --package-path "$stage" \
        --scratch-path "$consumer_scratch" \
        -Xswiftc -warnings-as-errors \
        --explicit-target-dependency-import-check error
fi

if ((run_after_build == 1)); then
    if ((${#build_arguments[@]} > 0)); then
        consumer_bin_directory="$(
            swift build \
                --package-path "$stage" \
                --scratch-path "$consumer_scratch" \
                --show-bin-path \
                "${build_arguments[@]}"
        )"
    else
        consumer_bin_directory="$(
            swift build \
                --package-path "$stage" \
                --scratch-path "$consumer_scratch" \
                --show-bin-path
        )"
    fi
    "$consumer_bin_directory/ConstExprConsumer"
fi

echo "Validated manifest JSON: $dump_path"
