param(
    [string]$Compiler = 'C:\Users\ajtaj\Desktop\Github\PureBasicCode\OpenGl Work\ArduinoBasic\PureMetalForge.exe',
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
