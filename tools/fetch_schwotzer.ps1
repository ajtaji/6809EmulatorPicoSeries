# Fetches W. Schwotzer's "MC6809 CPU Emulation Validation" program (third-party, not part of this
# repository), assembles it with asm6809 together with Diagnostics\schwotzer_host.asm (the two
# console routines it calls), and embeds it for the board verifier and the desktop program:
#   Diagnostics\upstream\6809test.asm   the source, from hoglet67/6809Decoder at a pinned commit
#   Diagnostics\schwotzer.s19 / .lst    the assembled program and its listing (desktop suites)
#   Diagnostics\schwotzer.pmi           the program as PureMetal data (board verifier)
# All of these are ignored by git. Needs asm6809 (https://www.6809.org.uk/asm6809/) and Python 3.
#   powershell -ExecutionPolicy Bypass -File tools\fetch_schwotzer.ps1 -Asm6809 C:\tools\asm6809.exe
param([string]$Asm6809 = 'asm6809.exe')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location (Join-Path $root 'Diagnostics')
$commit = '4f7e1846375024888ad7987bd390f434897953cf'
$url = "https://raw.githubusercontent.com/hoglet67/6809Decoder/$commit/test/assembler/6809test.asm"
New-Item -ItemType Directory -Force upstream | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile upstream\6809test.asm
& $Asm6809 -S -l schwotzer.lst -o schwotzer.s19 upstream\6809test.asm schwotzer_host.asm
if ($LASTEXITCODE) { throw 'asm6809 did not assemble the program' }
Set-Location $root
& py -3 tools\embed_srec.py Diagnostics\schwotzer.s19 Diagnostics\schwotzer.pmi Schwotzer
if ($LASTEXITCODE) { throw 'embedding the program failed' }
'Schwotzer program ready: Diagnostics\schwotzer.s19, .lst and .pmi'
