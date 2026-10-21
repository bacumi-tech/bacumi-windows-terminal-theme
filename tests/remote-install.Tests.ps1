# Download fixtures are local; installers only write markers inside this sandbox.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$installer = Join-Path $PSScriptRoot '../Install-Remote.ps1'
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('bacumi-remote-test-' + [guid]::NewGuid().ToString('N'))
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
try {
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    $version = (Get-Content (Join-Path $PSScriptRoot '../VERSION') -Raw).Trim()
    Assert ((Get-Content $installer -Raw).Contains("`$version = '$version'")) 'Bootstrap must match release VERSION'
    $name = "bacumi-windows-terminal-theme-$version"
    $payload = Join-Path $sandbox $name
    New-Item -ItemType Directory -Path $payload | Out-Null
    [IO.File]::WriteAllText((Join-Path $payload 'Install.ps1'), 'param($FragmentRoot) [IO.File]::WriteAllText((Join-Path $FragmentRoot ''fragment''), ''installed'')')
    [IO.File]::WriteAllText((Join-Path $payload 'Install-Prompt.ps1'), 'param($ModuleRoot) [IO.File]::WriteAllText((Join-Path $ModuleRoot ''prompt''), ''installed'')')
    $archive = Join-Path $sandbox "$name.zip"
    Compress-Archive -LiteralPath $payload -DestinationPath $archive
    $checksum = (Get-FileHash $archive -Algorithm SHA256).Hash + "  $name.zip"
    [IO.File]::WriteAllText((Join-Path $sandbox 'SHA256SUMS'), $checksum)
    function Invoke-WebRequest {
        param([switch] $UseBasicParsing, [string] $Uri, [string] $OutFile)
        if ($downloadFailure) { throw 'Fixture download failed' }
        Copy-Item -LiteralPath (Join-Path $sandbox ($Uri.Split('/')[-1])) -Destination $OutFile
    }
    $downloadFailure = $false
    $tls = [Net.ServicePointManager]::SecurityProtocol
    & $installer -FragmentRoot $sandbox -ModuleRoot $sandbox
    & $installer -FragmentRoot $sandbox -ModuleRoot $sandbox
    Assert ((Get-Content (Join-Path $sandbox 'fragment') -Raw) -eq 'installed') 'Schemes not installed'
    Assert ((Get-Content (Join-Path $sandbox 'prompt') -Raw) -eq 'installed') 'Prompt not installed'
    Assert ([Net.ServicePointManager]::SecurityProtocol -eq $tls) 'TLS settings not restored'
    Remove-Item (Join-Path $sandbox 'fragment'), (Join-Path $sandbox 'prompt')
    [IO.File]::WriteAllText($archive, 'corrupt archive')
    foreach ($failure in @($false, $true)) {
        $downloadFailure = $failure
        $refused = $false
        try { & $installer -FragmentRoot $sandbox -ModuleRoot $sandbox } catch { $refused = $true }
        Assert $refused 'Corrupt or unavailable downloads must fail'
        Assert (-not (Test-Path (Join-Path $sandbox 'fragment'))) 'Installer ran before verification'
        Assert (-not (Test-Path (Join-Path $sandbox 'prompt'))) 'Prompt installer ran before verification'
    }
    Write-Host 'Remote installation checks passed: install, update, checksum refusal, download failure and TLS restoration.'
} finally {
    Remove-Item Function:Invoke-WebRequest -ErrorAction SilentlyContinue
    if (Test-Path $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}
