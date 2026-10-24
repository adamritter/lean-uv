#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
lake build uv_http uv_echo std_http uv_test uv_machine_test
mkdir -p bin
LEANUV_PREFIX="$(lean --print-prefix)"
# Use the same libuv archive as Lake's Lean executable, not a different .so.
cc -O3 -g -std=c11 -Wall -Wextra -Werror LeanUVBench/Native.c -o bin/native_http \
  "$LEANUV_PREFIX/lib/libuv.a" -pthread -ldl -lrt
