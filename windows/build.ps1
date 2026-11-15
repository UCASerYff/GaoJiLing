$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $true
}
Set-Location $PSScriptRoot

function Assert-LastExit($step) {
    if ($LASTEXITCODE -ne 0) {
        throw "$step failed with exit code $LASTEXITCODE"
    }
}

python -m pip install --disable-pip-version-check -r requirements-dev.txt
Assert-LastExit "pip install"
python -m pytest -q
Assert-LastExit "pytest"

$assetDir = Join-Path $PSScriptRoot "src\gaojiling\assets"
if (-not (Test-Path (Join-Path $assetDir "index.html"))) {
    throw "UI assets were not found at $assetDir"
}
$assets = "{0};gaojiling_assets" -f $assetDir

python -m PyInstaller --noconfirm --clean --name GaoJiLing-cli --console --onefile --paths src --add-data $assets --distpath dist --workpath build/cli --specpath build/cli launch.py
Assert-LastExit "PyInstaller cli"
python -m PyInstaller --noconfirm --clean --name GaoJiLing --windowed --onefile --paths src --add-data $assets --distpath dist --workpath build/gui --specpath build/gui launch.py
Assert-LastExit "PyInstaller windowed"

Get-ChildItem dist\*.exe | ForEach-Object { Write-Output ("{0}`t{1}" -f $_.Name, $_.Length) }
