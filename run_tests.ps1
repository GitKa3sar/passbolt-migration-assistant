[CmdletBinding()]
param(
    [switch]$Ci,
    [string]$ArtifactDirectory = "",
    [switch]$SkipUiPreviews
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = $PSScriptRoot
$ReleaseContractPath = Join-Path $ProjectRoot "release-candidate.json"
$PythonFiles = @(
    "passbolt_acl_reconciliation.py",
    "passbolt_api_probe.py",
    "passbolt_app.py",
    "passbolt_import.py",
    "passbolt_integration_matrix.py",
    "passbolt_project.py",
    "passbolt_receipt.py",
    "offline_lab_acceptance.py",
    "offline_lab_setup.py",
    "offline_lab_smoke.py",
    "passbolt_reconciliation.py",
    "passbolt_review.py",
    "test_passbolt_acl_reconciliation.py",
    "test_passbolt_api_probe.py",
    "test_passbolt_app.py",
    "test_passbolt_import.py",
    "test_passbolt_integration_matrix.py",
    "test_passbolt_project.py",
    "test_passbolt_receipt.py",
    "test_offline_lab.py",
    "test_passbolt_reconciliation.py",
    "test_passbolt_review.py"
)
$UnitTestFiles = @(
    "test_passbolt_api_probe.py",
    "test_passbolt_app.py",
    "test_passbolt_import.py",
    "test_passbolt_integration_matrix.py",
    "test_passbolt_project.py",
    "test_passbolt_receipt.py",
    "test_offline_lab.py",
    "test_passbolt_reconciliation.py",
    "test_passbolt_review.py",
    "test_passbolt_acl_reconciliation.py"
)

function Resolve-Executable {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$BundledPath,
        [Parameter(Mandatory = $true)][string]$EnvironmentVariable
    )

    $Override = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $ResolvedOverride = [IO.Path]::GetFullPath($Override)
        if (-not (Test-Path -LiteralPath $ResolvedOverride -PathType Leaf)) {
            throw "L'eseguibile indicato da $EnvironmentVariable non esiste: $ResolvedOverride"
        }
        return $ResolvedOverride
    }
    if (Test-Path -LiteralPath $BundledPath -PathType Leaf) {
        return $BundledPath
    }
    $Command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $Command) {
        return $Command.Source
    }
    return ""
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [AllowNull()][string]$StandardInput = $null
    )

    Write-Host ""
    Write-Host "== $Label ==" -ForegroundColor Cyan
    if (-not $PSBoundParameters.ContainsKey("StandardInput")) {
        & $FilePath @Arguments
        $ExitCode = $LASTEXITCODE
    } else {
        $Output = $StandardInput | & $FilePath @Arguments 2>&1
        $ExitCode = $LASTEXITCODE
        if ($null -ne $Output) {
            $Output | ForEach-Object { Write-Host ([string]$_) }
        }
    }
    if ($ExitCode -ne 0) {
        throw "$Label non riuscito (codice $ExitCode)."
    }
}

function Invoke-CheckedJson {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    Write-Host ""
    Write-Host "== $Label ==" -ForegroundColor Cyan
    $Output = & $FilePath @Arguments 2>&1
    $ExitCode = $LASTEXITCODE
    if ($null -ne $Output) {
        $Output | ForEach-Object { Write-Host ([string]$_) }
    }
    if ($ExitCode -ne 0) {
        throw "$Label non riuscito (codice $ExitCode)."
    }
    $Serialized = ($Output | ForEach-Object { [string]$_ }) -join "`n"
    try {
        return $Serialized | ConvertFrom-Json
    } catch {
        throw "$Label non ha restituito un riepilogo JSON valido."
    }
}

function Assert-ExactPropertyNames {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $Actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $ExpectedSorted = @($Expected | Sort-Object)
    $Difference = @(Compare-Object -ReferenceObject $ExpectedSorted -DifferenceObject $Actual)
    if ($Difference.Count -ne 0) {
        throw "$Label non rispetta lo schema chiuso previsto."
    }
}

