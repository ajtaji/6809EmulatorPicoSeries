# Build and run programs on the shared Pico W (COM7) under ONE bench lease,
# taken and released only through C:\PMFBuild\board-leases\lease.ps1 (the
# coordinator's rule). Everything is compiled before the lease is taken, so the
# board is held only for the uploads and captures.
#   powershell -ExecutionPolicy Bypass -File tools\board.ps1 -Programs Diagnostics/verify-timed-i.picow,src/demo.picow -Seconds 30
# Each program's log: build\<name>.uf2.build.log
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
    $name = [IO.Path]::GetFileNameWithoutExtension($p)
    $out = "build/$name.uf2"
    & $build -Source $p -Output $out | Out-Null
    # refuse an image that reaches the NES ROM store at flash $10050000
    $uf2 = [IO.File]::ReadAllBytes((Join-Path $root $out)); $imageEnd = 0
    for ($o = 0; $o -lt $uf2.Length; $o += 512) {
        $e = [BitConverter]::ToUInt32($uf2, $o + 12) + [BitConverter]::ToUInt32($uf2, $o + 16)
        if ($e -gt $imageEnd) { $imageEnd = $e }
    }
    if ($imageEnd -gt 0x10050000) { throw ('{0} reaches 0x{1:X8}, past the NES ROM store: nothing uploaded' -f $p, $imageEnd) }
    $jobs += ,@($p, $out)
}
. C:\PMFBuild\board-leases\lease.ps1
$minutes = [Math]::Ceiling($jobs.Count * ($Seconds + 25) / 60)
$lease = Get-BoardLease -Port $Port -Owner '6809-core' -Minutes $minutes
try {
    foreach ($j in $jobs) {
        try { & $build -Source $j[0] -Output $j[1] -Port $Port -Seconds $Seconds | Out-Null }
        catch { Write-Output "[$($j[0])] upload/capture failed: $_" }
    }
} finally {
    Release-BoardLease $lease
}
foreach ($j in $jobs) {
    $tag = [IO.Path]::GetFileNameWithoutExtension($j[0])
    Get-Content (Join-Path $root ($j[1] + '.build.log')) |
        Where-Object { $_ -match '^(6809|API|vectors|Schwotzer v|verification|FAIL|sum test|register|arith|indexed|call)|<- FAIL|pmfc: (BUILD|uploaded|read)' } |
        ForEach-Object { "[$tag] $_" }
}
