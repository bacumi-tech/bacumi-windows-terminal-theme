# Download a versioned release, verify it, then use the local installers.
[CmdletBinding()]
param([string] $FragmentRoot, [string] $ModuleRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$version = '0.3.4'
$name = "bacumi-windows-terminal-theme-$version"
$base = "https://github.com/bacumi-tech/bacumi-windows-terminal-theme/releases/download/v$version"
$stage = Join-Path ([IO.Path]::GetTempPath()) ('bacumi-download-' + [guid]::NewGuid().ToString('N'))
# Windows PowerShell 5.1 can otherwise negotiate an obsolete TLS version.
$previousTls = [Net.ServicePointManager]::SecurityProtocol
try {
    [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Path $stage | Out-Null
    $archive = Join-Path $stage "$name.zip"
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$name.zip" -OutFile $archive
    $checksums = Join-Path $stage 'SHA256SUMS'
    Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile $checksums
    $record = ([IO.File]::ReadAllText($checksums)).Trim()
    if ($record -notmatch ('^([a-fA-F0-9]{64})  ' + [regex]::Escape("$name.zip") + '$')) { throw 'Invalid release checksum record.' }
    $expected = $Matches[1]
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected) { throw 'Release checksum mismatch; installation was not changed.' }
    Expand-Archive -LiteralPath $archive -DestinationPath $stage
    $source = Join-Path $stage $name
    $fragmentOptions = @{}; $moduleOptions = @{}
    if ($FragmentRoot) { $fragmentOptions.FragmentRoot = $FragmentRoot }
    if ($ModuleRoot) { $moduleOptions.ModuleRoot = $ModuleRoot }
    & (Join-Path $source 'Install.ps1') @fragmentOptions
    & (Join-Path $source 'Install-Prompt.ps1') @moduleOptions
} finally {
    [Net.ServicePointManager]::SecurityProtocol = $previousTls
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
