# Compile one PureMetal program (and optionally upload it and capture the board's USB serial).
#   .\tools\build.ps1 -Source src/demo.picow -Output firmware/6809-picow.uf2
#   .\tools\build.ps1 -Source src/demo.picow -Output build/demo.uf2 -Port COM7 -Seconds 15
param(
    # PureMetal Forge's executable: -Compiler, or the PUREMETALFORGE environment variable
    [string]$Compiler = $(if ($env:PUREMETALFORGE) { $env:PUREMETALFORGE } else { 'PureMetalForge.exe' }),
    [string]$Source = 'src/demo.picow',
    [string]$Output = 'firmware/6809-picow.uf2',
    [string]$Port = '',
    [int]$Seconds = 12
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$sourcePath = [IO.Path]::GetFullPath((Join-Path $projectRoot $Source))
$outputPath = [IO.Path]::GetFullPath((Join-Path $projectRoot $Output))
[IO.Directory]::CreateDirectory((Split-Path $outputPath -Parent)) | Out-Null
$arguments = '--compile "' + $sourcePath + '" -S -o "' + $outputPath + '"'
if ($Port) { $arguments += ' --port ' + $Port + ' --seconds ' + $Seconds }
$stdoutPath = $outputPath + '.build.log'
$stderrPath = $outputPath + '.stderr.log'
$process = Start-Process -FilePath $Compiler -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
Get-Content $stdoutPath
Get-Content $stderrPath
if ($process.ExitCode -ne 0) { throw "Compiler exit $($process.ExitCode): $stdoutPath" }
