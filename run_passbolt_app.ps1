$ErrorActionPreference = "Stop"

$AppPath = Join-Path $PSScriptRoot "PassboltApp.ps1"
$WindowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

if (-not (Test-Path -LiteralPath $WindowsPowerShell -PathType Leaf)) {
    throw "Windows PowerShell non trovato."
}

Start-Process `
    -FilePath $WindowsPowerShell `
    -ArgumentList @("-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", "`"$AppPath`"") `
    -WorkingDirectory $PSScriptRoot `
    -WindowStyle Hidden
