# Build, upload to the shared Pico W on COM7 and capture its serial output,
# holding the bench lease (C:\PMFBuild\board-leases\COM7.lease) only while the
# board is in use. The lease is taken exclusively: if another session holds it,
# wait and retry every 30 s.
param(
    [Parameter(Mandatory)] [string]$Source,
    [Parameter(Mandatory)] [string]$Output,
    [int]$Seconds = 30,
    [string]$Port = 'COM7',
    [string]$Session = '6809-core'
)
$ErrorActionPreference = 'Stop'
# Compile first, and refuse an image that reaches the NES ROM store at flash $10050000.
& (Join-Path $PSScriptRoot 'build.ps1') -Source $Source -Output $Output | Out-Null
$uf2 = [IO.File]::ReadAllBytes((Join-Path (Split-Path $PSScriptRoot -Parent) $Output)); $imageEnd = 0
for ($o = 0; $o -lt $uf2.Length; $o += 512) {
    $blockEnd = [BitConverter]::ToUInt32($uf2, $o + 12) + [BitConverter]::ToUInt32($uf2, $o + 16)
    if ($blockEnd -gt $imageEnd) { $imageEnd = $blockEnd }
}
if ($imageEnd -gt 0x10050000) { throw ('Image reaches 0x{0:X8}, past the NES ROM store at 0x10050000: not uploaded' -f $imageEnd) }
$leaseDir = 'C:\PMFBuild\board-leases'
$lease = Join-Path $leaseDir ($Port + '.lease')
New-Item -ItemType Directory -Force $leaseDir | Out-Null
while ($true) {
    try {
        New-Item -ItemType File -Path $lease -ErrorAction Stop | Out-Null
        Set-Content -Path $lease -Value ("$Session " + (Get-Date -Format o))
        break
    } catch {
        $held = Get-Content $lease -ErrorAction SilentlyContinue
        Write-Host "lease held: $held - waiting 30 s"
        Start-Sleep -Seconds 30
    }
}
try {
    & (Join-Path $PSScriptRoot 'build.ps1') -Source $Source -Output $Output -Port $Port -Seconds $Seconds | Out-Null
} finally {
    Remove-Item -LiteralPath $lease -Force
}
