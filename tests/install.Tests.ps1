# Standalone native integration checks: no Pester or package manager required.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$installer = Join-Path $PSScriptRoot '../Install.ps1'
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('bacumi-test-' + [Guid]::NewGuid().ToString('N'))
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
try {
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    $root = Join-Path $sandbox 'fragments with spaces'
    & $installer -FragmentRoot $root -WhatIf
    Assert (-not (Test-Path $root)) 'WhatIf must not create directories'
    & $installer -FragmentRoot $root
    $destination = Join-Path $root 'Bacumi'
    $file = Join-Path $destination 'bacumi.json'
    $fragment = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    Assert ($fragment.schemes.Count -eq 2) 'Both schemes must be installed'
    Assert ($fragment.schemes[0].name -eq 'Bacumi Dark') 'Dark must be available'
    Assert ($fragment.schemes[1].name -eq 'Bacumi Light') 'Light must be available'
    & $installer -FragmentRoot $root
    $keep = Join-Path $destination 'personal.txt'
    [IO.File]::WriteAllText($keep, 'keep')
    & $installer -FragmentRoot $root -Uninstall
    Assert (-not (Test-Path $file)) 'Uninstall must remove its scheme'
    Assert ((Get-Content -LiteralPath $keep -Raw) -eq 'keep') 'Uninstall must preserve unrelated files'
    Remove-Item -LiteralPath $keep
    Remove-Item -LiteralPath $destination
    & $installer -FragmentRoot $root
    [IO.File]::WriteAllText($file, '{"local":"edit"}')
    foreach ($uninstall in @($false, $true)) {
        $refused = $false
        try { & $installer -FragmentRoot $root -Uninstall:$uninstall } catch { $refused = $true }
        Assert $refused 'Local edits must be protected on update and uninstall'
        Assert ((Get-Content -LiteralPath $file -Raw) -eq '{"local":"edit"}') 'Local edit was overwritten'
    }
    $unowned = Join-Path $sandbox 'unowned'
    New-Item -ItemType Directory -Path (Join-Path $unowned 'Bacumi') | Out-Null
    $refused = $false
    try { & $installer -FragmentRoot $unowned } catch { $refused = $true }
    Assert $refused 'An existing unowned folder must not be claimed'
    Write-Host 'Native installer checks passed: WhatIf, install, repeat install, uninstall, unrelated files and local edits.'
} finally {
    if (Test-Path $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}
