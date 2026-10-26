#!/bin/zsh
# Runs KeepOne's real on-device analysis pipeline on a folder of photos/videos on this Mac.
# Useful for tuning thresholds against your own images without installing the app. Local only.
set -e
cd "$(dirname "$0")/.."
DIR=${1:?usage: scripts/run_pipeline_harness.sh <folder-with-photos-and-videos>}
OUT=build/pipeline_harness
mkdir -p $OUT
swiftc -O -swift-version 6 -parse-as-library -o $OUT/run scripts/pipeline_harness/main.swift \
  $(find KeepOne/Models KeepOne/Utilities KeepOne/Persistence KeepOne/Analysis KeepOne/Recommendations KeepOne/Personalization -name '*.swift') \
  KeepOne/PhotoLibrary/PhotoLibraryProviding.swift KeepOne/Features/Trash/TrashQueue.swift
$OUT/run "$DIR" KeepOne/Resources/Models/SemanticImageModel.mlpackage KeepOne/Resources/Semantic/category_embeddings
