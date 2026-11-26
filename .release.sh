#!/usr/bin/env bash

# grel release hook
# https://github.com/unamatasanatarai/gemini-dev-tools/blob/master/ggrel

if [[ -f "./scripts/config.sh" ]]; then
    # shellcheck source=./scripts/config.sh
    source "./scripts/config.sh"
fi

APP_NAME="${APP_NAME:-ClassicCommander}"
TEST_CMD="./scripts/test.sh"
BUILD_CMD="set -euo pipefail
./scripts/build_dmg.sh
built=\"\$(/usr/libexec/PlistBuddy -c \"Print :CFBundleShortVersionString\" \"build/${APP_NAME}.app/Contents/Info.plist\")\"
[[ \"\$built\" == \"\${version}\" ]] || { printf 'Error: Built app reports version %s, expected %s\n' \"\$built\" \"\${version}\" >&2; exit 1; }
if ! git diff --quiet -- BUILD_NUMBER; then
    git add -- BUILD_NUMBER && git commit --amend --no-edit
fi"
RELEASE_ASSETS=("build/${APP_NAME}-\${version}.dmg")
