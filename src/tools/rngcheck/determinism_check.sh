#!/usr/bin/env bash
# Builds tools/rngcheck under several distinct codegen configurations and
# confirms every one prints the same digest for the same fixed-seed draw
# sequence (see main.odin's own header for why this is the right proxy for
# cross-platform/cross-compiler RNG safety in this sandbox, which has no
# working Windows cross-link or a second real OS to test against -- see
# docs/decisions.md D27).
#
# -o:none vs -o:speed exercises the two optimisation levels this project
# actually ships (mise run dev / mise run build); -microarch:native adds
# whatever SIMD/FMA this host's own CPU supports, and an explicit
# -target-features:fma,avx2 forces it even if -microarch:native didn't
# already imply it -- the concrete mechanism (fused multiply-add rounding
# differently from separate mul+add) that could make the same source
# produce different float bits under a different compiler/platform.
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="${DR_BUILD:-build}/rngcheck"
mkdir -p "$(dirname "$BIN")"

declare -A digests
build_and_run() {
	local name="$1"; shift
	odin build tools/rngcheck "$DR_COLL" -out:"$BIN-$name" "$@" >&2
	digests[$name]=$("$BIN-$name")
	echo "$name: ${digests[$name]}"
}

build_and_run none    -o:none
build_and_run speed   -o:speed
build_and_run native  -o:speed -microarch:native
build_and_run fma     -o:speed -target-features:"fma,avx2"

first="${digests[none]}"
mismatch=0
for name in "${!digests[@]}"; do
	if [ "${digests[$name]}" != "$first" ]; then
		echo "MISMATCH: $name produced ${digests[$name]}, expected $first" >&2
		mismatch=1
	fi
done

if [ "$mismatch" -ne 0 ]; then
	echo "FAIL: sim/'s RNG is not codegen-stable -- see tools/rngcheck/main.odin" >&2
	exit 1
fi
echo "PASS: all $((${#digests[@]})) codegen configurations agree ($first)"
