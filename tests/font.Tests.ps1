# Standalone optional font checks, including native per-user registration on Windows.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$installer = Join-Path $PSScriptRoot '../Install-Font.ps1'
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('bacumi-font-test-' + [Guid]::NewGuid().ToString('N'))
$isNativeWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$registry = 'HKCU:\Software\BacumiFontTests\' + [Guid]::NewGuid().ToString('N')
$names = @('MesloLGS NF Regular.ttf', 'MesloLGS NF Bold.ttf', 'MesloLGS NF Italic.ttf', 'MesloLGS NF Bold Italic.ttf')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Assert-Refused([scriptblock] $Action, [string] $Message) {
    $refused = $false
    try { & $Action } catch { $refused = $true }
    Assert $refused $Message
}
try {
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    $source = Join-Path $sandbox 'fixture source'
    New-Item -ItemType Directory -Path $source | Out-Null
    $manifest = Join-Path $sandbox 'fonts.tsv'
    $rows = @()
    foreach ($name in $names) {
        $file = Join-Path $source $name
        [IO.File]::WriteAllText($file, ('controlled font fixture ' + $name))
        $rows += (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash + "`t" + $name + "`thttps://example.invalid/immutable/" + [Uri]::EscapeDataString($name)
    }
    [IO.File]::WriteAllLines($manifest, $rows)
    $dest = Join-Path $sandbox 'fonts with spaces'
    $options = @{FontDirectory = $dest; ManifestPath = $manifest; SourceDirectory = $source; RegistrationPath = $registry}
    if (-not $isNativeWindows) { $options.SkipRegistration = $true }
    & $installer @options -WhatIf
    Assert (-not (Test-Path -LiteralPath $dest)) 'WhatIf changed the destination'
    Assert (-not (Test-Path -LiteralPath $registry)) 'WhatIf created registration'
    # Inject a copy failure after earlier fonts have been copied; the transaction must roll back.
    $global:BacumiFontFailureTarget = Join-Path $dest $names[2]
    $global:BacumiFontFailureFired = $false
    function global:Copy-Item {
        [CmdletBinding()] param([string] $LiteralPath, [string] $Destination, [switch] $Force)
        if ($Destination -eq $global:BacumiFontFailureTarget -and -not $global:BacumiFontFailureFired) {
            $global:BacumiFontFailureFired = $true
            throw 'Controlled installation copy failure'
        }
        Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
    }
    try { Assert-Refused { & $installer @options } 'Injected copy failure was not reported' }
    finally { Remove-Item -LiteralPath Function:\Copy-Item; Remove-Variable BacumiFontFailureTarget, BacumiFontFailureFired -Scope Global }
    Assert (-not (Test-Path -LiteralPath $dest)) 'Copy failure left a partial font installation'
    Assert (-not (Test-Path -LiteralPath $registry)) 'Copy failure left a registration key'
    if ($isNativeWindows) {
        $global:BacumiRegistrationFailureFired = $false
        function global:New-ItemProperty {
            [CmdletBinding()] param([string] $LiteralPath, [string] $Name, $Value, [string] $PropertyType, [switch] $Force)
            if ($Name -eq 'MesloLGS NF Bold (TrueType)' -and -not $global:BacumiRegistrationFailureFired) {
                $global:BacumiRegistrationFailureFired = $true
                throw 'Controlled registration failure'
            }
            Microsoft.PowerShell.Management\New-ItemProperty @PSBoundParameters
        }
        try { Assert-Refused { & $installer @options } 'Injected registration failure was not reported' }
        finally { Remove-Item -LiteralPath Function:\New-ItemProperty; Remove-Variable BacumiRegistrationFailureFired -Scope Global }
        Assert (-not (Test-Path -LiteralPath $dest)) 'Registration failure left a partial font installation'
        Assert (-not (Test-Path -LiteralPath $registry)) 'Registration failure left partial registry values'
    }
    & $installer @options
    foreach ($name in $names) { Assert (Test-Path -LiteralPath (Join-Path $dest $name)) "Missing font $name" }
    $receipt = Join-Path $dest '.bacumi-meslolgs-nf/receipt.json'
    Assert (Test-Path -LiteralPath $receipt) 'Missing separate font receipt'
    Assert (Test-Path -LiteralPath (Join-Path $dest '.bacumi-meslolgs-nf/LICENSE-MesloLGS-NF.txt')) 'Missing retained font license'
    if ($isNativeWindows) {
        foreach ($name in $names) {
            $label = [IO.Path]::GetFileNameWithoutExtension($name) + ' (TrueType)'
            Assert ((Get-ItemPropertyValue -LiteralPath $registry -Name $label) -eq (Join-Path $dest $name)) 'Incorrect native font registration'
        }
    }
    $before = [IO.File]::ReadAllText($receipt)
    & $installer @options
    Assert ([IO.File]::ReadAllText($receipt) -eq $before) 'Repeat installation changed ownership'
    $keep = Join-Path $dest 'unrelated.ttf'
    [IO.File]::WriteAllText($keep, 'personal')
    & $installer @options -Uninstall -WhatIf
    Assert (Test-Path -LiteralPath $receipt) 'WhatIf uninstall changed ownership'
    & $installer @options -Uninstall
    Assert (-not (Test-Path -LiteralPath (Join-Path $dest $names[0]))) 'Owned font was not removed'
    Assert ([IO.File]::ReadAllText($keep) -eq 'personal') 'Unrelated font was removed'
    & $installer @options -Uninstall
    # An existing matching third-party font must remain unowned.
    Copy-Item -LiteralPath (Join-Path $source $names[0]) -Destination (Join-Path $dest $names[0])
    & $installer @options
    $owner = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    Assert (-not (@($owner.files | ForEach-Object { $_.name }) -contains $names[0])) 'Preexisting matching font was claimed'
    & $installer @options -Uninstall
    Assert (Test-Path -LiteralPath (Join-Path $dest $names[0])) 'Preexisting matching font was removed'
    Remove-Item -LiteralPath (Join-Path $dest $names[0])
    # All fixture hashes are verified before any destination mutation.
    [IO.File]::WriteAllText((Join-Path $source $names[3]), 'corrupt')
    Assert-Refused { & $installer @options } 'Corrupt download must fail'
    Assert (-not (Test-Path -LiteralPath (Join-Path $dest $names[0]))) 'Checksum failure installed a partial set'
    [IO.File]::WriteAllText((Join-Path $source $names[3]), ('controlled font fixture ' + $names[3]))
    Move-Item -LiteralPath (Join-Path $source $names[3]) -Destination (Join-Path $source 'missing.ttf')
    Assert-Refused { & $installer @options } 'Partial download must fail'
    Assert (-not (Test-Path -LiteralPath $receipt)) 'Partial download created ownership'
    Move-Item -LiteralPath (Join-Path $source 'missing.ttf') -Destination (Join-Path $source $names[3])
    # Strict manifest filenames and URL schemes.
    $bad = Join-Path $sandbox 'bad.tsv'
    [IO.File]::WriteAllLines($bad, @($rows | ForEach-Object { $_.Replace('https://', 'http://') }))
    $badOptions = $options.Clone(); $badOptions.ManifestPath = $bad
    Assert-Refused { & $installer @badOptions } 'HTTP manifest URL accepted'
    [IO.File]::WriteAllLines($bad, @($rows | ForEach-Object { $_.Replace('MesloLGS NF Regular.ttf', '../escaped.ttf') }))
    Assert-Refused { & $installer @badOptions } 'Unexpected font filename accepted'
    & $installer @options
    $font = Join-Path $dest $names[0]
    [IO.File]::WriteAllText($font, 'local change')
    Assert-Refused { & $installer @options } 'Update overwrote local font'
    Assert-Refused { & $installer @options -Uninstall } 'Uninstall removed local font'
    Assert ([IO.File]::ReadAllText($font) -eq 'local change') 'Modified font did not survive'
    Copy-Item -LiteralPath (Join-Path $source $names[0]) -Destination $font -Force
    if ($isNativeWindows) {
        $label = 'MesloLGS NF Regular (TrueType)'
        Set-ItemProperty -LiteralPath $registry -Name $label -Value 'personal.ttf'
        Assert-Refused { & $installer @options } 'Update overwrote local registration'
        Assert-Refused { & $installer @options -Uninstall } 'Uninstall removed local registration'
        Assert ((Get-ItemPropertyValue -LiteralPath $registry -Name $label) -eq 'personal.ttf') 'Modified registration did not survive'
        Set-ItemProperty -LiteralPath $registry -Name $label -Value $font
    }
    & $installer @options -Uninstall
    if ($isNativeWindows) {
        # Existing registration values, including matching values, are never claimed.
        $label = 'MesloLGS NF Regular (TrueType)'
        Set-ItemProperty -LiteralPath $registry -Name $label -Value 'third-party.ttf'
        Assert-Refused { & $installer @options } 'Conflicting third-party registration was replaced'
        Assert (-not (Test-Path -LiteralPath $font)) 'Registration conflict partially installed fonts'
        Set-ItemProperty -LiteralPath $registry -Name $label -Value $font
        & $installer @options
        & $installer @options -Uninstall
        Assert ((Get-ItemPropertyValue -LiteralPath $registry -Name $label) -eq $font) 'Preexisting matching registration was removed'
        Remove-ItemProperty -LiteralPath $registry -Name $label
    }
    # A complete matching third-party installation needs no receipt or ownership.
    foreach ($name in $names) { Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $dest $name) }
    & $installer @options
    Assert (-not (Test-Path -LiteralPath $receipt)) 'Complete third-party font installation was claimed'
    & $installer @options -Uninstall
    foreach ($name in $names) { Assert (Test-Path -LiteralPath (Join-Path $dest $name)) 'Third-party font was removed'; Remove-Item -LiteralPath (Join-Path $dest $name) }
    # An unowned conflicting font is preserved without registering a partial set.
    [IO.File]::WriteAllText($font, 'someone else')
    Assert-Refused { & $installer @options } 'Conflicting third-party font was overwritten'
    Assert ([IO.File]::ReadAllText($font) -eq 'someone else') 'Conflicting font changed'
    Write-Host 'Optional font checks passed: hashes, partial sources, manifests, WhatIf, repeat install, ownership, local edits and uninstall.'
    if ($isNativeWindows) { Write-Host 'Native Windows temporary HKCU registration checks passed.' }
    else { Write-Host 'Registration skipped explicitly outside Windows; native registration remains a Windows CI check.' }
} finally {
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
    if ($isNativeWindows -and (Test-Path -LiteralPath $registry)) { Remove-Item -LiteralPath $registry -Recurse -Force }
}
