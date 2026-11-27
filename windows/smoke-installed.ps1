param(
    [Parameter(Mandatory = $true)][string]$Package,
    [string]$PreviousPackage,
    [string]$Python = "python"
)

$ErrorActionPreference = "Stop"
$packagePath = (Resolve-Path -LiteralPath $Package).Path
$buildRoot = (New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot "build") -Force).FullName
$workspace = Join-Path $buildRoot ("msi-smoke-" + [guid]::NewGuid().ToString("n"))
$installation = Join-Path $workspace "installed"
$dataDirectory = Join-Path $workspace "data"
$installer = Join-Path ([Environment]::SystemDirectory) "msiexec.exe"

Add-Type @'
using System.Runtime.InteropServices;
public static class GaoJiLingInstallerSmoke {
    [DllImport("msi.dll", CharSet=CharSet.Unicode)]
    public static extern int MsiQueryProductState(string product);
}
'@

function Test-ProductState([string]$Product, [int]$Expected) {
    if ($Product -notmatch '^\{[0-9A-Fa-f-]{36}\}$' -or
        [GaoJiLingInstallerSmoke]::MsiQueryProductState($Product) -ne $Expected) {
        throw "Unexpected registration state for private MSI $Product. Evidence in $workspace"
    }
}

function Invoke-TestInstaller([string[]]$Arguments) {
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        $process = Start-Process -FilePath $installer -ArgumentList $Arguments -WindowStyle Hidden -PassThru -Wait
        if ($process.ExitCode -ne 1618 -or $attempt -eq 8) { break }
        Start-Sleep -Seconds 3
    }
    if ($process.ExitCode -ne 0) { throw "Windows Installer exited with code $($process.ExitCode), logs in $workspace" }
}

