#!/bin/zsh
# Builds KeepOne for the iOS Simulator and prints only diagnostics.
cd "$(dirname "$0")/.."
xcodebuild -project KeepOne.xcodeproj -scheme KeepOne -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "^/.*(error|warning): |\*\* BUILD" | sort -u
