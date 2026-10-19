# Standalone ownership integration checks; no Pester required.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$installer = Join-Path $PSScriptRoot '../Install-Prompt.ps1'
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("bacumi-prompt-test %PATH% ! & '-" + [guid]::NewGuid().ToString('N'))
try {
    $root = Join-Path $sandbox 'modules with spaces'
    & $installer -ModuleRoot $root -WhatIf
    Assert (-not (Test-Path -LiteralPath $root)) 'WhatIf created directories'
    & $installer -ModuleRoot $root
    $destination = Join-Path $root 'BacumiPrompt'
    $moduleFile = Join-Path $destination 'BacumiPrompt.psm1'
    $assembly = Join-Path $destination ('BacumiPrompt.NativeProbe.net' + [Environment]::Version.Major + '.dll')
    Assert (Test-Path -LiteralPath $moduleFile) 'Module must be installed'
    Assert (Test-Path -LiteralPath $assembly) 'Native helper must be compiled during installation'
    $manifest = Test-ModuleManifest (Join-Path $destination 'BacumiPrompt.psd1')
    Assert ($manifest.Name -eq 'BacumiPrompt') 'Installed module manifest invalid'
    $startup = Join-Path $sandbox 'startup.ps1'
    [IO.File]::WriteAllText($startup, @'
param($Manifest, $Assembly)
$ErrorActionPreference = 'Stop'
function Add-Type { throw 'Installed module must not compile during startup' }
Import-Module $Manifest -Force
Enable-BacumiPrompt -GitMode Off -ColorMode Plain
$null = prompt
$exclusive = [IO.File]::Open($Assembly, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$exclusive.Dispose()
$module = Get-Module BacumiPrompt
$git = (Get-Command git -CommandType Application | Select-Object -First 1).Source
$result = & $module { param($g, $d) Invoke-BacumiProbe $g @('--version') $d } $git (Split-Path $Manifest)
if (-not $result.Success -or $result.Output -notmatch 'git version') { throw 'Installed native helper failed a real Git probe' }
Disable-BacumiPrompt
'@)
    & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -File $startup (Join-Path $destination 'BacumiPrompt.psd1') $assembly
    Assert ($LASTEXITCODE -eq 0) 'Fresh installed startup must use the unlocked compiled helper and run Git'
    $oldAssembly = Join-Path $destination 'BacumiPrompt.NativeProbe.net999.dll'
    [IO.File]::WriteAllText($oldAssembly, 'old runtime helper')
    $receiptPath = Join-Path $destination '.bacumi-prompt-installed.json'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    $receipt.files | Add-Member -NotePropertyName 'BacumiPrompt.NativeProbe.net999.dll' -NotePropertyValue (Get-FileHash -LiteralPath $oldAssembly).Hash
    [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 4))
    & $installer -ModuleRoot $root
    Assert (-not (Test-Path -LiteralPath $oldAssembly)) 'Updating the helper must remove installer-owned binaries for older runtimes'
    $beforeFailure = (Get-FileHash -LiteralPath $assembly).Hash
    $badRelease = Join-Path $sandbox 'broken release'
    New-Item -ItemType Directory -Path (Join-Path $badRelease 'prompt') -Force | Out-Null
    Copy-Item -LiteralPath $installer -Destination (Join-Path $badRelease 'Install-Prompt.ps1')
    foreach ($file in @('BacumiPrompt.psd1', 'BacumiPrompt.psm1', 'NativeProbe.cs')) {
        Copy-Item -LiteralPath (Join-Path (Split-Path $installer) ('prompt/' + $file)) -Destination (Join-Path $badRelease ('prompt/' + $file))
    }
    [IO.File]::WriteAllText((Join-Path $badRelease 'prompt/NativeProbe.cs'), 'this is not valid C#')
    $refused = $false
    try { & (Join-Path $badRelease 'Install-Prompt.ps1') -ModuleRoot $root 2>$null } catch { $refused = $true }
    Assert $refused 'Compilation failure must abort installation'
    Assert ((Get-FileHash -LiteralPath $assembly).Hash -eq $beforeFailure) 'Compilation failure changed the working helper'
    $keep = Join-Path $destination 'personal.txt'
    [IO.File]::WriteAllText($keep, 'keep')
    & $installer -ModuleRoot $root -Uninstall -WhatIf
    Assert (Test-Path -LiteralPath $moduleFile) 'Uninstall WhatIf changed files'
    & $installer -ModuleRoot $root -Uninstall
    Assert (-not (Test-Path -LiteralPath $moduleFile)) 'Uninstall retained owned module'
    Assert ((Get-Content -LiteralPath $keep -Raw) -eq 'keep') 'Uninstall removed unrelated file'
    Remove-Item -LiteralPath $keep
    Remove-Item -LiteralPath $destination
    # Schema-1 receipts from before compiled helpers owned only the two module files.
    New-Item -ItemType Directory -Path $destination | Out-Null
    $legacyHashes = @{}
    foreach ($file in @('BacumiPrompt.psd1', 'BacumiPrompt.psm1')) {
        $target = Join-Path $destination $file
        [IO.File]::WriteAllText($target, '# legacy installation')
        $legacyHashes[$file] = (Get-FileHash -LiteralPath $target).Hash
    }
    [IO.File]::WriteAllText((Join-Path $destination '.bacumi-prompt-installed.json'), (@{ identity = 'bacumi-native-powershell-prompt'; schema = 1; files = $legacyHashes } | ConvertTo-Json))
    & $installer -ModuleRoot $root
    Assert (Test-Path -LiteralPath $assembly) 'Legacy installation must gain its compiled helper'
    foreach ($editedFile in @($moduleFile, $assembly, (Join-Path $destination 'NativeProbe.cs'))) {
        $original = [IO.File]::ReadAllBytes($editedFile)
        [IO.File]::AppendAllText($editedFile, '# local edit')
        $editedHash = (Get-FileHash -LiteralPath $editedFile).Hash
        foreach ($uninstall in @($false, $true)) {
            $refused = $false
            try { & $installer -ModuleRoot $root -Uninstall:$uninstall } catch { $refused = $true }
            Assert $refused 'Local edits must be protected on update and uninstall'
            Assert ((Get-FileHash -LiteralPath $editedFile).Hash -eq $editedHash) 'Local edit changed'
        }
        [IO.File]::WriteAllBytes($editedFile, $original)
    }
    $unowned = Join-Path $sandbox 'unowned'
    New-Item -ItemType Directory -Path (Join-Path $unowned 'BacumiPrompt') | Out-Null
    $refused = $false
    try { & $installer -ModuleRoot $unowned } catch { $refused = $true }
    Assert $refused 'Unowned installation was claimed'
    Write-Host 'Prompt installer checks passed: WhatIf, repeat/update, ownership, edits, removal, custom paths.'
} finally { if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force } }