function Read-ReleaseContract {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Manifesto del candidato non trovato: $Path"
    }
    try {
        $Contract = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        throw "Il manifesto del candidato non contiene JSON valido."
    }
    Assert-ExactPropertyNames $Contract @(
        "schema_version",
        "version",
        "changelog_state",
        "compatibility_profile",
        "quality_gate"
    ) "Il manifesto del candidato"
    Assert-ExactPropertyNames $Contract.quality_gate @(
        "python_tests",
        "offline_read_only_scenarios",
        "offline_stateful_scenarios",
        "offline_recovery_fault_paths",
        "wpf_controls",
        "import_readiness_diagnostic_cases",
        "ui_previews_required",
        "real_v4_matrix_scenarios"
    ) "Il contratto del quality gate"
    if (
        [int]$Contract.schema_version -ne 1 -or
        [string]$Contract.version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?$' -or
        [string]$Contract.changelog_state -ne "technical_beta" -or
        [string]$Contract.compatibility_profile -ne "passbolt-v4-only"
    ) {
        throw "Il manifesto del candidato non descrive una beta tecnica v4-only valida."
    }
    foreach ($Property in $Contract.quality_gate.PSObject.Properties) {
        if ([int]$Property.Value -le 0) {
            throw "Il conteggio $($Property.Name) del quality gate deve essere positivo."
        }
    }
    return $Contract
}

function Test-ReleaseIdentityBindings {
    param([Parameter(Mandatory = $true)][object]$Contract)

    $Version = [string]$Contract.version
    $IdentityBindings = @(
        [pscustomobject]@{
            Path = "PassboltApp.ps1"
            Pattern = '(?:\bv|\bapp_version\s*=\s*"|\bversion\s*(?:=|-ne)\s*")(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)'
        },
        [pscustomobject]@{ Path = "offline_lab_acceptance.py"; Pattern = 'APP_VERSION\s*=\s*"(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)"' },
        [pscustomobject]@{ Path = "offline_lab_server.mjs"; Pattern = "APP_VERSION\s*=\s*'(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)'" },
        [pscustomobject]@{ Path = "offline_lab_setup.py"; Pattern = 'APP_VERSION\s*=\s*"(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)"' },
        [pscustomobject]@{ Path = "offline_lab_smoke.py"; Pattern = 'APP_VERSION\s*=\s*"(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)"' },
        [pscustomobject]@{ Path = "passbolt_api_probe.py"; Pattern = 'Passbolt-Migration-Assistant-Probe/(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)' },
        [pscustomobject]@{ Path = "passbolt_app.py"; Pattern = 'APP_VERSION\s*=\s*"(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)"' },
        [pscustomobject]@{ Path = "passbolt_crypto.mjs"; Pattern = 'Passbolt-Migration-Assistant/(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)' },
        [pscustomobject]@{ Path = "passbolt_import.py"; Pattern = 'APP_VERSION\s*=\s*"(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)"' },
        [pscustomobject]@{ Path = "passbolt_integration_matrix.py"; Pattern = 'APP_VERSION\s*=\s*"(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)"' },
        [pscustomobject]@{ Path = "passbolt_project.py"; Pattern = 'APP_VERSION\s*=\s*"(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)"' },
        [pscustomobject]@{ Path = "passbolt_receipt.py"; Pattern = 'APP_VERSION\s*=\s*"(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)"' },
        [pscustomobject]@{ Path = "passbolt_review.py"; Pattern = 'APP_VERSION\s*=\s*"(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)"' },
        [pscustomobject]@{ Path = "test_passbolt_project.py"; Pattern = '"app_version"\s*:\s*"(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)"' }
    )
    foreach ($Binding in $IdentityBindings) {
        $Text = Get-Content -LiteralPath (Join-Path $ProjectRoot $Binding.Path) -Raw
        $Matches = @([regex]::Matches($Text, [string]$Binding.Pattern))
        if (
            $Matches.Count -eq 0 -or
            @($Matches | Where-Object { $_.Groups["version"].Value -ne $Version }).Count -ne 0
        ) {
            throw "Identita applicativa non allineata al manifesto in $($Binding.Path)."
        }
    }
    $WpfText = Get-Content -LiteralPath (Join-Path $ProjectRoot "PassboltApp.ps1") -Raw
    if (-not $WpfText.Contains("v$([regex]::Escape($Version))")) {
        throw "Il controllo del titolo WPF non coincide con il manifesto del candidato."
    }

    $Package = Get-Content -LiteralPath (Join-Path $ProjectRoot "package.json") -Raw | ConvertFrom-Json
    if ([string]$Package.version -ne $Version) {
        throw "La versione di package.json non coincide con il manifesto del candidato."
    }
    $ChangelogText = Get-Content -LiteralPath (Join-Path $ProjectRoot "CHANGELOG.md") -Raw
    $CandidateHeading = [regex]::Match(
        $ChangelogText,
        '(?m)^##\s+(\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)\s+-\s+Technical beta\s*$'
    )
    if (-not $CandidateHeading.Success -or $CandidateHeading.Groups[1].Value -ne $Version) {
        throw "La prima beta tecnica del changelog non coincide con il manifesto."
    }
}