function Install-Fixture($Fixture, [string]$LogName) {
    $log = Join-Path $workspace $LogName
    Invoke-TestInstaller -Arguments @('/i', "`"$($Fixture.path)`"", "INSTALLDIR=`"$installation`"",
        'GAOISOLATED=1', '/qn', '/norestart', '/l*v', "`"$log`"")
    Test-ProductState $Fixture.product 5
}

function Uninstall-Fixture($Fixture, [string]$LogName) {
    $log = Join-Path $workspace $LogName
    Invoke-TestInstaller -Arguments @('/x', $Fixture.product, 'GAOISOLATED=1', '/qn', '/norestart', '/l*v', "`"$log`"")
    Test-ProductState $Fixture.product -1
}

function Invoke-InstalledApp([string]$Version, [string]$TaskName, [string]$PreviousTaskId = '', [switch]$SeedSettings) {
    $gui = Join-Path $installation 'GaoJiLing.exe'
    $cli = Join-Path $installation 'GaoJiLing-cli.exe'
    if ((& $cli --version) -ne $Version -or $LASTEXITCODE -ne 0) { throw "Installed CLI version mismatch" }
    $peBytes = [IO.File]::ReadAllBytes($gui)
    $header = [BitConverter]::ToInt32($peBytes, 0x3c)
    if ([BitConverter]::ToUInt16($peBytes, $header + 4) -ne 0x8664) { throw "Installed GUI was not x64" }

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $app = Start-Process -FilePath $gui -ArgumentList @('--data-dir', "`"$dataDirectory`"",
        '--serve', '--no-browser', '--port', "$port") -PassThru -WindowStyle Hidden
    try {
        $url = "http://127.0.0.1:$port"
        $page = $null
        $deadline = (Get-Date).AddSeconds(85)
        do {
            if ($app.HasExited) { throw "Installed GUI exited with code $($app.ExitCode)" }
            try { $page = Invoke-WebRequest -Uri "$url/" -TimeoutSec 2 -NoProxy } catch {}
            if ($page) { break }
            Start-Sleep -Milliseconds 400
        } while ((Get-Date) -lt $deadline)
        if (-not $page -or $page.StatusCode -ne 200) { throw "Installed GUI did not return HTTP 200" }
        $token = [regex]::Match($page.Content, 'name="gao-token" content="([^"]+)"').Groups[1].Value
        if (-not $token) { throw "HTTP 200 page did not include a session token" }
        $headers = @{ 'X-Gao-Token' = $token }
        $post = @{ Headers = $headers; Method = 'Post'; ContentType = 'application/json'; NoProxy = $true }
        $state = Invoke-RestMethod -Uri "$url/api/state" -Headers $headers -NoProxy
        if ($state.version -ne $Version -or $state.panel.horizontalRatio -ne 0.61 -or $state.panel.verticalRatio -ne 0.37) {
            throw "Installed GUI did not read the expected version and saved panel position"
        }
        if ($state.desktop.available -or $state.desktop.trayAvailable) {
            throw "The headless smoke entry unexpectedly started the desktop host or a tray icon"
        }
        if ($PreviousTaskId) {
            $oldTask = @($state.sessions | Where-Object { $_.id -eq $PreviousTaskId -and $_.name -eq 'Prior build smoke' -and $_.end })
            if ($oldTask.Count -ne 1 -or $state.settings.appearance -ne 'dark' -or
                $state.settings.retentionDays -ne 14 -or $state.settings.hotkeyChoice -ne 'm') {
                throw "Upgraded GUI did not restore the prior build's saved task and preferences"
            }
        }
        if ($SeedSettings) {
            Invoke-RestMethod -Uri "$url/api/settings" @post -Body '{"appearance":"dark","retentionDays":14,"hotkeyChoice":"m"}' | Out-Null
        }
        $taskBody = @{ name = $TaskName } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$url/api/session/start" @post -Body $taskBody | Out-Null
        $state = Invoke-RestMethod -Uri "$url/api/state" -Headers $headers -NoProxy
        if ($state.activeSession.name -ne $TaskName) { throw "Installed GUI failed to write a task" }
        $taskId = $state.activeSession.id
        if ($PreviousTaskId) {
            $started = $state.activeSession.start
            $deadline = (Get-Date).AddSeconds(35)
            do {
                Start-Sleep -Milliseconds 400
                $state = Invoke-RestMethod -Uri "$url/api/state" -Headers $headers -NoProxy
                if ($state.latest.timestamp -gt $started) { break }
            } while ((Get-Date) -lt $deadline)
            if ($state.latest.timestamp -le $started) { throw 'The candidate task did not receive a real sample' }
        }
        Invoke-RestMethod -Uri "$url/api/session/stop" @post -Body '{}' | Out-Null
        if ($PreviousTaskId) {
            $body = @{ ids = @($PreviousTaskId, $taskId) } | ConvertTo-Json -Compress
            $comparison = Invoke-RestMethod -Uri "$url/api/session/compare" @post -Body $body
            $runs = @($comparison.sessions)
            if ($runs.Count -ne 2 -or $runs[0].id -ne $PreviousTaskId -or $runs[1].id -ne $taskId -or
                $runs[0].trend.source -ne 'history' -or $runs[0].processes.available -ne $false -or
                $runs[1].trend.source -ne 'session' -or $runs[1].sampleCount -lt 1 -or
                $comparison.comparable.durationSeconds -ne $true) {
                throw 'Upgraded GUI did not compare the legacy task and the newly sampled task as expected'
            }
        }
        Invoke-RestMethod -Uri "$url/api/shutdown" @post -Body '{}' | Out-Null
        if (-not $app.WaitForExit(20000) -or $app.ExitCode -ne 0) { throw "Installed GUI did not exit normally" }
        $probe = [Net.Sockets.TcpClient]::new()
        try {
            try { $probe.Connect([Net.IPAddress]::Loopback, $port) } catch [Net.Sockets.SocketException] {}
            if ($probe.Connected) { throw "The loopback port remained open after shutdown" }
        } finally {
            $probe.Dispose()
        }
        return $taskId
    } finally {
        if (-not $app.HasExited) {
            & (Join-Path ([Environment]::SystemDirectory) 'taskkill.exe') /PID $app.Id /T /F | Out-Null
        }
    }
}

New-Item -ItemType Directory -Path $workspace,$dataDirectory | Out-Null
$prepare = @('-B', (Join-Path $PSScriptRoot 'prepare_smoke_packages.py'), $workspace, $packagePath)
if ($PreviousPackage) { $prepare += @('--previous', (Resolve-Path -LiteralPath $PreviousPackage).Path) }
$privatePackages = & $Python @prepare
if ($LASTEXITCODE -ne 0) { throw "Could not create private MSI copies. Evidence in $workspace" }
$fixtures = $privatePackages | ConvertFrom-Json
$candidate = $fixtures.candidate
$previous = $fixtures.previous
Test-ProductState $candidate.product -1
if ($previous) { Test-ProductState $previous.product -1 }

$legacyPanel = Join-Path $dataDirectory 'panel.json'
'{"verticalRatio":0.37,"horizontalRatio":0.61,"displayId":"fixture"}' | Set-Content -LiteralPath $legacyPanel -Encoding Ascii
$originalPanel = (Get-FileHash -LiteralPath $legacyPanel).Hash
$runtimeDatabase = Join-Path $dataDirectory 'monitor.sqlite'
$verified = $false
try {
    $previousTask = ''
    if ($previous) {
        Install-Fixture $previous 'install-previous.log'
        $previousTask = Invoke-InstalledApp $previous.version 'Prior build smoke' -SeedSettings
        if (-not $previousTask) { throw "Prior build did not return a task identifier" }
        $beforeUpgrade = (Get-FileHash -LiteralPath $runtimeDatabase).Hash
    }
    Install-Fixture $candidate 'install-candidate.log'
    if ($previous) {
        Test-ProductState $previous.product -1
        if ((Get-FileHash -LiteralPath $runtimeDatabase).Hash -ne $beforeUpgrade) {
            throw "MSI major upgrade changed isolated data before the GUI opened it"
        }
    }
    if ((Get-FileHash -LiteralPath $legacyPanel).Hash -ne $originalPanel) { throw "Installer changed isolated panel settings" }
    Invoke-InstalledApp $candidate.version 'Installed smoke' $previousTask | Out-Null
    $runtimeHash = (Get-FileHash -LiteralPath $runtimeDatabase).Hash
    Uninstall-Fixture $candidate 'uninstall-candidate.log'
    if ((Test-Path -LiteralPath (Join-Path $installation 'GaoJiLing.exe')) -or
        (Test-Path -LiteralPath (Join-Path $installation 'GaoJiLing-cli.exe')) -or
        (Get-FileHash -LiteralPath $runtimeDatabase).Hash -ne $runtimeHash -or
        (Get-FileHash -LiteralPath $legacyPanel).Hash -ne $originalPanel) {
        throw "Uninstall did not remove only installed program files"
    }
    $verified = $true
    if ($previous) {
        Write-Output "Verified private MSI major upgrade $($previous.version) to $($candidate.version), saved task and settings."
        Write-Output 'Verified the upgraded comparison of a legacy task and a new task with real samples.'
    }
    Write-Output 'Verified MSI SHA-256, private install, x64 headless launcher without tray, task round-trip, loopback shutdown and data-preserving uninstall.'
} finally {
    foreach ($entry in @($candidate, $previous)) {
        if ($entry -and [GaoJiLingInstallerSmoke]::MsiQueryProductState($entry.product) -eq 5) {
            try { Uninstall-Fixture $entry ("cleanup-" + $entry.version + ".log") } catch { Write-Warning $_ }
        }
    }
    $checked = Get-Item -LiteralPath $workspace
    if ($verified -and $checked.FullName -eq $workspace -and $checked.Parent.FullName -eq $buildRoot -and
        -not ($checked.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $checked.FullName -Recurse -Force
    }
}
