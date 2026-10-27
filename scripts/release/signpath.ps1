# Tauri's documented signCommand pauses packaging at each first-party binary.
# Ordinary GitHub upload-artifact / SignPath steps perform the network calls.
# This hook never receives the SignPath API token or the updater private key.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Start','Worker','Hook','Wait','Complete','Finish','TestRejection','Smoke','Cleanup')][string]$Operation,
    [ValidateSet('app','uninstaller','installer')][string]$Role,
    [string]$File,
    [string]$State = $env:ZEPHIUM_SIGNPATH_STATE
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Atomic([string]$Path, [string]$Value) {
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, $Value)
    Move-Item -LiteralPath $temp -Destination $Path
}
function Read-Json([string]$Path) { Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json }
function Assert-Metadata([string]$Path) {
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    if ($info.ProductName -cne 'Zephium' -or $info.ProductVersion -cne $config.version) {
        throw "Unexpected product metadata on ${Path}: $($info.ProductName) / $($info.ProductVersion)"
    }
}
function Assert-Signature([string]$Path) {
    Assert-Metadata $Path
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if (!$signature.SignerCertificate -or $signature.SignerCertificate.Thumbprint -ne $config.thumbprint) {
        throw "Unexpected or missing signing certificate on $Path"
    }
    if ($config.policy -eq 'test-signing') {
        # Trust ONLY the pinned public test certificate, ONLY in this disposable
        # GitHub-hosted runner. Cleanup removes it; never do this on user PCs.
        $certPath = "Cert:\CurrentUser\Root\$($config.thumbprint)"
        if (!(Test-Path $certPath)) {
            if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
                throw 'Test certificate trust is restricted to disposable GitHub-hosted runners'
            }
            $store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'CurrentUser')
            try {
                $store.Open('ReadWrite')
                $store.Add($signature.SignerCertificate)
                [IO.File]::WriteAllText((Join-Path $State 'test-trust-added'), $config.thumbprint)
            } finally { $store.Close() }
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $Path
    }
    if ($signature.Status -ne 'Valid') { throw "Invalid signature on ${Path}: $($signature.Status)" }
    if ($config.policy -eq 'release-signing' -and !$signature.TimeStamperCertificate) {
        throw "Production signature has no timestamp: $Path"
    }
}
function Wait-File([string]$Path, [int]$Seconds = 600) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while (!(Test-Path -LiteralPath $Path)) {
        if (Test-Path "$State/failed.txt") { throw (Get-Content -Raw "$State/failed.txt") }
        if (Test-Path "$State/cancelled") { throw 'Signing session cancelled' }
        if (Test-Path "$State/worker-exit.json") { throw 'Bundler exited before the requested signing stage' }
        if ([DateTime]::UtcNow -gt $deadline) { throw "Timed out waiting for $Path" }
        Start-Sleep -Seconds 2
    }
}