function Get-PythonTestCount {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Prefix = @(),
        [Parameter(Mandatory = $true)][string[]]$TestFiles
    )

    $Modules = @($TestFiles | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) })
    $CounterScript = @'
import sys
import unittest

suite = unittest.defaultTestLoader.loadTestsFromNames(sys.argv[1:])
print(suite.countTestCases())
'@
    $Output = & $FilePath @($Prefix + @("-c", $CounterScript) + $Modules) 2>&1
    if ($LASTEXITCODE -ne 0) {
        $Details = ($Output | ForEach-Object { [string]$_ }) -join "`n"
        throw "Impossibile contare la suite Python: $Details"
    }
    $Serialized = (($Output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($Serialized -notmatch '^\d+$') {
        throw "Il conteggio della suite Python non e un intero valido."
    }
    return [int]$Serialized
}

function Test-PowerShellSyntax {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    Write-Host ""
    Write-Host "== Sintassi PowerShell ==" -ForegroundColor Cyan
    foreach ($RelativePath in $Paths) {
        $FullPath = Join-Path $ProjectRoot $RelativePath
        $Tokens = $null
        $Errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $FullPath,
            [ref]$Tokens,
            [ref]$Errors
        )
        if ($Errors.Count -gt 0) {
            $Details = ($Errors | ForEach-Object { $_.Message }) -join "; "
            throw "Errore di sintassi in ${RelativePath}: $Details"
        }
        Write-Host "OK  $RelativePath"
    }
}

function Test-WindowsPowerShellSourceEncoding {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    Write-Host ""
    Write-Host "== Codifica sorgenti Windows PowerShell ==" -ForegroundColor Cyan
    $StrictUtf8 = New-Object System.Text.UTF8Encoding($true, $true)
    foreach ($RelativePath in $Paths) {
        $FullPath = Join-Path $ProjectRoot $RelativePath
        $Bytes = [IO.File]::ReadAllBytes($FullPath)
        if (
            $Bytes.Length -lt 3 -or
            $Bytes[0] -ne 0xEF -or
            $Bytes[1] -ne 0xBB -or
            $Bytes[2] -ne 0xBF
        ) {
            throw "$RelativePath deve essere UTF-8 con BOM per conservare i caratteri Unicode in Windows PowerShell 5.1."
        }
        try {
            [void]$StrictUtf8.GetString($Bytes, 3, $Bytes.Length - 3)
        } catch {
            throw "$RelativePath non contiene UTF-8 valido: $($_.Exception.Message)"
        }
        Write-Host "OK  $RelativePath"
    }
}

