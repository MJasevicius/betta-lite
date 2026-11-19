#!/bin/zsh
# Builds the app for Apple silicon and Intel and zips it for a GitHub release:
#
#   tools/release.sh            -> dist/betta-lite-macos.zip

set -e
cd "$(dirname "$0")/.."
UNIVERSAL=1 INSTALL=0 ./make-app.sh
rm -f dist/betta-lite-macos.zip
ditto -c -k --keepParent "dist/Betta Lite.app" dist/betta-lite-macos.zip
ls -la dist/betta-lite-macos.zip
