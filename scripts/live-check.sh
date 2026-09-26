#!/bin/bash
# Plans real commands with the local model (Ollama must be running). Executes nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build"
swiftc -target "$(uname -m)-apple-macos14.0" -parse-as-library -swift-version 5 \
  "$ROOT"/Sources/Core/*.swift "$ROOT/tests/LivePlanner.swift" -o "$ROOT/build/live-planner"
"$ROOT/build/live-planner"
