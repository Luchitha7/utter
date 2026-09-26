#!/bin/bash
# Builds and runs the core tests using only the Command Line Tools.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build"
swiftc -target "$(uname -m)-apple-macos14.0" -parse-as-library -swift-version 5 \
  "$ROOT"/Sources/Core/*.swift "$ROOT/tests/CoreTests.swift" -o "$ROOT/build/core-tests"
"$ROOT/build/core-tests"
