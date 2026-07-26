#!/bin/bash
# One-command "get the latest code" for building in Xcode.
#
#   ./Scripts/update.sh
#
# Discards Xcode's automatic scribbles on the two tracked files it always dirties
# (project.pbxproj and Info.plist), pulls the latest main, and prints the commit
# hash the Library version stamp should show after the next build. Personal
# settings (Team ID, bundle id, API keys) live in gitignored xcconfig files and
# are never touched by this script.
set -e
cd "$(dirname "$0")/.."

git checkout -- SousChef.xcodeproj/project.pbxproj Sources/SousChef/Info.plist 2>/dev/null || true
git pull origin main

echo
echo "Now at:  $(git log --oneline -1)"
echo "After building, the Library stamp should read: $(git rev-parse --short HEAD)"
