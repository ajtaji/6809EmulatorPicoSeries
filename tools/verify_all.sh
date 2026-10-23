#!/bin/bash
# Every verification build on the board, one lease per upload. Logs: build/verify-*.uf2.build.log
cd "$(dirname "$0")/.."
for w in "$@"; do
  tools/board.sh Diagnostics/verify-$w.picow build/verify-$w.uf2 25 | grep -E "^(6809|API|vectors|Schwotzer v|verification|FAIL|.*<- FAIL|pmfc: (BUILD|upload))" | sed "s/^/[$w] /"
done
