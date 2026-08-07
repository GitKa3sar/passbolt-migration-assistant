param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedFingerprint
)

$ErrorActionPreference = "Stop"

$ScriptPath = Join-Path $PSScriptRoot "passbolt_api_probe.py"
$BundledPython = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"

if (Test-Path -LiteralPath $BundledPython) {
    $PythonExecutable = $BundledPython
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    $PythonExecutable = "py"
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $PythonExecutable = "python"
} else {
    throw "Python non trovato. Installare Python 3.11 o superiore."
}

& $PythonExecutable $ScriptPath --base-url $BaseUrl --expected-fingerprint $ExpectedFingerprint --json
exit $LASTEXITCODE
