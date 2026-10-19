#!/bin/sh
# Generates Murmur.xcodeproj from project.yml and opens it in Xcode.
#
# Uses XcodeGen if it's installed, otherwise downloads it into ios/.tools — no Homebrew,
# no password. Run it again any time you change Config.xcconfig or pull new code.
set -eu
cd "$(dirname "$0")"

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen=xcodegen
else
    xcodegen=.tools/xcodegen/bin/xcodegen
    if [ ! -x "$xcodegen" ]; then
        echo "Downloading XcodeGen…"
        mkdir -p .tools
        curl -fsSL https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip \
            -o .tools/xcodegen.zip
        unzip -q -o .tools/xcodegen.zip -d .tools
        rm .tools/xcodegen.zip
    fi
fi

"$xcodegen" generate --quiet
echo "Generated Murmur.xcodeproj"

if [ "${1:-}" != "--no-open" ]; then
    open Murmur.xcodeproj
fi
