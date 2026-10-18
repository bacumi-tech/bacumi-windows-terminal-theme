# MIT License · Copyright (c) 2026 Bacumi
# Adds a native JSON fragment; never opens or rewrites settings.json.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $FragmentRoot,
    [switch] $Uninstall
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $FragmentRoot) {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable. Use -FragmentRoot with an explicit directory.' }
    $FragmentRoot = Join-Path $env:LOCALAPPDATA 'Microsoft/Windows Terminal/Fragments'
}
$destination = Join-Path $FragmentRoot 'Bacumi'
$target = Join-Path $destination 'bacumi.json'
$marker = Join-Path $destination '.bacumi-installed'
$source = Join-Path $PSScriptRoot 'fragments/bacumi.json'

function Assert-NotLinked([string] $Path) {
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing linked installation path: $Path" }
    }
}

Assert-NotLinked $destination
Assert-NotLinked $target
Assert-NotLinked $marker
if (Test-Path -LiteralPath $destination) {
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw "Folder is not owned by this installer: $destination" }
    $owner = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    if ($owner.identity -ne 'bacumi-windows-terminal-theme' -or -not (Test-Path -LiteralPath $target -PathType Leaf)) {
        throw 'Invalid or incomplete Bacumi installation. Back it up before replacing it.'
    }
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $owner.sha256) {
        throw 'Bacumi files were modified locally. Back up or move the installation before replacing it.'
    }
} elseif ($Uninstall) {
    Write-Host 'Bacumi is already uninstalled.'
    return
}

if ($Uninstall) {
    if ($PSCmdlet.ShouldProcess($destination, 'Remove only the installed Bacumi fragment and ownership marker')) {
        Remove-Item -LiteralPath $target
        Remove-Item -LiteralPath $marker -Force
        if (@(Get-ChildItem -LiteralPath $destination -Force).Count -eq 0) { Remove-Item -LiteralPath $destination }
        Write-Host 'Bacumi removed. Select another color scheme if a profile still references Bacumi Dark or Light.'
    }
} else {
    $payload = Get-Content -LiteralPath $source -Raw | ConvertFrom-Json
    if ($payload.schemes.Count -ne 2 -or $payload.schemes[0].name -ne 'Bacumi Dark' -or $payload.schemes[1].name -ne 'Bacumi Light') {
        throw 'This release does not contain the expected Bacumi schemes.'
    }
    if ($PSCmdlet.ShouldProcess($destination, 'Install or update Bacumi Dark and Light')) {
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
        $owner = @{ identity = 'bacumi-windows-terminal-theme'; sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash }
        [IO.File]::WriteAllText($marker, ($owner | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
        Write-Host "Installed Dark and Light into $destination"
        Write-Host 'Reopen Windows Terminal, then choose Bacumi Dark or Bacumi Light under Settings > your profile > Appearance > Color scheme.'
    }
}
