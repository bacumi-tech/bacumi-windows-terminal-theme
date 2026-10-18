# MIT License - Copyright (c) 2026 Bacumi
# No profile editing, project-script evaluation, network calls or background jobs.
Set-StrictMode -Version 2.0
$script:enabled = $false
$script:previousPrompt = $null
$script:runtimeCache = @{}
$script:settings = @{}
$script:lastObservedError = $null

function ConvertTo-BacumiText([string] $Text) {
    # Remove terminal controls and bidirectional formatting before rendering data.
    return [regex]::Replace($Text, '[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]', '')
}

function Get-BacumiWidth([string] $Text) {
    $width = 0
    $elements = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($elements.MoveNext()) {
        $element = [string]$elements.Current
        $point = [char]::ConvertToUtf32($element, 0)
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($element, 0)
        if ($category -eq [Globalization.UnicodeCategory]::NonSpacingMark) { continue }
        if (($point -ge 0x1100 -and $point -le 0x115f) -or ($point -ge 0x2329 -and $point -le 0x232a) -or
            ($point -ge 0x2e80 -and $point -le 0xa4cf) -or ($point -ge 0xac00 -and $point -le 0xd7a3) -or
            ($point -ge 0xf900 -and $point -le 0xfaff) -or ($point -ge 0xfe10 -and $point -le 0xfe6f) -or
            ($point -ge 0xff00 -and $point -le 0xff60) -or ($point -ge 0x1f000 -and $point -le 0x1faff) -or
            ($point -ge 0x20000 -and $point -le 0x3ffff)) { $width += 2 } else { $width++ }
    }
    return $width
}

function Limit-BacumiText([string] $Text, [int] $Width) {
    if ($Width -le 0) { return '' }
    if ((Get-BacumiWidth $Text) -le $Width) { return $Text }
    if ($Width -le 3) { return ('.' * $Width) }
    $result = ''
    $elements = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($elements.MoveNext()) {
        $next = $result + [string]$elements.Current
        if ((Get-BacumiWidth $next) -gt ($Width - 3)) { break }
        $result = $next
    }
    return $result + '...'
}

function ConvertFrom-BacumiGitStatus([string] $Text) {
    if (-not $Text -or $Text -notmatch '# branch\.') { return $null }
    $state = [ordered]@{ branch = ''; unborn = $false; detached = $false; staged = 0; unstaged = 0; untracked = 0; conflicts = 0; ahead = $null; behind = $null; operation = '' }
    $oid = ''; $skipRenamePath = $false
    # Native porcelain v2 -z protects newlines in filenames. Fixtures also accept lines.
    $records = if ($Text.Contains([string][char]0)) { $Text.Split([char]0) } else { $Text -split "`n" }
    foreach ($record in $records) {
        if ($skipRenamePath) { $skipRenamePath = $false; continue }
        if ($record.StartsWith('# branch.oid ')) { $oid = $record.Substring(13).Trim(); $state.unborn = $oid -eq '(initial)' }
        elseif ($record.StartsWith('# branch.head ')) { $state.branch = $record.Substring(14).TrimEnd("`r", "`n") }
        elseif ($record -match '^# branch.ab \+(\d+) -(\d+)') { $state.ahead = [int]$Matches[1]; $state.behind = [int]$Matches[2] }
        elseif ($record.StartsWith('? ')) { $state.untracked++ }
        elseif ($record.StartsWith('u ')) { $state.conflicts++ }
        elseif ($record -match '^[12] ([^ ]{2}) ') {
            $xy = $Matches[1]
            if ($xy[0] -ne '.') { $state.staged++ }
            if ($xy[1] -ne '.') { $state.unstaged++ }
            if ($record.StartsWith('2 ') -and $Text.Contains([string][char]0)) { $skipRenamePath = $true }
        }
    }
    if ($state.branch -eq '(detached)') { $state.detached = $true; $state.branch = $oid.Substring(0, [Math]::Min(7, $oid.Length)) }
    $state.branch = ConvertTo-BacumiText $state.branch
    return [pscustomobject]$state
}

function Get-BacumiGitDirectory([string] $Directory) {
    $cursor = $Directory
    for ($i = 0; $cursor -and $i -lt 64; $i++) {
        $candidate = Join-Path $cursor '.git'
        if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $content = [IO.File]::ReadAllText($candidate)
            if ($content -match '^gitdir: (.+)') {
                $target = $Matches[1].TrimEnd("`r", "`n")
                if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path $cursor $target }
                return [IO.Path]::GetFullPath($target)
            }
            return $null
        }
        $parent = [IO.Directory]::GetParent($cursor)
        $cursor = if ($null -ne $parent) { $parent.FullName } else { $null }
    }
    return $null
}

