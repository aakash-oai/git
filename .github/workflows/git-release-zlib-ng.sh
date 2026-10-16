#!/bin/sh

# Build a private native-API library. Do not replace libz: other bundled
# dependencies, including curl, may continue using the system zlib ABI.
set -eu

if test "$#" != 1
then
	echo "usage: $0 <absolute-install-prefix>" >&2
	exit 1
fi
prefix=$1
case "$prefix" in
/*) ;;
*) echo "zlib-ng install prefix must be absolute" >&2; exit 1 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/git-release-zlib-ng.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
trap 'exit 1' HUP INT TERM

version=2.3.3
archive="$build_dir/zlib-ng.tar.gz"
curl --fail --location --retry 3 \
	"https://github.com/zlib-ng/zlib-ng/archive/refs/tags/$version.tar.gz" \
	--output "$archive"
printf '%s  %s\n' \
	f9c65aa9c852eb8255b636fd9f07ce1c406f061ec19a2e7d508b318ca0c907d1 \
	"$archive" | sha256sum --check
tar -xzf "$archive" -C "$build_dir"
source_dir="$build_dir/zlib-ng-$version"

# Upstream 80eac58d477f66132c0966938ef69520c0e7b547 initializes CPU
# dispatch before concurrent callers can race on the function table.
patch -d "$source_dir" -p1 <"$script_dir/zlib-ng-functable-constructor.patch"

cmake -S "$source_dir" -B "$build_dir/build" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$prefix" \
	-DCMAKE_INSTALL_LIBDIR=lib \
	-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
	-DZLIB_COMPAT=OFF \
	-DBUILD_SHARED_LIBS=OFF \
	-DWITH_NATIVE_INSTRUCTIONS=OFF \
	-DBUILD_TESTING=ON \
	-DWITH_GTEST=OFF
cmake --build "$build_dir/build" --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
ctest --test-dir "$build_dir/build" --output-on-failure
cmake --install "$build_dir/build"
test -f "$prefix/lib/libz-ng.a"
test -f "$prefix/include/zlib-ng.h"
