#!/bin/bash
# Verification builds on the board under ONE lease for the whole batch (each run
# is an upload plus a 30 s capture). Everything is compiled first, so the lease
# is held only for the uploads and captures. Logs: build/verify-*.uf2.build.log
#   tools/verify_all.sh timed-b fast-i pure-b ...
cd "$(dirname "$0")/.."
PMF='C:\Users\ajtaj\Desktop\Github\PureBasicCode\OpenGl Work\ArduinoBasic\PureMetalForge.exe'
for w in "$@"; do
  "$PMF" --compile "$(cygpath -w "$(pwd)/Diagnostics/verify-$w.picow")" -S -o "$(cygpath -w "$(pwd)/build/verify-$w.uf2")" > build/pre.log 2>&1 \
    || { echo "[$w] compile failed: build/pre.log"; exit 1; }
done
L=/c/PMFBuild/board-leases/COM7.lease
mkdir -p /c/PMFBuild/board-leases
set -o noclobber
until echo "6809-core $(date -Iseconds) $# upload+capture jobs, about $(( $# * 50 )) s" 2>/dev/null > "$L"; do sleep 30; done
set +o noclobber
trap 'rm -f "$L"' EXIT
export LEASE_HELD=1
for w in "$@"; do
  tools/board.sh Diagnostics/verify-$w.picow build/verify-$w.uf2 30 \
    | grep -E "^(6809|API|vectors|Schwotzer v|verification|FAIL|.*<- FAIL|register|arith|indexed|call|pmfc: (BUILD|upload|read))" \
    | sed "s/^/[$w] /"
done
