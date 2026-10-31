#!/bin/sh
# Re-import headless and print script errors with locations (runs under the heavy lock).
cd "$(dirname "$0")/.." || exit 1
~/.agents/bin/heavy 240 godot --headless --path . --import 2>&1 | grep -A1 -E "SCRIPT ERROR|^ERROR|Parse Error" | grep -vE "^--$" | head -${1:-40}
