[CmdletBinding()]
param(
    [ValidateSet("v4", "v5")]
    [string]$Profile = "v5",
    [ValidateSet("healthy", "mfa-rejected", "session-expired")]
    [string]$Scenario = "healthy",
    [ValidateSet("none", "next-resource-create-500", "next-folder-create-500", "next-share-500", "expire-session")]
    [string]$Fault = "none",
    [switch]$SelfTest,
    [switch]$AcceptanceTest,
    [switch]$KeepWorkspace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = $PSScriptRoot
$SetupScript = Join-Path $ProjectRoot "offline_lab_setup.py"
$ServerScript = Join-Path $ProjectRoot "offline_lab_server.mjs"
$SmokeScript = Join-Path $ProjectRoot "offline_lab_smoke.py"
$AcceptanceScript = Join-Path $ProjectRoot "offline_lab_acceptance.py"
$AppScript = Join-Path $ProjectRoot "PassboltApp.ps1"
$WindowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$BundledRoot = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies"

function Resolve-LabExecutable {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$BundledPath
    )
    if (Test-Path -LiteralPath $BundledPath -PathType Leaf) { return $BundledPath }
    $Command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $Command) { return $Command.Source }
    return ""
}

function ConvertTo-LabProcessArgument([string]$Value) {
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $Builder = New-Object System.Text.StringBuilder
    [void]$Builder.Append('"')
    $Backslashes = 0
    foreach ($Character in $Value.ToCharArray()) {
        if ($Character -eq '\') {
            $Backslashes++
            continue
        }
        if ($Character -eq '"') {
            [void]$Builder.Append(('\' * (($Backslashes * 2) + 1)))
            [void]$Builder.Append('"')
            $Backslashes = 0
            continue
        }
        if ($Backslashes -gt 0) {
            [void]$Builder.Append(('\' * $Backslashes))
            $Backslashes = 0
        }
        [void]$Builder.Append($Character)
    }
    if ($Backslashes -gt 0) { [void]$Builder.Append(('\' * ($Backslashes * 2))) }
    [void]$Builder.Append('"')
    return $Builder.ToString()
}

$PythonExecutable = Resolve-LabExecutable `
    -Name "python" `
    -BundledPath (Join-Path $BundledRoot "python\python.exe")
$NodeExecutable = Resolve-LabExecutable `
    -Name "node" `
    -BundledPath (Join-Path $BundledRoot "node\bin\node.exe")
if ([string]::IsNullOrWhiteSpace($PythonExecutable)) {
    throw "Python 3.11 o superiore non trovato."
}
if ([string]::IsNullOrWhiteSpace($NodeExecutable)) {
    throw "Node.js 18 o superiore non trovato."
}
if ($SelfTest -and $AcceptanceTest) {
    throw "SelfTest e AcceptanceTest sono modalita' alternative."
}
if (-not $SelfTest -and -not $AcceptanceTest -and -not (Test-Path -LiteralPath $WindowsPowerShell -PathType Leaf)) {
    throw "Windows PowerShell non trovato."
}

$TempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$Workspace = Join-Path $TempRoot ("passbolt-offline-lab-" + [guid]::NewGuid().ToString("N"))
$ReadyFile = Join-Path $Workspace "ready.json"
$ServerOutput = Join-Path $Workspace "server.stdout.log"
$ServerError = Join-Path $Workspace "server.stderr.log"
$ServerProcess = $null
$Ready = $null
$PreviousSslCertificate = [Environment]::GetEnvironmentVariable("SSL_CERT_FILE")
$PreviousNodeCertificate = [Environment]::GetEnvironmentVariable("NODE_EXTRA_CA_CERTS")
$PreviousAppPython = [Environment]::GetEnvironmentVariable("PASSBOLT_APP_PYTHON")
$PreviousAppNode = [Environment]::GetEnvironmentVariable("PASSBOLT_APP_NODE")

try {
    [void][IO.Directory]::CreateDirectory($Workspace)
    $SetupOutput = & $PythonExecutable $SetupScript --workspace $Workspace 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Preparazione del laboratorio offline non riuscita."
    }
    $SetupEnvelope = (($SetupOutput | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json
    if ($null -eq $SetupEnvelope -or $SetupEnvelope.ok -ne $true) {
        throw "Il generatore del laboratorio non ha restituito un risultato valido."
    }
    $Setup = $SetupEnvelope.result

    $ServerArguments = @(
        $ServerScript,
        "--profile", $Profile,
        "--scenario", $Scenario,
        "--fault", $Fault,
        "--cert", [string]$Setup.certificate_path,
        "--key", [string]$Setup.tls_private_key_path,
        "--workspace", $Workspace,
        "--ready-file", $ReadyFile,
        "--dataset-root", [string]$Setup.dataset_root
    )
    $QuotedServerArguments = (@($ServerArguments | ForEach-Object { ConvertTo-LabProcessArgument ([string]$_) })) -join ' '
    $ServerProcess = Start-Process `
        -FilePath $NodeExecutable `
        -ArgumentList $QuotedServerArguments `
        -WorkingDirectory $ProjectRoot `
        -WindowStyle Hidden `
        -RedirectStandardOutput $ServerOutput `
        -RedirectStandardError $ServerError `
        -PassThru

    $Deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not (Test-Path -LiteralPath $ReadyFile -PathType Leaf)) {
        if ($ServerProcess.HasExited) {
            throw "Il server del laboratorio si e' chiuso durante l'avvio."
        }
        if ([DateTime]::UtcNow -ge $Deadline) {
            throw "Timeout durante l'avvio del laboratorio offline."
        }
        Start-Sleep -Milliseconds 200
    }

    $Ready = Get-Content -LiteralPath $ReadyFile -Raw | ConvertFrom-Json
    if ($null -eq $Ready -or $Ready.contains_real_credentials -ne $false -or [string]$Ready.profile -ne $Profile) {
        throw "Il laboratorio offline non ha restituito un'identita' sintetica valida."
    }
    $env:SSL_CERT_FILE = [string]$Ready.certificate_path
    $env:NODE_EXTRA_CA_CERTS = [string]$Ready.certificate_path
    $env:PASSBOLT_APP_PYTHON = $PythonExecutable
    $env:PASSBOLT_APP_NODE = $NodeExecutable

    if ($SelfTest) {
        $SmokeOutput = & $PythonExecutable $SmokeScript --ready-file $ReadyFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            $SafeSmokeText = ($SmokeOutput | ForEach-Object { [string]$_ }) -join "`n"
            throw "Smoke test del laboratorio offline non riuscito: $SafeSmokeText"
        }
        $SmokeOutput | ForEach-Object { Write-Host ([string]$_) }
    } elseif ($AcceptanceTest) {
        if ($Scenario -ne "healthy" -or $Fault -ne "none") {
            throw "AcceptanceTest richiede Scenario healthy e Fault none."
        }
        $AcceptanceOutput = & $PythonExecutable $AcceptanceScript --ready-file $ReadyFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            $SafeAcceptanceText = ($AcceptanceOutput | ForEach-Object { [string]$_ }) -join "`n"
            throw "Accettazione stateful del laboratorio offline non riuscita: $SafeAcceptanceText"
        }
        $AcceptanceOutput | ForEach-Object { Write-Host ([string]$_) }
    } else {
        Write-Host ""
        Write-Host "Laboratorio Passbolt offline pronto" -ForegroundColor Green
        Write-Host "Profilo:      $Profile"
        Write-Host "Scenario:     $Scenario"
        Write-Host "Fault:        $Fault"
        Write-Host "URL:          $($Ready.base_url)"
        Write-Host "Fingerprint:  $($Ready.server_fingerprint)"
        Write-Host "Chiave test:  $($Ready.private_key_path)"
        Write-Host "Passphrase:   $($Ready.passphrase)"
        Write-Host "MFA TOTP:     $($Ready.mfa_totp)"
        Write-Host "Documenti:    $($Ready.dataset_root)"
        Write-Host ""
        Write-Host "Tutti i valori sono sintetici, temporanei e validi soltanto per questa sessione." -ForegroundColor Yellow
        Write-Host "Chiudendo l'app il laboratorio verra' arrestato e rimosso." -ForegroundColor Yellow
        Write-Host ""
        & $WindowsPowerShell -NoProfile -STA -ExecutionPolicy Bypass -File $AppScript
        if ($LASTEXITCODE -ne 0) {
            throw "L'applicazione del laboratorio offline si e' chiusa con un errore."
        }
    }
} finally {
    [Environment]::SetEnvironmentVariable("SSL_CERT_FILE", $PreviousSslCertificate, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS", $PreviousNodeCertificate, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable("PASSBOLT_APP_PYTHON", $PreviousAppPython, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable("PASSBOLT_APP_NODE", $PreviousAppNode, [EnvironmentVariableTarget]::Process)
    if ($null -ne $Ready) {
        $Ready.passphrase = ""
        $Ready.mfa_totp = ""
        $Ready.lab_token = ""
    }
    if ($null -ne $ServerProcess) {
        try {
            if (-not $ServerProcess.HasExited) {
                Stop-Process -Id $ServerProcess.Id -Force
                [void]$ServerProcess.WaitForExit(5000)
            }
        } catch {}
        $ServerProcess.Dispose()
    }
    if (-not $KeepWorkspace -and (Test-Path -LiteralPath $Workspace -PathType Container)) {
        $ResolvedWorkspace = [IO.Path]::GetFullPath($Workspace)
        $ExpectedPrefix = $TempRoot + '\passbolt-offline-lab-'
        if (-not $ResolvedWorkspace.StartsWith($ExpectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Il workspace del laboratorio non appartiene alla directory temporanea prevista."
        }
        Remove-Item -LiteralPath $ResolvedWorkspace -Recurse -Force
    } elseif ($KeepWorkspace) {
        Write-Warning "Workspace sintetico conservato in $Workspace. Contiene una chiave OpenPGP di laboratorio."
    }
}
