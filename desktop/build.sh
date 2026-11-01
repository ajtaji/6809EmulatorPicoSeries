#!/bin/sh
# Builds the desktop programs on Linux (PureBasic 6.41 for Linux, C back end) into desktop/build and
# runs the console verifier in both timing modes - what tools/build_desktop.ps1 does on Windows, from
# the same sources. Run from anywhere:
#   sh desktop/build.sh
# PUREBASIC_HOME must name the PureBasic folder (its compilers/pbcompilerc is used). The Neon Arcade
# Display Engine is NEON_ENGINE_DIR, or a clone beside this repository
# (https://github.com/ajtaji/Neon-Arcade-Dispay-Engine).
# Build from a Linux disk: on a Windows drive mounted under WSL (/mnt/c) the compiler includes an
# XIncludeFile twice ("Procedure is already declared").
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
pb="${PUREBASIC_HOME:?set PUREBASIC_HOME to the PureBasic folder}/compilers/pbcompilerc"
engine="${NEON_ENGINE_DIR:-$root/../Neon-Arcade-Dispay-Engine}"
if [ ! -f "$engine/GlUI.pbi" ]; then
  echo "Neon Arcade Display Engine not found at '$engine'. Clone it beside this repository:"
  echo "  git clone https://github.com/ajtaji/Neon-Arcade-Dispay-Engine.git  (or set NEON_ENGINE_DIR)"
  exit 1
fi
# absolute, trailing slash: the program includes #GL_ENGINE_DIR$ + "GlUI.pbi"
engine="$(cd "$engine" && pwd)/"
mkdir -p desktop/build
for t in 1 0; do
  "$pb" desktop/verify_console.pb -z -cl -co "CPU_TIMING=$t" -o "desktop/build/verify_$t"
done
"$pb" desktop/m6809.pb -z -t -co "GL_ENGINE_DIR\$=$engine" -o desktop/build/m6809
fail=0
for t in 1 0; do
  desktop/build/verify_$t > "desktop/build/verify_$t.log" || fail=1
  cat "desktop/build/verify_$t.log"
done
if [ $fail -ne 0 ]; then echo "desktop suites FAILED"; exit 1; fi
