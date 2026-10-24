#!/bin/bash
# Build, then upload to the shared Pico W on COM7 and capture its serial output,
# holding the bench lease only while the board is in use. The lease is taken and
# released from Bash: the PowerShell tool's sandbox cannot see or delete it.
#   tools/board.sh <source> <output.uf2> <seconds>
set -u
cd "$(dirname "$0")/.."
SRC="$1"; OUT="$2"; SECS="${3:-30}"
PMF='C:\Users\ajtaj\Desktop\Github\PureBasicCode\OpenGl Work\ArduinoBasic\PureMetalForge.exe'
win() { cygpath -w "$(pwd)/$1"; }
"$PMF" --compile "$(win "$SRC")" -S -o "$(win "$OUT")" > "$OUT.build.log" 2> "$OUT.stderr.log" || { echo "compile failed: $OUT.build.log"; exit 1; }
# refuse an image that reaches the NES ROM store at flash $10050000
END=$(py -3 -c "import struct,sys;d=open(sys.argv[1],'rb').read();print(max(struct.unpack_from('<I',d,o+12)[0]+struct.unpack_from('<I',d,o+16)[0] for o in range(0,len(d),512)))" "$OUT")
if [ "$END" -gt $((0x10050000)) ]; then echo "image reaches $END, past the NES ROM store: not uploaded"; exit 1; fi
L=/c/PMFBuild/board-leases/COM7.lease
if [ -z "${LEASE_HELD:-}" ]; then   # tools/verify_all.sh holds one lease for a whole batch
  mkdir -p /c/PMFBuild/board-leases
  set -o noclobber
  until echo "6809-core $(date -Iseconds) (upload+capture ${SECS}s)" 2>/dev/null > "$L"; do sleep 30; done
  set +o noclobber
  trap 'rm -f "$L"' EXIT
fi
"$PMF" --compile "$(win "$SRC")" -S -o "$(win "$OUT")" --port COM7 --seconds "$SECS" > "$OUT.build.log" 2> "$OUT.stderr.log"
rc=$?
if [ -z "${LEASE_HELD:-}" ]; then rm -f "$L"; trap - EXIT; fi
grep -v '^\[DEBUG\]\|^> \|TELEMETRY\|_RP2040' "$OUT.build.log" | tail -n +1
exit $rc
