# Builds the Windows release and packages it as CI does, into dist\: an
# installer (Inno Setup, hanashi.iss) and a .zip, each with the app in a
# folder named Hanashi.
#
#   powershell -ExecutionPolicy Bypass -File packaging\windows\build-installer.ps1
#
# The version is app\pubspec.yaml's, and the files are named like CI's builds,
# with commits counted here where CI counts its runs (as on Linux, see
# packaging/linux/build-appimage.sh). CI's Windows job runs this too, with its
# own version, build number and file name:
#
#   build-installer.ps1 -Version 0.2.0 -BuildNumber 123 -Name hanashi-v0.2.0-windows-x64
#
# Flutter builds Windows apps only on Windows. Needs: Flutter (the version in
# .github/workflows/ci.yml; another one gets a warning), Visual Studio with
# "Desktop development with C++", Developer Mode on (plugins are linked in
# with symlinks), git, and Inno Setup 6 (winget install JRSoftware.InnoSetup),
# or ISCC set to the path of its ISCC.exe. Windows PowerShell or PowerShell 7.
param(
  # The version name, e.g. 0.2.0 (default: app\pubspec.yaml's).
  [string] $Version,
  # The build number (default: the number of commits).
  [string] $BuildNumber,
  # The file name without extension (default: hanashi-VERSION-COMMIT-windows-x64).
  [string] $Name,
  # Where the files go (default: dist\).
  [string] $OutDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$release = Join-Path $root 'app\build\windows\x64\runner\Release'

function Assert-Exit([string] $what) {
  if ($LASTEXITCODE -ne 0) { throw "$what failed (exit code $LASTEXITCODE)" }
}

# Inno Setup's compiler: ISCC, on PATH, or where its installer puts it (for
# everyone or for this user).
function Find-Iscc {
  if ($env:ISCC) { return $env:ISCC }
  $onPath = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }
  foreach ($dir in ${env:ProgramFiles(x86)}, $env:ProgramFiles, "$env:LOCALAPPDATA\Programs") {
    if (-not $dir) { continue }
    $found = Get-ChildItem (Join-Path $dir 'Inno Setup *\ISCC.exe') -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
  }
}

# What the build needs, before it takes its minutes. GitHub's runners may
# lack Inno Setup; they get it from Chocolatey.
$iscc = Find-Iscc
if (-not $iscc -and $env:GITHUB_ACTIONS -eq 'true') {
  choco install innosetup --yes --no-progress | Out-Null
  Assert-Exit 'choco install innosetup'
  $iscc = Find-Iscc
}
if (-not $iscc) {
  throw 'Inno Setup 6 not found: install it (winget install JRSoftware.InnoSetup), or set ISCC to the path of its ISCC.exe.'
}
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  throw 'flutter not found on PATH.'
}

# CI's Flutter makes the releases; another one may build a different app.
$ciFlutter = Select-String -Path (Join-Path $root '.github\workflows\ci.yml') -Pattern '^  FLUTTER_VERSION:\s*(\S+)' |
  Select-Object -First 1
$flutterInfo = flutter --version --machine | Out-String
Assert-Exit 'flutter --version'
if ($ciFlutter -and $flutterInfo -match '"frameworkVersion"\s*:\s*"([^"]+)"') {
  $ciVersion = $ciFlutter.Matches[0].Groups[1].Value
  if ($Matches[1] -ne $ciVersion) {
    Write-Warning "Flutter $($Matches[1]) here; CI builds with $ciVersion."
  }
}

if (-not $Version) {
  $line = Select-String -Path (Join-Path $root 'app\pubspec.yaml') -Pattern '^version:\s*([0-9.]+)' | Select-Object -First 1
  if (-not $line) { throw 'No version in app\pubspec.yaml' }
  $Version = $line.Matches[0].Groups[1].Value
}
if (-not $BuildNumber) {
  $BuildNumber = git -C $root rev-list --count HEAD
  Assert-Exit 'git rev-list'
}
if (-not $Name) {
  $commit = git -C $root rev-parse --short=7 HEAD
  Assert-Exit 'git rev-parse'
  git -C $root diff --quiet HEAD
  if ($LASTEXITCODE -ne 0) { $commit += '-dirty' }
  $Name = "hanashi-$Version-$commit-windows-x64"
}
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

Push-Location (Join-Path $root 'app')
try {
  flutter build windows --release "--build-name=$Version" "--build-number=$BuildNumber"
  Assert-Exit 'flutter build windows'
} finally {
  Pop-Location
}
if (-not (Test-Path (Join-Path $release 'hanashi.exe'))) {
  throw "No hanashi.exe in $release"
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$out = (Resolve-Path $OutDir).Path

# The .zip, entry by entry: the app goes in a folder named Hanashi without
# being copied there first, and the names have / whichever PowerShell runs
# this.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zipPath = Join-Path $out "$Name.zip"
Remove-Item $zipPath -ErrorAction SilentlyContinue
$zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
  foreach ($file in Get-ChildItem $release -Recurse -File -Force) {
    $entry = 'Hanashi/' + $file.FullName.Substring($release.Length + 1).Replace('\', '/')
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $entry, 'Optimal')
  }
} finally {
  $zip.Dispose()
}

& $iscc /Qp "/DAppVersion=$Version" "/DAppDir=$release" "/DOutputDir=$out" "/DOutputName=$Name-setup" `
  (Join-Path $PSScriptRoot 'hanashi.iss')
Assert-Exit 'Inno Setup'

Get-ChildItem $out -Filter "$Name*" | Format-Table Name, Length -AutoSize
