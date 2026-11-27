param([Parameter(Mandatory = $true)][string]$Package)

$ErrorActionPreference = "Stop"
$packagePath = (Resolve-Path -LiteralPath $Package).Path
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$workspace = Join-Path $temporaryRoot ("gaojiling-msi-smoke-" + [guid]::NewGuid().ToString("n"))
$installation = Join-Path $workspace "installed"
$dataDirectory = Join-Path $workspace "data"
$installer = Join-Path ([Environment]::SystemDirectory) "msiexec.exe"
$checksum = ((Get-Content -LiteralPath ($packagePath + ".sha256") -Raw).Trim() -split '\s+')[0]
if ((Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $checksum) {
    throw "MSI SHA-256 did not match"
}

Add-Type @'
using System.Runtime.InteropServices;
public static class GaoJiLingInstallerSmoke {
    [DllImport("msi.dll", CharSet=CharSet.Unicode)]
    public static extern int MsiQueryProductState(string product);
}
'@
$msi = New-Object -ComObject WindowsInstaller.Installer
$database = $msi.OpenDatabase($packagePath, 0)
$view = $database.OpenView('SELECT `Value` FROM `Property` WHERE `Property`=''ProductCode''')
$view.Execute()
$product = $view.Fetch().StringData(1)
$view.Close()
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($view)
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($database)
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($msi)
if ($product -notmatch '^\{[0-9A-Fa-f-]{36}\}$' -or [GaoJiLingInstallerSmoke]::MsiQueryProductState($product) -ne -1) {
    throw "This product code is already registered or could not be verified for isolated installation"
}

function Invoke-TestInstaller([string[]]$Arguments) {
    $process = Start-Process -FilePath $installer -ArgumentList $Arguments -WindowStyle Hidden -PassThru -Wait
    if ($process.ExitCode -ne 0) { throw "Windows Installer exited with code $($process.ExitCode), logs in $workspace" }
}

New-Item -ItemType Directory -Path $workspace,$dataDirectory | Out-Null
$legacyPanel = Join-Path $dataDirectory 'panel.json'
'{"verticalRatio":0.37,"horizontalRatio":0.61,"displayId":"fixture"}' | Set-Content -LiteralPath $legacyPanel -Encoding Ascii
$originalPanel = (Get-FileHash -LiteralPath $legacyPanel).Hash
$app = $null
$installed = $false
$verified = $false
try {
    Invoke-TestInstaller -Arguments @('/i', "`"$packagePath`"", "INSTALLDIR=`"$installation`"", 'GAOISOLATED=1', '/qn', '/norestart', '/l*v', "`"$workspace\install.log`"")
    $installed = $true
    if ((Get-FileHash -LiteralPath $legacyPanel).Hash -ne $originalPanel) { throw "installer changed isolated user preferences" }
    $gui = Join-Path $installation 'GaoJiLing.exe'
    $cli = Join-Path $installation 'GaoJiLing-cli.exe'
    if ((& $cli --version) -notmatch '^1\.16\+\d+$' -or $LASTEXITCODE -ne 0) { throw "installed CLI version mismatch" }
    $peBytes = [IO.File]::ReadAllBytes($gui)
    $header = [BitConverter]::ToInt32($peBytes, 0x3c)
    if ([BitConverter]::ToUInt16($peBytes, $header + 4) -ne 0x8664) { throw "installed GUI was not x64" }

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $app = Start-Process -FilePath $gui -ArgumentList @('--data-dir', "`"$dataDirectory`"", '--serve', '--no-browser', '--port', "$port") -PassThru -WindowStyle Hidden
    $url = "http://127.0.0.1:$port"
    $page = $null
    $deadline = (Get-Date).AddSeconds(85)
    do {
        if ($app.HasExited) { throw "installed GUI exited early with code $($app.ExitCode)" }
        try { $page = Invoke-WebRequest -Uri "$url/" -TimeoutSec 2 -NoProxy } catch {}
        if ($page) { break }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
    if (-not $page -or $page.StatusCode -ne 200) { throw "installed GUI did not return HTTP 200" }
    $token = [regex]::Match($page.Content, 'name="gao-token" content="([^"]+)"').Groups[1].Value
    if (-not $token) { throw "HTTP 200 page did not include a session token" }
    $headers = @{ 'X-Gao-Token' = $token }
    $post = @{ Headers = $headers; Method = 'Post'; ContentType = 'application/json'; NoProxy = $true }
    Invoke-RestMethod -Uri "$url/api/session/start" @post -Body '{"name":"Installed smoke"}' | Out-Null
    $state = Invoke-RestMethod -Uri "$url/api/state" -Headers $headers -NoProxy
    if ($state.activeSession.name -ne 'Installed smoke' -or $state.panel.horizontalRatio -ne 0.61 -or $state.panel.verticalRatio -ne 0.37) {
        throw "installed GUI failed to read compatible preferences or write a task"
    }
    Invoke-RestMethod -Uri "$url/api/session/stop" @post -Body '{}' | Out-Null
    Invoke-RestMethod -Uri "$url/api/shutdown" @post -Body '{}' | Out-Null
    if (-not $app.WaitForExit(20000)) { throw "installed GUI did not exit normally" }
    $runtimeDatabase = Join-Path $dataDirectory 'monitor.sqlite'
    $runtimeHash = (Get-FileHash -LiteralPath $runtimeDatabase).Hash
    Invoke-TestInstaller -Arguments @('/x', $product, 'GAOISOLATED=1', '/qn', '/norestart', '/l*v', "`"$workspace\uninstall.log`"")
    $installed = $false
    if ((Test-Path -LiteralPath $gui) -or (Get-FileHash -LiteralPath $runtimeDatabase).Hash -ne $runtimeHash -or (Get-FileHash -LiteralPath $legacyPanel).Hash -ne $originalPanel) {
        throw "uninstall did not remove only installed program files"
    }
    $verified = $true
    Write-Output 'MSI SHA-256, installed x64 programs, launcher, isolated legacy settings, task round-trip, orderly exit and data-preserving uninstall verified.'
} finally {
    if ($app -and -not $app.HasExited) { & (Join-Path ([Environment]::SystemDirectory) 'taskkill.exe') /PID $app.Id /T /F | Out-Null }
    if ($installed) {
        try { Invoke-TestInstaller -Arguments @('/x', $product, 'GAOISOLATED=1', '/qn', '/norestart') } catch { Write-Warning $_ }
    }
    $checked = (Get-Item -LiteralPath $workspace).FullName
    if ($verified -and $checked -eq $workspace -and (Split-Path $checked -Parent) -eq $temporaryRoot.TrimEnd('\')) {
        Remove-Item -LiteralPath $checked -Recurse -Force
    }
}
