# Baut den Windows-Installer von Textly.
#
# Aufruf aus dem Ordner app:   powershell -ExecutionPolicy Bypass -File tool\build_installer.ps1
# Ergebnis:                    build\installer\Textly-Setup-<Version>.exe
#
# Voraussetzungen: Flutter, Inno Setup 6 (winget install JRSoftware.InnoSetup)

$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
Set-Location $app

# Version aus pubspec.yaml (z. B. "0.1.0+1" -> "0.1.0")
$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value
Write-Host "Textly $version"

# 1. Release-Build
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'flutter build ist fehlgeschlagen' }
$release = Join-Path $app 'build\windows\x64\runner\Release'

# 2. Microsoft-C++-Laufzeit neben das Programm legen (erlaubte «app-local» Weitergabe),
#    damit Textly auch auf Rechnern ohne installiertes Visual C++ Redistributable startet.
foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
  $src = Join-Path $env:WINDIR "System32\$dll"
  if (-not (Test-Path $src)) { throw "$dll fehlt in System32 (Visual C++ Redistributable installieren)" }
  Copy-Item $src $release -Force
}

# 3. Installer
$iscc = @(
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 nicht gefunden (winget install JRSoftware.InnoSetup)' }
& $iscc "/DAppVersion=$version" (Join-Path $app 'installer\textly.iss')
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup ist fehlgeschlagen' }

$out = Join-Path $app "build\installer\Textly-Setup-$version.exe"
# Gleicher Inhalt unter festem Namen: GitHub verlinkt so immer die neueste Version
# (…/releases/latest/download/Textly-Setup.exe). Beim Release beide Dateien hochladen.
Copy-Item $out (Join-Path $app 'build\installer\Textly-Setup.exe') -Force
Write-Host "Fertig: $out ($([math]::Round((Get-Item $out).Length / 1MB, 1)) MB)"