function Test-PngDimensions {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$ExpectedWidth,
        [Parameter(Mandatory = $true)][int]$ExpectedHeight
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Anteprima UI non creata: $Path"
    }
    $File = Get-Item -LiteralPath $Path
    if ($File.Length -lt 1024) {
        throw "Anteprima UI non valida o vuota: $Path"
    }
    $Stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $Decoder = [System.Windows.Media.Imaging.PngBitmapDecoder]::new(
            $Stream,
            [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        )
        $Frame = $Decoder.Frames[0]
        if ($Frame.PixelWidth -ne $ExpectedWidth -or $Frame.PixelHeight -ne $ExpectedHeight) {
            throw "Dimensioni PNG inattese per ${Path}: $($Frame.PixelWidth)x$($Frame.PixelHeight), attese ${ExpectedWidth}x${ExpectedHeight}."
        }
    } finally {
        $Stream.Dispose()
    }
}

$ReleaseContract = Read-ReleaseContract $ReleaseContractPath
Test-ReleaseIdentityBindings $ReleaseContract

Push-Location $ProjectRoot
$TemporaryPreviewDirectory = $false
$UiPreviewCount = 0
$PreviousAppPython = [Environment]::GetEnvironmentVariable("PASSBOLT_APP_PYTHON")
$PreviousAppNode = [Environment]::GetEnvironmentVariable("PASSBOLT_APP_NODE")
try {
    $BundledRoot = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies"
    $PythonExecutable = Resolve-Executable `
        -Name "python" `
        -BundledPath (Join-Path $BundledRoot "python\python.exe") `
        -EnvironmentVariable "PASSBOLT_TEST_PYTHON"
    $PythonPrefix = @()
    if ([string]::IsNullOrWhiteSpace($PythonExecutable)) {
        $PyLauncher = Get-Command "py" -ErrorAction SilentlyContinue
        if ($null -eq $PyLauncher) {
            throw "Python 3.11 o superiore non trovato."
        }
        $PythonExecutable = $PyLauncher.Source
        $PythonPrefix = @("-3")
    }
    $NodeExecutable = Resolve-Executable `
        -Name "node" `
        -BundledPath (Join-Path $BundledRoot "node\bin\node.exe") `
        -EnvironmentVariable "PASSBOLT_TEST_NODE"
    if ([string]::IsNullOrWhiteSpace($NodeExecutable)) {
        throw "Node.js 18 o superiore non trovato."
    }
    $GitExecutable = Resolve-Executable `
        -Name "git" `
        -BundledPath (Join-Path $BundledRoot "native\git\cmd\git.exe") `
        -EnvironmentVariable "PASSBOLT_TEST_GIT"
    if ([string]::IsNullOrWhiteSpace($GitExecutable)) {
        throw "Git non trovato: e necessario per il controllo del diff."
    }

    if ($PythonPrefix.Count -eq 0) {
        $env:PASSBOLT_APP_PYTHON = $PythonExecutable
    }
    $env:PASSBOLT_APP_NODE = $NodeExecutable

    if ($Ci) {
        $env:PASSBOLT_MIGRATION_CI = "1"
    }
    $env:PYTHONDONTWRITEBYTECODE = "1"
    $env:PYTHONUTF8 = "1"

    Test-WindowsPowerShellSourceEncoding @(
        "PassboltApp.ps1"
    )
    Test-PowerShellSyntax @(
        "PassboltApp.ps1",
        "run_passbolt_app.ps1",
        "run_passbolt_probe.ps1",
        "run_passbolt_integration_matrix.ps1",
        "run_offline_lab.ps1",
        "run_tests.ps1"
    )
    Invoke-Checked "Sintassi Python" $PythonExecutable ($PythonPrefix + @("-m", "py_compile") + $PythonFiles)
    Invoke-Checked "Sintassi bridge OpenPGP" $NodeExecutable @("--check", "passbolt_crypto.mjs")
    Invoke-Checked "Sintassi test OpenPGP" $NodeExecutable @("--check", "test_passbolt_crypto.mjs")
    Invoke-Checked "Sintassi server laboratorio offline" $NodeExecutable @("--check", "offline_lab_server.mjs")

    Invoke-Checked "Self-test inventario" $PythonExecutable ($PythonPrefix + @("passbolt_app.py", "--self-test"))
    Invoke-Checked "Self-test revisione" $PythonExecutable ($PythonPrefix + @("passbolt_review.py", "--self-test"))
    Invoke-Checked "Self-test importazione" $PythonExecutable ($PythonPrefix + @("passbolt_import.py", "--self-test"))
    Invoke-Checked "Self-test matrice integrazione" $PythonExecutable ($PythonPrefix + @("passbolt_integration_matrix.py", "self-test"))
    Invoke-Checked "Self-test progetti locali" $PythonExecutable ($PythonPrefix + @("passbolt_project.py", "--self-test"))
    Invoke-Checked "Self-test bridge OpenPGP" $NodeExecutable @("passbolt_crypto.mjs") '{"command":"self-test"}'
    Invoke-Checked "Self-test server laboratorio offline" $NodeExecutable @("offline_lab_server.mjs", "--self-test")

    $PythonTestCount = Get-PythonTestCount $PythonExecutable $PythonPrefix $UnitTestFiles
    if ($PythonTestCount -ne [int]$ReleaseContract.quality_gate.python_tests) {
        throw "La suite Python contiene $PythonTestCount test, ma il manifesto ne dichiara $($ReleaseContract.quality_gate.python_tests)."
    }
    Invoke-Checked "Suite Python" $PythonExecutable ($PythonPrefix + @("-m", "unittest") + $UnitTestFiles)
    Invoke-Checked "Suite Node/OpenPGP" $NodeExecutable @("test_passbolt_crypto.mjs")
    $OfflineLabEnvelope = Invoke-CheckedJson "Laboratorio offline Passbolt v4" "powershell.exe" @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $ProjectRoot "run_offline_lab.ps1"),
        "-Profile", "v4",
        "-Scenario", "healthy",
        "-SelfTest"
    )
    if (
        $OfflineLabEnvelope.ok -ne $true -or
        [string]$OfflineLabEnvelope.result.version -ne [string]$ReleaseContract.version -or
        [string]$OfflineLabEnvelope.result.profile -ne "v4" -or
        [int]$OfflineLabEnvelope.result.automated_scenarios_passed -ne [int]$ReleaseContract.quality_gate.offline_read_only_scenarios -or
        [int]$OfflineLabEnvelope.result.manual_write_scenarios_executed -ne 0 -or
        $OfflineLabEnvelope.result.contains_real_credentials -ne $false
    ) {
        throw "Il laboratorio read-only non coincide con il contratto del candidato."
    }
    $OfflineAcceptanceEnvelope = Invoke-CheckedJson "Accettazione stateful offline Passbolt v4" "powershell.exe" @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $ProjectRoot "run_offline_lab.ps1"),
        "-Profile", "v4",
        "-AcceptanceTest"
    )
    if (
        $OfflineAcceptanceEnvelope.ok -ne $true -or
        [string]$OfflineAcceptanceEnvelope.result.version -ne [string]$ReleaseContract.version -or
        [string]$OfflineAcceptanceEnvelope.result.profile -ne "v4" -or
        [int]$OfflineAcceptanceEnvelope.result.scenario_count -ne [int]$ReleaseContract.quality_gate.offline_stateful_scenarios -or
        [int]$OfflineAcceptanceEnvelope.result.passed_count -ne [int]$ReleaseContract.quality_gate.offline_stateful_scenarios -or
        [int]$OfflineAcceptanceEnvelope.result.recovery_fault_path_count -ne [int]$ReleaseContract.quality_gate.offline_recovery_fault_paths -or
        $OfflineAcceptanceEnvelope.result.contains_real_credentials -ne $false
    ) {
        throw "L'accettazione stateful non coincide con il contratto del candidato."
    }
    $WpfSummary = Invoke-CheckedJson "Self-test WPF" "powershell.exe" @(
        "-NoProfile",
        "-STA",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $ProjectRoot "PassboltApp.ps1"),
        "-SelfTest"
    )
    if (
        [string]$WpfSummary.version -ne [string]$ReleaseContract.version -or
        [int]$WpfSummary.controls -ne [int]$ReleaseContract.quality_gate.wpf_controls -or
        [int]$WpfSummary.import_readiness_diagnostic_cases -ne [int]$ReleaseContract.quality_gate.import_readiness_diagnostic_cases -or
        [string]$WpfSummary.import_readiness_diagnostics -ne "OK" -or
        [string]$WpfSummary.single_operational_state -ne "OK" -or
        [string]$WpfSummary.operation_reentrancy_guard -ne "OK" -or
        [string]$WpfSummary.centralized_interaction_lock -ne "OK" -or
        [string]$WpfSummary.asynchronous_worker_lifecycle -ne "OK" -or
        [string]$WpfSummary.sanitized_source_feedback -ne "OK" -or
        [string]$WpfSummary.sanitized_migration_receipts -ne "OK" -or
        $WpfSummary.secrets_serialized -ne $false
    ) {
        throw "Il self-test WPF non coincide con il contratto del candidato."
    }

    if (-not $SkipUiPreviews) {
        Add-Type -AssemblyName PresentationCore
        if ([string]::IsNullOrWhiteSpace($ArtifactDirectory)) {
            $ArtifactDirectory = Join-Path ([IO.Path]::GetTempPath()) ("passbolt-ui-tests-" + [guid]::NewGuid().ToString("N"))
            $TemporaryPreviewDirectory = $true
        }
        $ArtifactDirectory = [IO.Path]::GetFullPath($ArtifactDirectory)
        [void][IO.Directory]::CreateDirectory($ArtifactDirectory)
        $PreviewCases = New-Object System.Collections.Generic.List[object]
        @(
            [pscustomobject]@{ Page = "Configuration"; Width = 1360; Height = 860; Dpi = 96 },
            [pscustomobject]@{ Page = "Inventory"; Width = 1360; Height = 860; Dpi = 96 },
            [pscustomobject]@{ Page = "Review"; Width = 1360; Height = 860; Dpi = 96 },
            [pscustomobject]@{ Page = "Import"; Width = 1360; Height = 860; Dpi = 96 },
            [pscustomobject]@{ Page = "Configuration"; Width = 1160; Height = 740; Dpi = 96 }
        ) | ForEach-Object { [void]$PreviewCases.Add($_) }
        foreach ($Dpi in @(96, 120, 144, 192)) {
            foreach ($ImportWorkspace in @("new_import", "recovery", "existing_acl")) {
                foreach ($ImportState in @("initial", "populated")) {
                    [void]$PreviewCases.Add([pscustomobject]@{
                        Page = "Import"
                        Width = 1160
                        Height = 740
                        Dpi = $Dpi
                        ImportWorkspace = $ImportWorkspace
                        ImportState = $ImportState
                    })
                }
            }
        }
        foreach ($PreviewCase in $PreviewCases) {
            $ImportSuffix = if ($PreviewCase.PSObject.Properties.Name -contains "ImportWorkspace") { "-$($PreviewCase.ImportWorkspace)-$($PreviewCase.ImportState)" } else { "" }
            $FileName = "$($PreviewCase.Page.ToLowerInvariant())$ImportSuffix-$($PreviewCase.Width)x$($PreviewCase.Height)-dpi$($PreviewCase.Dpi).png"
            $PreviewPath = Join-Path $ArtifactDirectory $FileName
            $PreviewArguments = @(
                "-NoProfile",
                "-STA",
                "-ExecutionPolicy", "Bypass",
                "-File", (Join-Path $ProjectRoot "PassboltApp.ps1"),
                "-RenderPreviewPath", $PreviewPath,
                "-RenderPreviewPage", $PreviewCase.Page,
                "-RenderPreviewWidth", ([string]$PreviewCase.Width),
                "-RenderPreviewHeight", ([string]$PreviewCase.Height),
                "-RenderPreviewDpi", ([string]$PreviewCase.Dpi)
            )
            if ($PreviewCase.PSObject.Properties.Name -contains "ImportWorkspace") {
                $PreviewArguments += @(
                    "-RenderPreviewImportTab", [string]$PreviewCase.ImportWorkspace,
                    "-RenderPreviewImportState", [string]$PreviewCase.ImportState
                )
            }
            Invoke-Checked "Anteprima UI $FileName" "powershell.exe" $PreviewArguments
            $ExpectedPixelWidth = [int][math]::Ceiling($PreviewCase.Width * $PreviewCase.Dpi / 96.0)
            $ExpectedPixelHeight = [int][math]::Ceiling($PreviewCase.Height * $PreviewCase.Dpi / 96.0)
            Test-PngDimensions $PreviewPath $ExpectedPixelWidth $ExpectedPixelHeight
            $UiPreviewCount++
        }
        if ($UiPreviewCount -ne [int]$ReleaseContract.quality_gate.ui_previews_required) {
            throw "Sono state generate $UiPreviewCount anteprime, ma il manifesto ne richiede $($ReleaseContract.quality_gate.ui_previews_required)."
        }
    }

    Invoke-Checked "Controllo diff Git" $GitExecutable @(
        "-c", "safe.directory=$($ProjectRoot.Replace('\', '/'))",
        "diff", "--check"
    )

    Write-Host ""
    [pscustomobject]@{
        app = "Passbolt Migration Assistant"
        version = [string]$ReleaseContract.version
        changelog_state = [string]$ReleaseContract.changelog_state
        ci_mode = [bool]$Ci
        python_tests = $PythonTestCount
        node_suite = "OK"
        compatibility_profile = [string]$ReleaseContract.compatibility_profile
        v5_format_and_server_rejection = "OK"
        offline_read_only_scenarios = [int]$OfflineLabEnvelope.result.automated_scenarios_passed
        offline_stateful_scenarios = [int]$OfflineAcceptanceEnvelope.result.scenario_count
        offline_recovery_fault_paths = [int]$OfflineAcceptanceEnvelope.result.recovery_fault_path_count
        wpf_controls = [int]$WpfSummary.controls
        import_readiness_diagnostic_cases = [int]$WpfSummary.import_readiness_diagnostic_cases
        ui_preview_count = $UiPreviewCount
        real_instance_access = $(if ($Ci) { "blocked_in_ci" } else { "operator_controlled" })
        offline_gate = $(if ($SkipUiPreviews) { "partial_ui_previews_skipped" } else { "passed" })
        ui_previews_required = [int]$ReleaseContract.quality_gate.ui_previews_required
        real_v4_matrix_scenarios = [int]$ReleaseContract.quality_gate.real_v4_matrix_scenarios
        real_v4_matrix_gate = "not_attested_by_offline_gate"
        release_authorized = $false
        secrets_serialized = $false
        status = "OK"
    } | ConvertTo-Json
} finally {
    [Environment]::SetEnvironmentVariable("PASSBOLT_APP_PYTHON", $PreviousAppPython, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable("PASSBOLT_APP_NODE", $PreviousAppNode, [EnvironmentVariableTarget]::Process)
    Pop-Location
    if ($TemporaryPreviewDirectory -and -not [string]::IsNullOrWhiteSpace($ArtifactDirectory) -and (Test-Path -LiteralPath $ArtifactDirectory -PathType Container)) {
        $ResolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $ResolvedArtifactDirectory = [IO.Path]::GetFullPath($ArtifactDirectory)
        if (-not $ResolvedArtifactDirectory.StartsWith($ResolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "La cartella temporanea delle anteprime non appartiene alla directory temporanea prevista."
        }
        Remove-Item -LiteralPath $ArtifactDirectory -Recurse -Force
    }
}
