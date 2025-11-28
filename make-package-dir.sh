#!/bin/sh

set -eu

package="$1"
nvim="${2:-}"

log_error() {
    printf "%b[ERROR]%b: %s" "\e[0;31m" "\e[0m" "$1" >&2
    exit 1
}

cleanup() {
    [ -d "$package" ] && rmdir "${package:?}"
}

[ -z "$package" ] && log_error "No argument provided"

build_file="${package:?}/${package:?}.build"

mkdir "${package:?}"
cp ../../blank.build "$build_file"
sed s/package_name=\"/package_name=\""$package"/ "$build_file" > "$build_file".tmp
mv "$build_file".tmp "$build_file"

[ -z "$nvim" ] && echo "Task completed successfully."
[ -n "$nvim" ] && nvim "${package:?}/${package:?}.build"
