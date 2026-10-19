# MIT License - Copyright (c) 2026 Bacumi
# Per-user module installation. Never reads or changes a PowerShell profile.
[CmdletBinding(SupportsShouldProcess = $true)]
param([string] $ModuleRoot, [switch] $Uninstall)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $ModuleRoot) {
    $userHome = [Environment]::GetFolderPath('UserProfile')
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $documents = [Environment]::GetFolderPath('MyDocuments')
        if (-not $documents) { throw 'Documents is unavailable. Specify -ModuleRoot.' }
        $edition = if ($PSVersionTable.PSVersion.Major -ge 6) { 'PowerShell' } else { 'WindowsPowerShell' }
        $ModuleRoot = Join-Path $documents ($edition + '/Modules')
    } else {
        $dataRoot = if ($env:XDG_DATA_HOME -and [IO.Path]::IsPathRooted($env:XDG_DATA_HOME)) { $env:XDG_DATA_HOME } else { Join-Path $userHome '.local/share' }
        $ModuleRoot = Join-Path $dataRoot 'powershell/Modules'
    }
}
$ModuleRoot = [IO.Path]::GetFullPath($ModuleRoot)
$destination = Join-Path $ModuleRoot 'BacumiPrompt'
$marker = Join-Path $destination '.bacumi-prompt-installed.json'
$sourceNames = @('BacumiPrompt.psd1', 'BacumiPrompt.psm1', 'NativeProbe.cs')
$assemblyName = 'BacumiPrompt.NativeProbe.net' + [Environment]::Version.Major + '.dll'
$installNames = $sourceNames + $assemblyName
$names = $installNames
$source = Join-Path $PSScriptRoot 'prompt'
function Assert-NotLinked([string] $Path) {
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing linked installation path: $cursor" }
        }
        if ($cursor -eq $ModuleRoot) { break }
        $parent = [IO.Directory]::GetParent($cursor)
        $cursor = if ($parent) { $parent.FullName } else { $null }
    }
}
Assert-NotLinked $destination
Assert-NotLinked $marker
$oldFiles = @()
if (Test-Path -LiteralPath $destination) {
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw "Folder is not owned by this installer: $destination" }
    $receipt = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    if ($receipt.identity -ne 'bacumi-native-powershell-prompt' -or $receipt.schema -ne 1) { throw 'Invalid prompt installation receipt.' }
    $oldFiles = @($receipt.files.PSObject.Properties)
    if ($oldFiles.Count -eq 0) { throw 'Empty prompt installation receipt.' }
    foreach ($file in $oldFiles) {
        if (($file.Name -notin $sourceNames -and $file.Name -notmatch '^BacumiPrompt\.NativeProbe\.net[1-9][0-9]*\.dll$') -or $file.Value -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid owned filename or checksum in prompt receipt.' }
        $target = Join-Path $destination $file.Name
        Assert-NotLinked $target
        if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $file.Value) {
            throw "Prompt file missing or modified locally: $target. Back it up or move the installation before replacing it."
        }
    }
    $names = @($installNames + @($oldFiles.Name) | Select-Object -Unique)
    foreach ($name in $names) {
        $target = Join-Path $destination $name
        Assert-NotLinked $target
        if ((Test-Path -LiteralPath $target) -and $name -notin @($oldFiles.Name)) { throw "Refusing to overwrite an unowned file: $target" }
    }
} elseif ($Uninstall) { Write-Host 'Bacumi prompt is already uninstalled.'; return }
if ($Uninstall) {
    if ($PSCmdlet.ShouldProcess($destination, 'Remove verified Bacumi prompt files and receipt')) {
        foreach ($file in $oldFiles) { Remove-Item -LiteralPath (Join-Path $destination $file.Name) }
        Remove-Item -LiteralPath $marker -Force
        if (@(Get-ChildItem -LiteralPath $destination -Force).Count -eq 0) { Remove-Item -LiteralPath $destination }
        Write-Host 'Bacumi prompt removed. Run Disable-BacumiPrompt in active sessions and remove any import/activation lines you added to your profile.'
    }
    return
}
$hashes = [ordered]@{}
foreach ($name in $sourceNames) {
    $payload = Join-Path $source $name
    if (-not (Test-Path -LiteralPath $payload -PathType Leaf)) { throw "Release is missing prompt file: $name" }
    $hashes[$name] = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash
}
$null = Test-ModuleManifest (Join-Path $source 'BacumiPrompt.psd1')
if ($PSCmdlet.ShouldProcess($destination, 'Install or update native Bacumi PowerShell prompt')) {
    # Stage all payloads before changing an existing installation.
    New-Item -ItemType Directory -Path $ModuleRoot -Force | Out-Null
    $staging = Join-Path $ModuleRoot ('.bacumi-prompt-stage-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging | Out-Null
    $backup = @{}; $oldMarker = $null; $created = -not (Test-Path -LiteralPath $destination)
    try {
        foreach ($name in $sourceNames) { Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $staging $name) }
        # A fresh compiler process also works when this shell has already loaded the type.
        $escapedSource = (Join-Path $staging 'NativeProbe.cs').Replace("'", "''")
        $escapedAssembly = (Join-Path $staging $assemblyName).Replace("'", "''")
        $compile = "Add-Type -LiteralPath '$escapedSource' -OutputAssembly '$escapedAssembly' -OutputType Library -ErrorAction Stop"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($compile))
        & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $staging $assemblyName) -PathType Leaf)) { throw 'Native prompt helper compilation failed; installation was not changed.' }
        $hashes[$assemblyName] = (Get-FileHash -LiteralPath (Join-Path $staging $assemblyName) -Algorithm SHA256).Hash
        $newReceipt = @{ identity = 'bacumi-native-powershell-prompt'; schema = 1; files = $hashes }
        [IO.File]::WriteAllText((Join-Path $staging '.bacumi-prompt-installed.json'), ($newReceipt | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
        if (-not $created) {
            $oldMarker = [IO.File]::ReadAllBytes($marker)
            foreach ($name in $names) { $file = Join-Path $destination $name; if (Test-Path -LiteralPath $file) { $backup[$name] = [IO.File]::ReadAllBytes($file) } }
        }
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        try {
            foreach ($name in $installNames) { Copy-Item -LiteralPath (Join-Path $staging $name) -Destination (Join-Path $destination $name) -Force }
            foreach ($name in $names) { if ($name -notin $installNames) { Remove-Item -LiteralPath (Join-Path $destination $name) -Force } }
            Copy-Item -LiteralPath (Join-Path $staging '.bacumi-prompt-installed.json') -Destination $marker -Force
        } catch {
            foreach ($name in $names) {
                $file = Join-Path $destination $name
                if ($backup.ContainsKey($name)) { [IO.File]::WriteAllBytes($file, $backup[$name]) }
                elseif (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
            }
            if ($oldMarker) { [IO.File]::WriteAllBytes($marker, $oldMarker) }
            elseif (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
            if ($created -and @(Get-ChildItem -LiteralPath $destination -Force).Count -eq 0) { Remove-Item -LiteralPath $destination }
            throw
        }
    } finally { if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force } }
    $escapedManifest = (Join-Path $destination 'BacumiPrompt.psd1').Replace("'", "''")
    Write-Host "Installed into $destination"
    Write-Host 'Add these lines to your profile manually, or run them now:'
    Write-Host "Import-Module '$escapedManifest'"
    Write-Host 'Enable-BacumiPrompt -Appearance Dark'
    Write-Host 'Use -Appearance Light for Bacumi Light; -Layout Compact for one line. Disable-BacumiPrompt restores the previous session prompt.'
}
