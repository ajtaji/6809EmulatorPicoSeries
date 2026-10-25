# Build programs, then upload each to a Pico on -Port and capture its USB serial output.
# Everything is compiled first, so a shared board (see BOARD_LEASE_SCRIPT below) is held only
# for the uploads and captures. Each program's log: build\<name>.uf2.build.log
#   powershell -ExecutionPolicy Bypass -File tools\board.ps1 -Programs Diagnostics/verify-timed-b.picow,src/demo.picow -Port COM7 -Seconds 30
param(
    [Parameter(Mandatory)] [string[]]$Programs,
    [int]$Seconds = 30,
    [string]$Port = 'COM7'
)
$ErrorActionPreference = 'Stop'
# powershell -File hands a comma list over as one string
$Programs = @($Programs | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$root = Split-Path $PSScriptRoot -Parent
$build = Join-Path $PSScriptRoot 'build.ps1'
$jobs = @()
foreach ($p in $Programs) {
    # the extension stays in the name: verify-timed-b.picow and .pico2w must not share an output
    $name = [IO.Path]::GetFileName($p).Replace('.', '-')
    $out = "build/$name.uf2"
    & $build -Source $p -Output $out | Out-Null
    # every image here stays below flash offset $50000, leaving the rest of the flash to
    # whatever else lives on the board (a game store, saved disks)
    $uf2 = [IO.File]::ReadAllBytes((Join-Path $root $out)); $imageEnd = 0
    for ($o = 0; $o -lt $uf2.Length; $o += 512) {
        $e = [BitConverter]::ToUInt32($uf2, $o + 12) + [BitConverter]::ToUInt32($uf2, $o + 16)
        if ($e -gt $imageEnd) { $imageEnd = $e }
    }
    if ($imageEnd -gt 0x10050000) { throw ('{0} reaches 0x{1:X8}, past flash offset $50000: nothing uploaded' -f $p, $imageEnd) }
    $jobs += ,@($p, $out)
}
# On a bench where several people share boards, $env:BOARD_LEASE_SCRIPT names a script that
# provides Get-BoardLease / Release-BoardLease; without it the board is simply used.
$lease = $null
if ($env:BOARD_LEASE_SCRIPT -and (Test-Path $env:BOARD_LEASE_SCRIPT)) {
    . $env:BOARD_LEASE_SCRIPT
    $minutes = [Math]::Ceiling($jobs.Count * ($Seconds + 25) / 60)
    $lease = Get-BoardLease -Port $Port -Owner '6809-core' -Minutes $minutes
}
try {
    foreach ($j in $jobs) {
        try { & $build -Source $j[0] -Output $j[1] -Port $Port -Seconds $Seconds | Out-Null }
        catch { Write-Output "[$($j[0])] upload/capture failed: $_" }
    }
} finally {
    if ($lease) { Release-BoardLease $lease }
}
foreach ($j in $jobs) {
    $tag = [IO.Path]::GetFileName($j[0])
    Get-Content (Join-Path $root ($j[1] + '.build.log')) |
        Where-Object { $_ -match '^(6809|API|vectors|Schwotzer v|verification|FAIL|sum test|register|arith|indexed|call)|<- FAIL|pmfc: (BUILD|uploaded|read)' } |
        ForEach-Object { "[$tag] $_" }
}
