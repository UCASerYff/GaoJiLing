param(
    [string]$Python = "python",
    [switch]$SkipInstallDependencies,
    [switch]$TestsOnly
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Invoke-Python {
    & $Python @args
    if ($LASTEXITCODE -ne 0) { throw "Python build step failed with exit code $LASTEXITCODE" }
}

Invoke-Python -c "import platform, sys; assert sys.version_info[:2] == (3, 12) and sys.platform == 'win32' and platform.machine() == 'AMD64', 'Use x64 CPython 3.12'"
if (-not $SkipInstallDependencies) {
    Invoke-Python -m pip install --disable-pip-version-check -r requirements-dev.txt
}
$buildRoot = (New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot "build") -Force).FullName
$testRoot = Join-Path $buildRoot ("pytest-" + [guid]::NewGuid().ToString("n"))
try {
    Invoke-Python -B -m pytest -q -p no:cacheprovider --basetemp $testRoot
} finally {
    $created = Get-Item -LiteralPath $testRoot -ErrorAction SilentlyContinue
    if ($created -and $created.FullName -eq $testRoot -and $created.Parent.FullName -eq $buildRoot -and
        -not ($created.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $created.FullName -Recurse -Force
    }
}
if ($TestsOnly) { return }

$build = Join-Path $buildRoot "package"
$dist = Join-Path $PSScriptRoot "dist"
$programs = Join-Path $build "programs"
New-Item -ItemType Directory -Path $build,$dist,$programs -Force | Out-Null
Invoke-Python .\prepare_package.py $build
$assetDir = Join-Path $PSScriptRoot "src\gaojiling\assets"
$assetMapping = "{0};gaojiling_assets" -f $assetDir
$pngMapping = "{0};gaojiling_assets" -f (Join-Path (Split-Path $PSScriptRoot -Parent) "Assets\AppIcon.png")
$ico = Join-Path $build "AppIcon.ico"
$icoMapping = "{0};gaojiling_assets" -f $ico
$common = @('--noconfirm', '--clean', '--onefile', '--paths', 'src', '--add-data', $assetMapping,
    '--add-data', $pngMapping, '--add-data', $icoMapping, '--icon', $ico, '--version-file',
    (Join-Path $build "FileVersion.txt"), '--distpath', $programs)
$guiWork = Join-Path $build "gui"
$cliWork = Join-Path $build "cli"
Invoke-Python -m PyInstaller @common --name GaoJiLing --windowed --workpath $guiWork --specpath $guiWork launch.py
Invoke-Python -m PyInstaller @common --name GaoJiLing-cli --console --exclude-module gaojiling.desktop --exclude-module gaojiling.appwindow --workpath $cliWork --specpath $cliWork launch_cli.py

$notice = Join-Path $build "ThirdPartyNotices.txt"
$msiWork = Join-Path $build "msi"
$package = (Invoke-Python .\package_msi.py $programs $msiWork $notice | Select-Object -Last 1)
$final = Join-Path $dist (Split-Path $package -Leaf)
Copy-Item -LiteralPath $package -Destination $final -Force
$hash = (Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $(Split-Path $final -Leaf)" | Set-Content -LiteralPath ($final + ".sha256") -Encoding Ascii
Get-Item -LiteralPath $final,($final + ".sha256") | ForEach-Object { Write-Output ("{0}`t{1}" -f $_.FullName, $_.Length) }
