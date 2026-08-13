param(
    [ValidateSet("Validate", "Run", "Record", "Summary")]
    [string]$Action = "Validate",
    [string]$Config = (Join-Path $PSScriptRoot "integration-matrix.local.json"),
    [string]$Instance,
    [string]$Report,
    [string]$Scenario,
    [ValidateSet("passed", "failed", "blocked")]
    [string]$Status,
    [string]$ErrorCode,
    [switch]$RequireComplete
)

$ErrorActionPreference = "Stop"
$ScriptPath = Join-Path $PSScriptRoot "passbolt_integration_matrix.py"
$BundledPython = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"

if (Test-Path -LiteralPath $BundledPython -PathType Leaf) {
    $PythonExecutable = $BundledPython
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    $PythonExecutable = "py"
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $PythonExecutable = "python"
} else {
    throw "Python non trovato. Installare Python 3.11 o superiore."
}

$Arguments = [System.Collections.Generic.List[string]]::new()
$Arguments.Add($ScriptPath)
switch ($Action) {
    "Validate" {
        $Arguments.Add("validate")
        $Arguments.Add("--config")
        $Arguments.Add($Config)
    }
    "Run" {
        if ([string]::IsNullOrWhiteSpace($Instance)) { throw "Indicare -Instance per eseguire la matrice." }
        $Arguments.Add("run")
        $Arguments.Add("--config")
        $Arguments.Add($Config)
        $Arguments.Add("--instance")
        $Arguments.Add($Instance)
    }
    "Record" {
        if ([string]::IsNullOrWhiteSpace($Report) -or [string]::IsNullOrWhiteSpace($Scenario) -or [string]::IsNullOrWhiteSpace($Status)) {
            throw "Indicare -Report, -Scenario e -Status per registrare un'attestazione."
        }
        $Arguments.Add("record")
        $Arguments.Add("--report")
        $Arguments.Add($Report)
        $Arguments.Add("--scenario")
        $Arguments.Add($Scenario)
        $Arguments.Add("--status")
        $Arguments.Add($Status)
        if (-not [string]::IsNullOrWhiteSpace($ErrorCode)) {
            $Arguments.Add("--error-code")
            $Arguments.Add($ErrorCode)
        }
    }
    "Summary" {
        if ([string]::IsNullOrWhiteSpace($Report)) { throw "Indicare -Report per il riepilogo." }
        $Arguments.Add("summary")
        $Arguments.Add("--report")
        $Arguments.Add($Report)
        if ($RequireComplete) { $Arguments.Add("--require-complete") }
    }
}

& $PythonExecutable @Arguments
exit $LASTEXITCODE