if ($Operation -eq 'Start') {
    if ($env:GITHUB_REPOSITORY -ne 'zephium-browser/Zephium' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
        throw 'Signing requires the official repository and a GitHub-hosted runner'
    }
    if ($env:SIGNPATH_POLICY -notin @('test-signing','release-signing')) { throw 'Invalid signing policy' }
    if ($env:SIGNPATH_CERT_THUMBPRINT -notmatch '^[A-Fa-f0-9]{40}$') { throw 'A pinned signing certificate thumbprint is required' }
    if ($env:VERSION -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'Invalid application version' }
    $State = Join-Path $env:RUNNER_TEMP ('zephium-signpath-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $State | Out-Null
    $root = (Resolve-Path "$PSScriptRoot/../..").Path
    $config = @{
        workspace = $root; version = $env:VERSION; policy = $env:SIGNPATH_POLICY
        thumbprint = $env:SIGNPATH_CERT_THUMBPRINT.ToUpperInvariant()
    }
    $config | ConvertTo-Json | Set-Content "$State/config.json"
    $hook = @{
        bundle = @{
            createUpdaterArtifacts = $false
            resources = @{ '../target/THIRD_PARTY_NOTICES.txt' = 'licenses/THIRD_PARTY_NOTICES.txt' }
            windows = @{ signCommand = @{
                cmd = (Get-Command pwsh).Source
                args = @('-NoProfile','-NonInteractive','-File', $PSCommandPath, '-Operation','Hook','-State',$State,'-File','%1')
            } }
        }
    }
    $hook | ConvertTo-Json -Depth 8 | Set-Content "$State/bundle.json"
    "ZEPHIUM_SIGNPATH_STATE=$State" >> $env:GITHUB_ENV
    # Start-Process on Windows detaches; the runner still owns and cleans up
    # the process tree. No signing credentials are passed to this worker.
    $workerArguments = @('-NoProfile','-NonInteractive','-File', ('"' + $PSCommandPath + '"'), '-Operation','Worker','-State',('"' + $State + '"'))
    $worker = Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList $workerArguments -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput "$State/bundle.stdout.log" -RedirectStandardError "$State/bundle.stderr.log"
    $worker.Id | Set-Content "$State/worker.pid"
    exit 0
}
if (!$State -or !(Test-Path "$State/config.json")) {
    if ($Operation -eq 'Cleanup') { exit 0 }
    throw 'Missing signing session'
}
$config = Read-Json "$State/config.json"
$root = $config.workspace
$installer = Join-Path $root "target/release/bundle/nsis/Zephium_$($config.version)_x64-setup.exe"
try {
    switch ($Operation) {
        'Worker' {
            Set-Location (Join-Path $root 'desktop')
            & pnpm.cmd exec tauri bundle --bundles nsis --config "$State/bundle.json"
            $result = $LASTEXITCODE
            if ($result -ne 0) { throw "Tauri bundler failed ($result)" }
            Write-Atomic "$State/worker-exit.json" '{"exitCode":0}'
        }
        'Hook' {
            $path = (Resolve-Path -LiteralPath $File).Path
            $pluginRoot = Join-Path $root 'target/release/nsis/x64/Plugins/x86-unicode'
            $thirdParty = @('NSISdl.dll','StartMenu.dll','System.dll','nsDialogs.dll','additional/nsis_tauri_utils.dll')
            foreach ($plugin in $thirdParty) {
                if ($path -eq (Join-Path $pluginRoot $plugin)) {
                    Write-Host "Preserving upstream NSIS plugin without Zephium signing: $plugin"
                    exit 0
                }
            }
            if ($path -eq (Join-Path $root 'target/release/zephium-desktop.exe')) { $Role = 'app' }
            elseif ($path -eq $installer) { $Role = 'installer' }
            else {
                # NSIS creates its temporary uninstaller beneath TEMP. Any
                # unexpected binary/path/product fails closed.
                $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
                if (!$path.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Unexpected signing target: $path" }
                $Role = 'uninstaller'
            }
            Assert-Metadata $path
            $previous = @{app = ''; uninstaller = 'app'; installer = 'uninstaller'}[$Role]
            if ($previous -and !(Test-Path "$State/$previous/done")) { throw "Out-of-order signing request: $Role" }
            $dir = Join-Path $State $Role
            New-Item -ItemType Directory -Path "$dir/unsigned" | Out-Null
            Copy-Item -LiteralPath $path -Destination "$dir/unsigned/Zephium.exe"
            Write-Atomic "$dir/request.json" (@{role=$Role; path=$path; sha256=(Get-FileHash -LiteralPath $path).Hash} | ConvertTo-Json)
            Wait-File "$dir/ready" 4200
            if ((Get-FileHash -LiteralPath $path).Hash -ne (Read-Json "$dir/request.json").sha256) { throw 'Input changed while signing' }
            Assert-Signature "$dir/signed/Zephium.exe"
            Copy-Item "$dir/signed/Zephium.exe" -Destination $path -Force
            Assert-Signature $path
            Write-Atomic "$dir/done" 'verified'
        }
        'Wait' {
            if (!$Role) { throw 'Missing signing role' }
            Wait-File "$State/$Role/request.json"
            $request = Read-Json "$State/$Role/request.json"
            if ($request.role -cne $Role) { throw 'Signing role mismatch' }
            "unsigned=$State/$Role/unsigned" >> $env:GITHUB_OUTPUT
            "signed=$State/$Role/signed" >> $env:GITHUB_OUTPUT
            "version=$($config.version)" >> $env:GITHUB_OUTPUT
        }
        'Complete' {
            if (!$Role) { throw 'Missing signing role' }
            $files = @(Get-ChildItem "$State/$Role/signed" -File -Recurse)
            if ($files.Count -ne 1 -or $files[0].Name -cne 'Zephium.exe') { throw 'Unexpected signed artifact contents' }
            Assert-Signature "$State/$Role/signed/Zephium.exe"
            Write-Atomic "$State/$Role/ready" 'verified'
            Wait-File "$State/$Role/done" 120
        }
        'Finish' {
            Wait-File "$State/worker-exit.json" 600
            if ((Read-Json "$State/worker-exit.json").exitCode -ne 0) { throw 'Bundler failed' }
            foreach ($item in @('app','uninstaller','installer')) {
                if (!(Test-Path "$State/$item/done")) { throw "Missing verified signature: $item" }
                Assert-Signature "$State/$item/signed/Zephium.exe"
            }
            Assert-Signature $installer
            if ((Get-FileHash $installer).Hash -ne (Get-FileHash "$State/installer/signed/Zephium.exe").Hash) { throw 'Final installer changed after signing' }
            Get-Content "$State/bundle.stdout.log"
        }
        'TestRejection' {
            # Exercise real Windows verification with corrupted signed bytes,
            # a wrong expected publisher, and an unexpected product version.
            $original = "$State/app/signed/Zephium.exe"
            Assert-Signature $original
            $tampered = Join-Path $State 'tampered.exe'
            $bytes = [IO.File]::ReadAllBytes($original)
            $bytes[1024] = $bytes[1024] -bxor 1
            [IO.File]::WriteAllBytes($tampered, $bytes)
            $rejected = $false
            try { Assert-Signature $tampered } catch { $rejected = $true }
            if (!$rejected) { throw 'Verification accepted tampered bytes' }
            Remove-Item $tampered
            $expected = $config.thumbprint
            $config.thumbprint = '0000000000000000000000000000000000000000'
            $rejected = $false
            try { Assert-Signature $original } catch { $rejected = $true }
            $config.thumbprint = $expected
            if (!$rejected) { throw 'Verification accepted the wrong publisher' }
            $expectedVersion = $config.version
            $config.version = '0.0.0-unexpected'
            $rejected = $false
            try { Assert-Signature $original } catch { $rejected = $true }
            $config.version = $expectedVersion
            if (!$rejected) { throw 'Verification accepted the wrong version' }
            Write-Host 'Rejected tampered bytes, wrong publisher, and wrong version.'
        }
        'Smoke' {
            if ($env:RUNNER_ENVIRONMENT -ne 'github-hosted') { throw 'Installation tests require a disposable runner' }
            $destination = Join-Path $State 'installation'
            $install = Start-Process -FilePath $installer -ArgumentList @('/S', "/D=$destination") -PassThru
            if (!$install.WaitForExit(180000)) { $install.Kill($true); throw 'Installer timed out' }
            if ($install.ExitCode -ne 0) { throw "Installation failed: $($install.ExitCode)" }
            foreach ($entry in @(@('app','zephium-desktop.exe'), @('uninstaller','uninstall.exe'))) {
                $installed = Join-Path $destination $entry[1]
                Assert-Signature $installed
                if ((Get-FileHash $installed).Hash -ne (Get-FileHash "$State/$($entry[0])/signed/Zephium.exe").Hash) { throw 'Installed bytes differ from signed bytes' }
            }
            $uninstall = Start-Process -FilePath "$destination/uninstall.exe" -ArgumentList @('/S', "_?=$destination") -PassThru
            if (!$uninstall.WaitForExit(120000)) { $uninstall.Kill($true); throw 'Uninstaller timed out' }
            if ($uninstall.ExitCode -ne 0 -or (Test-Path "$destination/zephium-desktop.exe")) { throw 'Uninstallation failed' }
            Write-Host 'Verified installation, installed app/uninstaller signatures and hashes, and uninstallation.'
        }
        'Cleanup' {
            [IO.File]::WriteAllText("$State/cancelled", 'cancelled')
            if (!(Test-Path "$State/worker-exit.json") -and (Test-Path "$State/worker.pid")) {
                $workerId = [int](Get-Content "$State/worker.pid")
                & taskkill.exe /PID $workerId /T /F 2>$null
            }
            if (Test-Path "$State/test-trust-added") {
                Remove-Item "Cert:\CurrentUser\Root\$($config.thumbprint)" -ErrorAction SilentlyContinue
            }
            foreach ($log in @('bundle.stdout.log','bundle.stderr.log')) {
                if (Test-Path "$State/$log") { Get-Content "$State/$log" -Tail 100 }
            }
            $global:LASTEXITCODE = 0
        }
    }
} catch {
    if ($Operation -ne 'Cleanup' -and !(Test-Path "$State/failed.txt")) {
        Write-Atomic "$State/failed.txt" $_.Exception.Message
    }
    throw
}
