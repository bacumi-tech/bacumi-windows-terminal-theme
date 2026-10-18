# Standalone ownership integration checks; no Pester required.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$installer = Join-Path $PSScriptRoot '../Install-Prompt.ps1'
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('bacumi-prompt-test-' + [guid]::NewGuid().ToString('N'))
try {
    $root = Join-Path $sandbox 'modules with spaces'
    & $installer -ModuleRoot $root -WhatIf
    Assert (-not (Test-Path -LiteralPath $root)) 'WhatIf created directories'
    & $installer -ModuleRoot $root
    $destination = Join-Path $root 'BacumiPrompt'
    $moduleFile = Join-Path $destination 'BacumiPrompt.psm1'
    Assert (Test-Path -LiteralPath $moduleFile) 'Module must be installed'
    $manifest = Test-ModuleManifest (Join-Path $destination 'BacumiPrompt.psd1')
    Assert ($manifest.Name -eq 'BacumiPrompt') 'Installed module manifest invalid'
    & $installer -ModuleRoot $root
    $keep = Join-Path $destination 'personal.txt'
    [IO.File]::WriteAllText($keep, 'keep')
    & $installer -ModuleRoot $root -Uninstall -WhatIf
    Assert (Test-Path -LiteralPath $moduleFile) 'Uninstall WhatIf changed files'
    & $installer -ModuleRoot $root -Uninstall
    Assert (-not (Test-Path -LiteralPath $moduleFile)) 'Uninstall retained owned module'
    Assert ((Get-Content -LiteralPath $keep -Raw) -eq 'keep') 'Uninstall removed unrelated file'
    Remove-Item -LiteralPath $keep
    Remove-Item -LiteralPath $destination
    & $installer -ModuleRoot $root
    [IO.File]::AppendAllText($moduleFile, '# local edit')
    foreach ($uninstall in @($false, $true)) {
        $refused = $false
        try { & $installer -ModuleRoot $root -Uninstall:$uninstall } catch { $refused = $true }
        Assert $refused 'Local edits must be protected on update and uninstall'
        Assert ((Get-Content -LiteralPath $moduleFile -Raw).EndsWith('# local edit')) 'Local edit changed'
    }
    $unowned = Join-Path $sandbox 'unowned'
    New-Item -ItemType Directory -Path (Join-Path $unowned 'BacumiPrompt') | Out-Null
    $refused = $false
    try { & $installer -ModuleRoot $unowned } catch { $refused = $true }
    Assert $refused 'Unowned installation was claimed'
    Write-Host 'Prompt installer checks passed: WhatIf, repeat/update, ownership, edits, removal, custom paths.'
} finally { if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force } }
