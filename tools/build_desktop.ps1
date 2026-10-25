# Builds the desktop programs (PureBasic 6.41 x64, C back end) into desktop\build and runs
# the console verifier in both timing modes. Run from PowerShell:
#   powershell -ExecutionPolicy Bypass -File tools\build_desktop.ps1
# PureBasic's C-back-end compiler and the Neon Arcade Display Engine folder (trailing slash):
# parameters, or the PBCOMPILERC and NEON_ENGINE_DIR environment variables
param(
    [string]$Pb = $(if ($env:PBCOMPILERC) { $env:PBCOMPILERC } else { 'C:\Program Files\PureBasic\Compilers\pbcompilerc.exe' }),
    [string]$Engine = $(if ($env:NEON_ENGINE_DIR) { $env:NEON_ENGINE_DIR } else { '../Neon-Arcade-Dispay-Engine/' })
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$pb = $Pb
$engine = $Engine
New-Item -ItemType Directory -Force desktop\build | Out-Null
& py -3 tools\generate.py | Out-Null
foreach ($t in 1, 0) {
    & $pb /OPTIMIZER /CONSOLE /CONSTANT "CPU_TIMING=$t" /OUTPUT "desktop\build\verify_$t.exe" desktop\verify_console.pb
    if ($LASTEXITCODE) { throw "verify_console.pb (CPU_TIMING=$t) did not build" }
}
& $pb desktop\m6809.pb /OPTIMIZER /THREAD /DPIAWARE /OUTPUT desktop\build\m6809.exe /CONSTANT "GL_ENGINE_DIR$=$engine"
if ($LASTEXITCODE) { throw 'm6809.pb did not build' }
foreach ($t in 1, 0) {
    $p = Start-Process -FilePath "desktop\build\verify_$t.exe" -WorkingDirectory $root -NoNewWindow -Wait -PassThru -RedirectStandardOutput "desktop\build\verify_$t.log"
    Get-Content "desktop\build\verify_$t.log"
    if ($p.ExitCode) { throw "desktop suites FAILED (CPU_TIMING=$t): desktop\build\verify_$t.log" }
}
# the program exactly as built and tested here
New-Item -ItemType Directory -Force desktop\bin | Out-Null
Copy-Item desktop\build\m6809.exe desktop\bin\m6809.exe -Force