function Get-BacumiGit([string] $Directory) {
    if ($script:settings.GitMode -eq 'Off') { return $null }
    $gitDirectory = Get-BacumiGitDirectory $Directory
    if (-not $gitDirectory) { return $null }
    $git = Get-Command git -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    if (-not $git) { return $null }
    $arguments = @('--no-optional-locks', '-c', 'core.fsmonitor=false', 'status', '--porcelain=v2', '--branch', '-z')
    if ($script:settings.GitMode -eq 'Fast') { $arguments += @('--untracked-files=no', '--ignore-submodules=all') }
    else { $arguments += '--untracked-files=normal' }
    $raw = & $git.Source @arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $state = ConvertFrom-BacumiGitStatus ($raw -join "`n")
    if ($null -eq $state) { return $null }
    if ((Test-Path -LiteralPath (Join-Path $gitDirectory 'rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $gitDirectory 'rebase-apply'))) { $state.operation = 'rebase' }
    elseif (Test-Path -LiteralPath (Join-Path $gitDirectory 'MERGE_HEAD')) { $state.operation = 'merge' }
    return $state
}

function Get-BacumiRuntimes([string] $Directory) {
    $definitions = @(
        @{ label = 'node'; command = 'node'; args = @('--version'); files = @('package.json', '.nvmrc', '.node-version') },
        @{ label = 'python'; command = 'python'; args = @('--version'); files = @('pyproject.toml', 'requirements.txt', 'Pipfile', '.python-version') },
        @{ label = 'go'; command = 'go'; args = @('version'); files = @('go.mod', 'go.work') },
        @{ label = 'rust'; command = 'rustc'; args = @('--version'); files = @('Cargo.toml', 'rust-toolchain', 'rust-toolchain.toml') },
        @{ label = 'dotnet'; command = 'dotnet'; args = @('--version'); files = @('global.json', '*.csproj', '*.fsproj', '*.sln', '*.slnx') }
    )
    $output = @()
    foreach ($definition in $definitions) {
        $cursor = $Directory; $project = ''; $fingerprint = ''
        for ($depth = 0; $cursor -and $depth -lt 32; $depth++) {
            foreach ($pattern in $definition.files) {
                $filePaths = @()
                if ($pattern.Contains('*')) {
                    try { $filePaths = @([IO.Directory]::EnumerateFiles($cursor, $pattern, [IO.SearchOption]::TopDirectoryOnly)) } catch { }
                } else {
                    $filePath = [IO.Path]::Combine($cursor, $pattern)
                    if ([IO.File]::Exists($filePath)) { $filePaths = @($filePath) }
                }
                foreach ($filePath in $filePaths) {
                    $file = [IO.FileInfo]$filePath
                    $fingerprint += $file.FullName + ':' + $file.LastWriteTimeUtc.Ticks + ':' + $file.Length + ';'
                }
            }
            if ($fingerprint) { $project = $cursor; break }
            $parent = [IO.Directory]::GetParent($cursor)
            $cursor = if ($null -ne $parent) { $parent.FullName } else { $null }
        }
        if (-not $project -and -not ($definition.label -eq 'python' -and ($env:VIRTUAL_ENV -or $env:CONDA_DEFAULT_ENV))) { continue }
        $command = Get-Command $definition.command -CommandType Application -ErrorAction Ignore | Select-Object -First 1
        if (-not $command -and $definition.label -eq 'python') { $command = Get-Command python3 -CommandType Application -ErrorAction Ignore | Select-Object -First 1 }
        if (-not $command) { continue }
        $key = $definition.label + '|' + $Directory + '|' + $project + '|' + $fingerprint + '|' + $command.Source + '|' + $env:PATH + '|' + $env:VIRTUAL_ENV + '|' + $env:CONDA_DEFAULT_ENV + '|' + $env:PYENV_VERSION + '|' + $env:NVM_BIN
        $cached = $script:runtimeCache[$definition.label]
        if (-not $cached -or $cached.key -ne $key -or ([datetime]::UtcNow - $cached.time).TotalSeconds -ge $script:settings.CacheSeconds) {
            # Application only: aliases/functions and project scripts are never invoked.
            $versionOutput = & $command.Source @($definition.args) 2>$null
            $version = ''
            if ($LASTEXITCODE -eq 0 -and (($versionOutput -join ' ') -match '(\d+\.\d+(?:\.\d+)?(?:[-+][A-Za-z0-9.-]+)?)')) { $version = $Matches[1] }
            $cached = @{ key = $key; time = [datetime]::UtcNow; version = $version }
            $script:runtimeCache[$definition.label] = $cached
        }
        if ($cached.version) { $output += $definition.label + ':' + $cached.version }
    }
    if ($env:VIRTUAL_ENV) { $output += 'venv:' + (ConvertTo-BacumiText (Split-Path ($env:VIRTUAL_ENV.TrimEnd('/', '\')) -Leaf)) }
    elseif ($env:CONDA_DEFAULT_ENV) { $output += 'venv:' + (ConvertTo-BacumiText $env:CONDA_DEFAULT_ENV) }
    return $output
}

function Format-BacumiPrompt {
    param([string] $Directory, $Git, [bool] $Success = $true, [int] $NativeExit = 0, [int] $Width = 80,
        [string[]] $Context = @(), [double] $Duration = 0)
    $Width = [Math]::Max(16, $Width)
    $path = ConvertTo-BacumiText $Directory
    $homePath = [Environment]::GetFolderPath('UserProfile')
    if ($homePath -and ($path -eq $homePath -or $path.StartsWith($homePath + [IO.Path]::DirectorySeparatorChar))) { $path = '~' + $path.Substring($homePath.Length) }
    $critical = @()
    if ($null -ne $Git) {
        $branchPrefix = if ($Git.detached) { 'git:@' } else { 'git:' }
        $branchLabel = $branchPrefix + (Limit-BacumiText (ConvertTo-BacumiText $Git.branch) $(if ($Width -lt 60) { 12 } else { 28 }))
        $critical += $branchLabel
        if ($Git.conflicts -gt 0) { $critical += 'conflict:' + $Git.conflicts }
        if ($Git.operation) { $critical += $Git.operation }
    }
    $failure = if ($Success) { '' } elseif ($NativeExit -ne 0) { '!' + $NativeExit } else { '!1' }
    $marker = if ($script:settings.Icons) { [char]0x276f } else { '>' }
    $inputLine = if ($failure) { $failure + ' ' + $marker + ' ' } else { [string]$marker + ' ' }
    if ($critical.Count) {
        $otherWidth = if ($critical.Count -gt 1) { (Get-BacumiWidth ($critical[1..($critical.Count - 1)] -join ' ')) + 1 } else { 0 }
        $inputWidth = if ($script:settings.Layout -eq 'Compact') { (Get-BacumiWidth $inputLine) + 1 } else { 0 }
        $branchBudget = [Math]::Max(1, $Width - $otherWidth - $inputWidth - $branchPrefix.Length - 7)
        $critical[0] = $branchPrefix + (Limit-BacumiText (ConvertTo-BacumiText $Git.branch) ([Math]::Min($branchBudget, $(if ($Width -lt 60) { 12 } else { 28 }))))
    }
    $reserved = if ($critical.Count) { (Get-BacumiWidth ($critical -join ' ')) + 2 } else { 0 }
    if ($script:settings.Layout -eq 'Compact') { $reserved += (Get-BacumiWidth $inputLine) + 1 }
    $pathBudget = [Math]::Max(1, $Width - $reserved)
    if ((Get-BacumiWidth $path) -gt $pathBudget) {
        $leaf = Split-Path $path -Leaf
        if ($leaf) { $path = '.../' + $leaf }
        $path = Limit-BacumiText $path $pathBudget
    }
    $first = $path
    if ($critical.Count) { $first += '  ' + ($critical -join ' ') }
    $gitEnd = $first.Length
    $optional = @()
    if ($null -ne $Git) {
        if ($script:settings.GitMode -eq 'Full') {
            if ($Git.staged) { $optional += '+' + $Git.staged }
            if ($Git.unstaged) { $optional += '~' + $Git.unstaged }
            if ($Git.untracked) { $optional += '?' + $Git.untracked }
        }
        if ($null -ne $Git.ahead -and $Git.ahead -gt 0) { $optional += 'ahead:' + $Git.ahead }
        if ($null -ne $Git.behind -and $Git.behind -gt 0) { $optional += 'behind:' + $Git.behind }
    }
    $gitOptionCount = $optional.Count
    $optional += $Context
    if ($Duration -ge 2) { $optional += $Duration.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + 's' }
    $optionIndex = 0
    foreach ($item in $optional) {
        $candidate = $first + '  ' + (ConvertTo-BacumiText $item)
        $extra = if ($script:settings.Layout -eq 'Compact') { (Get-BacumiWidth $inputLine) + 1 } else { 0 }
        if ((Get-BacumiWidth $candidate) + $extra -le $Width) { $first = $candidate; if ($optionIndex -lt $gitOptionCount) { $gitEnd = $first.Length } }
        $optionIndex++
    }
    $mode = $script:settings.ColorMode
    if ($mode -eq 'Auto') {
        $mode = 'Plain'
        if (-not $env:NO_COLOR -and $env:TERM -ne 'dumb') {
            $supports = $false
            try { $supports = $Host.UI.SupportsVirtualTerminal } catch { }
            if ($supports -or $env:WT_SESSION -or $env:TERM) {
                $mode = if ($env:COLORTERM -match 'truecolor|24bit' -or $env:WT_SESSION) { 'TrueColor' } else { 'Ansi' }
            }
        }
    }
    if ($env:NO_COLOR) { $mode = 'Plain' }
    if ($mode -ne 'Plain') {
        $escape = [string][char]27
        $bad = -not $Success -or ($null -ne $Git -and $Git.conflicts -gt 0)
        $reset = $escape + '[0m'
        if ($mode -eq 'TrueColor') {
            $colors = if ($script:settings.Appearance -eq 'Light') {
                @{ directory = '47;96;132'; git = '66;101;60'; muted = '86;95;107'; error = '180;35;24'; accent = '163;65;0' }
            } else {
                @{ directory = '147;182;214'; git = '173;196;161'; muted = '160;167;178'; error = '255;138;128'; accent = '255;179;71' }
            }
            $directoryColor = $escape + '[38;2;' + $colors.directory + 'm'
            $gitColor = $escape + '[38;2;' + $(if ($null -ne $Git -and $Git.conflicts) { $colors.error } else { $colors.git }) + 'm'
            $contextColor = $escape + '[38;2;' + $colors.muted + 'm'
            $markerColor = $escape + '[38;2;' + $(if ($bad) { $colors.error } else { $colors.accent }) + 'm'
        } else {
            $directoryColor = $escape + '[34m'
            $gitColor = $escape + $(if ($null -ne $Git -and $Git.conflicts) { '[31m' } else { '[32m' })
            $contextColor = $escape + '[90m'
            $markerColor = $escape + $(if ($bad) { '[31m' } else { '[33m' })
        }
        $first = $directoryColor + $first.Substring(0, $path.Length) + $reset +
            $gitColor + $first.Substring($path.Length, $gitEnd - $path.Length) + $reset +
            $contextColor + $first.Substring($gitEnd) + $reset
        $inputLine = $markerColor + $inputLine + $reset
    }
    if ($script:settings.Layout -eq 'Compact') { return $first + ' ' + $inputLine }
    return $first + [Environment]::NewLine + $inputLine
}

function Get-BacumiFailureCode([bool] $Success, [int] $NativeExit, $PreviousError, $History) {
    if ($Success) { return 0 }
    # A shell failure can follow an earlier native failure; LASTEXITCODE remains
    # deliberately unchanged by PowerShell cmdlets. New shell errors take priority.
    if ($PreviousError -and -not [object]::ReferenceEquals($PreviousError, $script:lastObservedError)) {
        $commandType = if ($PreviousError.InvocationInfo.MyCommand) { [string]$PreviousError.InvocationInfo.MyCommand.CommandType } else { '' }
        if ($commandType -ne 'Application' -and $PreviousError.FullyQualifiedErrorId -notmatch '^NativeCommand' -and
            $PreviousError.Exception.GetType().Name -notmatch 'NativeCommand') { return 1 }
    }
    # History gives a second signal for intentionally ignored shell errors. Parse
    # only the command name; never execute history, arguments or project contents.
    if ($History) {
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($History.CommandLine, [ref]$tokens, [ref]$parseErrors)
        $commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
        if ($commands.Count) {
            $name = $commands[-1].GetCommandName()
            if ($name) {
                $command = Get-Command -Name $name -ErrorAction Ignore | Select-Object -First 1
                if ($command -and $command.CommandType -ne 'Application') { return 1 }
            }
        }
    }
    if ($NativeExit -ne 0) { return $NativeExit }
    return 1
}

function Invoke-BacumiPrompt {
    param([bool] $PreviousSuccess, [int] $PreviousNativeExit, $PreviousError)
    try {
        $location = Get-Location
        $directory = $location.Path
        $git = $null; $context = @(); $duration = 0
        if ($location.Provider.Name -eq 'FileSystem') {
            $git = Get-BacumiGit $directory
            $context += @(Get-BacumiRuntimes $directory)
        }
        if ($env:SSH_CONNECTION -or $env:SSH_TTY -or [Environment]::UserName -eq 'root' -or $script:settings.Elevated) {
            $context += [Environment]::UserName + '@' + [Environment]::MachineName
        }
        $jobs = @(Get-Job -ErrorAction Ignore | Where-Object { $_.State -in @('Running', 'NotStarted', 'Blocked', 'Disconnected') })
        if ($jobs.Count) { $context += 'jobs:' + $jobs.Count }
        $history = Get-History -Count 1 -ErrorAction Ignore
        if ($history -and $history.EndExecutionTime -ge $history.StartExecutionTime) { $duration = ($history.EndExecutionTime - $history.StartExecutionTime).TotalSeconds }
        $width = 80
        try { if ($Host.UI.RawUI.WindowSize.Width -gt 0) { $width = $Host.UI.RawUI.WindowSize.Width } } catch { }
        $failureCode = Get-BacumiFailureCode $PreviousSuccess $PreviousNativeExit $PreviousError $history
        Format-BacumiPrompt -Directory $directory -Git $git -Success $PreviousSuccess -NativeExit $failureCode -Context $context -Duration $duration -Width $width
    } catch { '> ' }
    finally {
        $global:LASTEXITCODE = $PreviousNativeExit
        $script:lastObservedError = if ($global:Error.Count) { $global:Error[0] } else { $null }
    }
}

function Enable-BacumiPrompt {
    [CmdletBinding()]
    param([ValidateSet('Dark', 'Light')][string] $Appearance = 'Dark',
        [ValidateSet('Developer', 'Compact')][string] $Layout = 'Developer',
        [ValidateSet('Auto', 'TrueColor', 'Ansi', 'Plain')][string] $ColorMode = 'Auto',
        [ValidateSet('Full', 'Fast', 'Off')][string] $GitMode = 'Full',
        [switch] $Icons, [ValidateRange(1, 3600)][int] $CacheSeconds = 30)
    if (-not $script:enabled) {
        $existing = Get-Item Function:\global:prompt -ErrorAction Ignore
        # Get-Item's global-qualified function path differs between PS editions.
        if (-not $existing) { $existing = Get-Command prompt -CommandType Function -ErrorAction Ignore }
        $script:previousPrompt = if ($existing) { $existing.ScriptBlock } else { $null }
    }
    $elevated = $false
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        try { $identity = [Security.Principal.WindowsIdentity]::GetCurrent(); $principal = New-Object Security.Principal.WindowsPrincipal $identity; $elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
    }
    $script:settings = @{ Appearance = $Appearance; Layout = $Layout; ColorMode = $ColorMode; GitMode = $GitMode; Icons = [bool]$Icons; CacheSeconds = $CacheSeconds; Elevated = $elevated }
    $script:enabled = $true
    $script:lastObservedError = if ($global:Error.Count) { $global:Error[0] } else { $null }
    $promptBlock = {
        [CmdletBinding()]
        param()
        $previousSuccess = $?
        $nativeVariable = Get-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore
        $previousNativeExit = if ($nativeVariable) { [int]$nativeVariable.Value } else { 0 }
        $previousError = if ($global:Error.Count) { $global:Error[0] } else { $null }
        Invoke-BacumiPrompt -PreviousSuccess $previousSuccess -PreviousNativeExit $previousNativeExit -PreviousError $previousError
        # Ignore keeps the user's error collection untouched while restoring $?.
        if (-not $previousSuccess) {
            $ErrorActionPreference = 'Ignore'
            $record = [Management.Automation.ErrorRecord]::new([Exception]::new('Previous command failed.'), 'BacumiPreviousCommand', [Management.Automation.ErrorCategory]::NotSpecified, $null)
            $PSCmdlet.WriteError($record)
        }
    }.GetNewClosure()
    # Bind the global function to this module so private implementation stays private.
    $promptBlock = $ExecutionContext.SessionState.Module.NewBoundScriptBlock($promptBlock)
    Set-Item Function:\global:prompt -Value $promptBlock
}

function Disable-BacumiPrompt {
    [CmdletBinding()]
    param()
    if (-not $script:enabled) { return }
    if ($null -ne $script:previousPrompt) { Set-Item Function:\global:prompt -Value $script:previousPrompt }
    else { Remove-Item Function:\global:prompt -ErrorAction Ignore }
    $script:enabled = $false
    $script:runtimeCache = @{}
}
$ExecutionContext.SessionState.Module.OnRemove = { Disable-BacumiPrompt }
Export-ModuleMember -Function Enable-BacumiPrompt, Disable-BacumiPrompt
