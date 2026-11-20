# Builds dist\Pixelpress.exe on Windows. Needs Python 3.12+.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
python -m pip install --upgrade pip
python -m pip install -r requirements.txt pyinstaller
python -m PyInstaller --noconfirm --clean --onefile --windowed `
  --name Pixelpress `
  --icon assets\pixelpress.ico `
  --add-data "assets\pixelpress.png;assets" `
  --version-file version_info.txt `
  --collect-all pi_heif --collect-all rawpy `
  run.py
Write-Host "Built dist\Pixelpress.exe"
