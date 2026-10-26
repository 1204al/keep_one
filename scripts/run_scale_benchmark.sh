#!/bin/zsh
# Times persistence, launch load, grouping and recommendations on a synthetic library of N assets.
# Usage: scripts/run_scale_benchmark.sh [N] [dump-file]   (see scripts/scale_benchmark/main.swift)
set -e
cd "$(dirname "$0")/.."
OUT=build/scale_benchmark
mkdir -p $OUT
swiftc -O -swift-version 6 -parse-as-library -o $OUT/run scripts/scale_benchmark/main.swift \
  $(find KeepOne/Models KeepOne/Utilities KeepOne/Persistence KeepOne/Analysis KeepOne/Recommendations KeepOne/Personalization -name '*.swift') \
  KeepOne/PhotoLibrary/PhotoLibraryProviding.swift KeepOne/Features/Trash/TrashQueue.swift
$OUT/run "$@"
