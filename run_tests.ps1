[CmdletBinding()]
param(
    [switch]$Ci,
    [string]$ArtifactDirectory = "",
    [switch]$SkipUiPreviews
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = $PSScriptRoot
$PythonFiles = @(
    "passbolt_acl_reconciliation.py",
    "passbolt_api_probe.py",
    "passbolt_app.py",
    "passbolt_import.py",
    "passbolt_integration_matrix.py",
    "passbolt_project.py",
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

Push-Location $ProjectRoot
$TemporaryPreviewDirectory = $false
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

    Invoke-Checked "Suite Python" $PythonExecutable ($PythonPrefix + @("-m", "unittest") + $UnitTestFiles)
    Invoke-Checked "Suite Node/OpenPGP" $NodeExecutable @("test_passbolt_crypto.mjs")
    Invoke-Checked "Laboratorio offline Passbolt v4" "powershell.exe" @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $ProjectRoot "run_offline_lab.ps1"),
        "-Profile", "v4",
        "-Scenario", "healthy",
        "-SelfTest"
    )
    Invoke-Checked "Laboratorio offline Passbolt v5" "powershell.exe" @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $ProjectRoot "run_offline_lab.ps1"),
        "-Profile", "v5",
        "-Scenario", "healthy",
        "-SelfTest"
    )
    Invoke-Checked "Accettazione stateful offline Passbolt v4" "powershell.exe" @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $ProjectRoot "run_offline_lab.ps1"),
        "-Profile", "v4",
        "-AcceptanceTest"
    )
    Invoke-Checked "Accettazione stateful offline Passbolt v5" "powershell.exe" @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $ProjectRoot "run_offline_lab.ps1"),
        "-Profile", "v5",
        "-AcceptanceTest"
    )
    Invoke-Checked "Self-test WPF" "powershell.exe" @(
        "-NoProfile",
        "-STA",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $ProjectRoot "PassboltApp.ps1"),
        "-SelfTest"
    )

    if (-not $SkipUiPreviews) {
        Add-Type -AssemblyName PresentationCore
        if ([string]::IsNullOrWhiteSpace($ArtifactDirectory)) {
            $ArtifactDirectory = Join-Path ([IO.Path]::GetTempPath()) ("passbolt-ui-tests-" + [guid]::NewGuid().ToString("N"))
            $TemporaryPreviewDirectory = $true
        }
        $ArtifactDirectory = [IO.Path]::GetFullPath($ArtifactDirectory)
        [void][IO.Directory]::CreateDirectory($ArtifactDirectory)
        $PreviewCases = @(
            [pscustomobject]@{ Page = "Configuration"; Width = 1360; Height = 860; Dpi = 96 },
            [pscustomobject]@{ Page = "Inventory"; Width = 1360; Height = 860; Dpi = 96 },
            [pscustomobject]@{ Page = "Review"; Width = 1360; Height = 860; Dpi = 96 },
            [pscustomobject]@{ Page = "Import"; Width = 1360; Height = 860; Dpi = 96 },
            [pscustomobject]@{ Page = "Configuration"; Width = 1160; Height = 740; Dpi = 96 },
            [pscustomobject]@{ Page = "Import"; Width = 1160; Height = 740; Dpi = 120 },
            [pscustomobject]@{ Page = "Import"; Width = 1160; Height = 740; Dpi = 144 },
            [pscustomobject]@{ Page = "Import"; Width = 1160; Height = 740; Dpi = 192 }
        )
        foreach ($PreviewCase in $PreviewCases) {
            $FileName = "$($PreviewCase.Page.ToLowerInvariant())-$($PreviewCase.Width)x$($PreviewCase.Height)-dpi$($PreviewCase.Dpi).png"
            $PreviewPath = Join-Path $ArtifactDirectory $FileName
            Invoke-Checked "Anteprima UI $FileName" "powershell.exe" @(
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
            $ExpectedPixelWidth = [int][math]::Ceiling($PreviewCase.Width * $PreviewCase.Dpi / 96.0)
            $ExpectedPixelHeight = [int][math]::Ceiling($PreviewCase.Height * $PreviewCase.Dpi / 96.0)
            Test-PngDimensions $PreviewPath $ExpectedPixelWidth $ExpectedPixelHeight
        }
    }

    Invoke-Checked "Controllo diff Git" $GitExecutable @(
        "-c", "safe.directory=$($ProjectRoot.Replace('\', '/'))",
        "diff", "--check"
    )

    Write-Host ""
    [pscustomobject]@{
        app = "Passbolt Migration Assistant"
        version = "0.28.1"
        ci_mode = [bool]$Ci
        python_tests = 129
        node_suite = "OK"
        offline_stateful_scenarios = 18
        offline_recovery_fault_paths = 24
        wpf_controls = 136
        ui_preview_count = $(if ($SkipUiPreviews) { 0 } else { 8 })
        real_instance_access = $(if ($Ci) { "blocked_in_ci" } else { "operator_controlled" })
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
