# MIT License · Copyright (c) 2026 Bacumi
# Optional, separately owned per-user MesloLGS NF installation. Never edits profiles.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $FontDirectory,
    [string] $RegistrationPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts',
    [string] $ManifestPath = (Join-Path $PSScriptRoot 'fonts/meslolgs-nf.tsv'),
    [string] $SourceDirectory,
    [switch] $SkipRegistration,
    [switch] $Uninstall
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$nativeWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$customDirectory = $PSBoundParameters.ContainsKey('FontDirectory') -and $FontDirectory
if ($SkipRegistration -and (-not $customDirectory -or $nativeWindows)) {
    throw '-SkipRegistration is only for non-Windows tests with an explicit -FontDirectory.'
}
if (-not $nativeWindows -and -not $SkipRegistration) { throw 'Font installation requires Windows. Non-Windows tests must explicitly use -SkipRegistration and a custom -FontDirectory.' }
if (-not $FontDirectory) {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable.' }
    $FontDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft/Windows/Fonts'
}
$FontDirectory = [IO.Path]::GetFullPath($FontDirectory)
if ($RegistrationPath -notmatch '^HKCU:\\[^\r\n]+$' -or $RegistrationPath.Contains('..')) { throw 'Use an explicit HKCU registry path for per-user registration.' }
$names = @('MesloLGS NF Regular.ttf', 'MesloLGS NF Bold.ttf', 'MesloLGS NF Italic.ttf', 'MesloLGS NF Bold Italic.ttf')
$noticeNames = @('LICENSE-MesloLGS-NF.txt', 'Apache-2.0.txt', 'NOTICE.txt')
$ownershipDirectory = Join-Path $FontDirectory '.bacumi-meslolgs-nf'
$receiptPath = Join-Path $ownershipDirectory 'receipt.json'
$identity = 'bacumi-meslolgs-nf-v1'
function Assert-NotLinked([string] $Path) {
    if (Test-Path -LiteralPath $Path) {
        if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing linked font path: $Path" }
    }
}
function Save-HttpsFont([string] $Url, [string] $Path) {
    $uri = [Uri]$Url
    for ($redirect = 0; $redirect -le 5; $redirect++) {
        if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Fragment) { throw 'Font download redirected outside HTTPS or included credentials/fragments.' }
        $request = [Net.WebRequest]::Create($uri)
        $request.AllowAutoRedirect = $false
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 30000
        $response = $null
        try {
            $response = $request.GetResponse()
            $status = [int]$response.StatusCode
            if (@(301, 302, 303, 307, 308) -contains $status) {
                $location = $response.Headers['Location']
                if (-not $location -or $redirect -eq 5) { throw 'Missing font redirect location or too many redirects.' }
                $uri = New-Object System.Uri -ArgumentList $uri, $location
                continue
            }
            if ($status -ne 200) { throw "Unexpected font download HTTP status: $status" }
            $inputStream = $response.GetResponseStream()
            $outputStream = [IO.File]::Create($Path)
            try { $inputStream.CopyTo($outputStream) }
            finally { $outputStream.Dispose(); $inputStream.Dispose() }
            return
        } finally { if ($null -ne $response) { $response.Close() } }
    }
}
function Get-Hash([string] $Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-Label([string] $Name) { [IO.Path]::GetFileNameWithoutExtension($Name) + ' (TrueType)' }
function Get-Registration([string] $Name) {
    if ($SkipRegistration -or -not (Test-Path -LiteralPath $RegistrationPath)) { return $null }
    $key = Get-Item -LiteralPath $RegistrationPath
    if ($key.GetValueNames() -ccontains $Name) {
        return @{ value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); kind = $key.GetValueKind($Name).ToString() }
    }
    return $null
}
Assert-NotLinked $FontDirectory
Assert-NotLinked $ownershipDirectory
Assert-NotLinked $receiptPath
foreach ($name in $names) { Assert-NotLinked (Join-Path $FontDirectory $name) }
foreach ($name in $noticeNames) { Assert-NotLinked (Join-Path $ownershipDirectory $name) }
$oldFiles = @(); $oldNotices = @(); $oldRegistrations = @()
if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
    $owner = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if ($owner.identity -ne $identity -or $owner.registrationPath -ne $RegistrationPath -or [bool]$owner.skipRegistration -ne [bool]$SkipRegistration) { throw 'Invalid font ownership receipt or different registration settings.' }
    $oldFiles = @($owner.files); $oldNotices = @($owner.notices); $oldRegistrations = @($owner.registrations)
    $seen = @{}
    foreach ($entry in $oldFiles) {
        if ($names -cnotcontains $entry.name -or $seen.ContainsKey($entry.name) -or $entry.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid font ownership receipt.' }
        $seen[$entry.name] = $true
        $path = Join-Path $FontDirectory $entry.name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Hash $path) -ne $entry.sha256) { throw "Owned font is missing or modified locally: $path" }
    }
    $seen = @{}
    foreach ($entry in $oldNotices) {
        if ($noticeNames -cnotcontains $entry.name -or $seen.ContainsKey($entry.name) -or $entry.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid font notice ownership receipt.' }
        $seen[$entry.name] = $true
        $path = Join-Path $ownershipDirectory $entry.name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Hash $path) -ne $entry.sha256) { throw "Owned font notice is missing or modified locally: $path" }
    }
    $seen = @{}
    foreach ($entry in $oldRegistrations) {
        $matching = @($names | Where-Object { (Get-Label $_) -ceq $entry.name })
        if ($matching.Count -ne 1 -or $seen.ContainsKey($entry.name) -or @($oldFiles | Where-Object { $_.name -ceq $matching[0] }).Count -ne 1 -or $entry.value -cne (Join-Path $FontDirectory $matching[0])) { throw 'Invalid font registration ownership receipt.' }
        $seen[$entry.name] = $true
        $current = Get-Registration $entry.name
        if ($null -eq $current -or $current.kind -ne 'String' -or $current.value -cne $entry.value) { throw "Font registration was modified locally: $($entry.name)" }
    }
} elseif (Test-Path -LiteralPath $ownershipDirectory) { throw "Font ownership directory already exists without a valid receipt: $ownershipDirectory" }
if ($Uninstall -and -not (Test-Path -LiteralPath $receiptPath)) { Write-Host 'No installer-owned MesloLGS NF fonts to remove.'; return }
$manifest = @()
if (-not $Uninstall) {
    $seen = @{}
    foreach ($line in [IO.File]::ReadAllLines([IO.Path]::GetFullPath($ManifestPath))) {
        $fields = $line.Split("`t")
        if ($fields.Count -ne 3 -or $fields[0] -notmatch '^[a-fA-F0-9]{64}$' -or $names -cnotcontains $fields[1] -or $seen.ContainsKey($fields[1])) { throw 'Font manifest must contain exactly four unique approved filenames, SHA-256 hashes and HTTPS URLs.' }
        $uri = $null
        if (-not [Uri]::TryCreate($fields[2], [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Fragment -or -not $uri.Host) { throw 'Font manifest URLs must be absolute HTTPS URLs without credentials or fragments.' }
        $seen[$fields[1]] = $true
        $manifest += @{ name = $fields[1]; sha256 = $fields[0].ToLowerInvariant(); url = $fields[2] }
    }
    if ($manifest.Count -ne 4) { throw 'Font manifest must list all four MesloLGS NF styles.' }
    foreach ($name in $noticeNames) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot ('fonts/' + $name)) -PathType Leaf)) { throw "Missing font license or notice: $name" }
    }
}
if (-not $PSCmdlet.ShouldProcess($FontDirectory, $(if ($Uninstall) { 'Remove verified installer-owned MesloLGS NF files and registrations' } else { 'Verify and install optional MesloLGS NF fonts for this user' }))) { return }
$staging = Join-Path ([IO.Path]::GetTempPath()) ('bacumi-font-' + [Guid]::NewGuid().ToString('N'))
$fileChanges = @(); $registryChanges = @(); $madeDirectories = @(); $madeRegistry = $false
try {
    New-Item -ItemType Directory -Path $staging | Out-Null
    $newFiles = @(); $newRegistrations = @(); $newNotices = @()
    if (-not $Uninstall) {
        # Download and verify the complete set before changing any installed files or values.
        $previousTls = [Net.ServicePointManager]::SecurityProtocol
        try {
            [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
            foreach ($entry in $manifest) {
                $staged = Join-Path $staging $entry.name
                if ($SourceDirectory) { Copy-Item -LiteralPath (Join-Path $SourceDirectory $entry.name) -Destination $staged }
                else { Save-HttpsFont $entry.url $staged }
                if ((Get-Hash $staged) -ne $entry.sha256) { throw "SHA-256 mismatch for $($entry.name). Installed fonts were not changed." }
            }
        } finally { [Net.ServicePointManager]::SecurityProtocol = $previousTls }
        foreach ($entry in $manifest) {
            $path = Join-Path $FontDirectory $entry.name
            $wasOwned = @($oldFiles | Where-Object { $_.name -ceq $entry.name }).Count -eq 1
            if ((Test-Path -LiteralPath $path) -and -not $wasOwned) {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Hash $path) -ne $entry.sha256) { throw "Preserving an existing different font: $path" }
                Write-Host "Already present; leaving third-party font and registration unowned: $($entry.name). If unavailable in apps, register it using Windows font settings."
                continue
            }
            $newFiles += @{ name = $entry.name; sha256 = $entry.sha256 }
            if (-not $SkipRegistration) {
                $label = Get-Label $entry.name
                $current = Get-Registration $label
                $registeredByUs = @($oldRegistrations | Where-Object { $_.name -ceq $label }).Count -eq 1
                if ($null -ne $current -and ($current.kind -ne 'String' -or $current.value -cne $path)) { throw "Preserving an existing different font registration: $label" }
                if ($null -eq $current -or $registeredByUs) { $newRegistrations += @{ name = $label; value = $path } }
            }
        }
        if ($newFiles.Count -eq 0) { Write-Host 'All four matching fonts are already present; no ownership claimed. Existing third-party registration remains its owner''s responsibility.'; return }
        foreach ($name in $noticeNames) {
            $source = Join-Path $PSScriptRoot ('fonts/' + $name)
            $newNotices += @{ name = $name; sha256 = Get-Hash $source }
            $path = Join-Path $ownershipDirectory $name
            if ((Test-Path -LiteralPath $path) -and @($oldNotices | Where-Object { $_.name -ceq $name }).Count -ne 1) { throw "Preserving an unowned font notice: $path" }
        }
    }
    # Keep backups for every file changed, so a failed copy or registration rolls back the transaction.
    $targets = @($oldFiles | ForEach-Object { Join-Path $FontDirectory $_.name }) + @($oldNotices | ForEach-Object { Join-Path $ownershipDirectory $_.name }) + @($receiptPath)
    if (-not $Uninstall) { $targets += @($newFiles | ForEach-Object { Join-Path $FontDirectory $_.name }) + @($newNotices | ForEach-Object { Join-Path $ownershipDirectory $_.name }) }
    foreach ($path in @($targets | Select-Object -Unique)) {
        $backup = $null
        if (Test-Path -LiteralPath $path) { $backup = Join-Path $staging ([Guid]::NewGuid().ToString('N')); Copy-Item -LiteralPath $path -Destination $backup }
        $fileChanges += @{ path = $path; backup = $backup }
    }
    foreach ($entry in @($oldRegistrations) + @($newRegistrations)) {
        if (@($registryChanges | Where-Object { $_.name -ceq $entry.name }).Count -eq 0) { $registryChanges += @{ name = $entry.name; previous = Get-Registration $entry.name } }
    }
    if ($Uninstall) {
        foreach ($entry in $oldRegistrations) { Remove-ItemProperty -LiteralPath $RegistrationPath -Name $entry.name }
        foreach ($entry in $fileChanges) { if (Test-Path -LiteralPath $entry.path) { Remove-Item -LiteralPath $entry.path -Force } }
    } else {
        foreach ($path in @($FontDirectory, $ownershipDirectory)) {
            if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null; $madeDirectories += $path }
        }
        foreach ($entry in $newFiles) { Copy-Item -LiteralPath (Join-Path $staging $entry.name) -Destination (Join-Path $FontDirectory $entry.name) -Force }
        foreach ($entry in $newNotices) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('fonts/' + $entry.name)) -Destination (Join-Path $ownershipDirectory $entry.name) -Force }
        if ($newRegistrations.Count -gt 0 -and -not (Test-Path -LiteralPath $RegistrationPath)) { New-Item -Path $RegistrationPath -Force | Out-Null; $madeRegistry = $true }
        foreach ($entry in $newRegistrations) { New-ItemProperty -LiteralPath $RegistrationPath -Name $entry.name -Value $entry.value -PropertyType String -Force | Out-Null }
        $receipt = [ordered]@{ identity = $identity; registrationPath = $RegistrationPath; skipRegistration = [bool]$SkipRegistration; files = @($newFiles); notices = @($newNotices); registrations = @($newRegistrations) }
        [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    }
} catch {
    $failure = $_
    $rollbackErrors = @()
    foreach ($entry in $fileChanges) {
        try {
            if ($entry.backup) { Copy-Item -LiteralPath $entry.backup -Destination $entry.path -Force }
            elseif (Test-Path -LiteralPath $entry.path) { Remove-Item -LiteralPath $entry.path -Force }
        } catch { $rollbackErrors += $_.Exception.Message }
    }
    foreach ($entry in $registryChanges) {
        try {
            if ($null -ne $entry.previous) { New-ItemProperty -LiteralPath $RegistrationPath -Name $entry.name -Value $entry.previous.value -PropertyType $entry.previous.kind -Force | Out-Null }
            elseif (Test-Path -LiteralPath $RegistrationPath) { Remove-ItemProperty -LiteralPath $RegistrationPath -Name $entry.name -ErrorAction SilentlyContinue }
        } catch { $rollbackErrors += $_.Exception.Message }
    }
    foreach ($path in @($madeDirectories | Sort-Object Length -Descending)) {
        try { if ((Test-Path -LiteralPath $path) -and @(Get-ChildItem -LiteralPath $path -Force).Count -eq 0) { Remove-Item -LiteralPath $path -Force } } catch { $rollbackErrors += $_.Exception.Message }
    }
    if ($madeRegistry -and (Test-Path -LiteralPath $RegistrationPath)) {
        try { $key = Get-Item -LiteralPath $RegistrationPath; if ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) { Remove-Item -LiteralPath $RegistrationPath } } catch { $rollbackErrors += $_.Exception.Message }
    }
    if ($rollbackErrors.Count) { throw ($failure.Exception.Message + ' Rollback also failed: ' + ($rollbackErrors -join '; ')) }
    throw $failure
} finally { if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force } }
if ($Uninstall) {
    if (@(Get-ChildItem -LiteralPath $ownershipDirectory -Force).Count -eq 0) { Remove-Item -LiteralPath $ownershipDirectory -Force }
    Write-Host 'Removed installer-owned MesloLGS NF fonts. Sign out of Windows and sign in to refresh fonts in all apps. Existing third-party fonts and unrelated files were preserved.'
} else {
    Write-Host 'Installed MesloLGS NF for this user. Sign out of Windows and sign in to make the per-user registration available to all apps. Then in Windows Terminal: Settings > your profile > Appearance > Font face > MesloLGS NF.'
}
