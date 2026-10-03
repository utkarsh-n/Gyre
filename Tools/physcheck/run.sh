#!/bin/zsh
# Compiles the app's physics sources with the check harness and runs it on the Mac.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/gyre-physcheck"
xcrun swiftc -O -o "$OUT" Gyre/Physics/MathUtil.swift Gyre/Physics/GyroSim.swift Tools/physcheck/main.swift
"$OUT"
