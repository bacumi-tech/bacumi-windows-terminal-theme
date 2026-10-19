# MIT License - Copyright (c) 2026 Bacumi
# No profile editing, project-script evaluation, network calls or background jobs.
Set-StrictMode -Version 2.0
$script:enabled = $false
$script:previousPrompt = $null
$script:runtimeCache = @{}
$script:settings = @{}
$script:lastObservedError = $null

# One in-process helper drains both pipes without PowerShell callbacks or jobs.
# Installed helpers are compiled during setup, not each shell startup.
if (-not ('BacumiPrompt.NativeProbe' -as [type])) {
    $assembly = Join-Path $PSScriptRoot ('BacumiPrompt.NativeProbe.net' + [Environment]::Version.Major + '.dll')
    if ([IO.File]::Exists($assembly)) {
        # Load bytes so Windows does not lock the installed DLL during updates.
        $null = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assembly))
    } else {
        # Source checkouts and a different .NET major retain the standalone fallback.
        Add-Type -LiteralPath (Join-Path $PSScriptRoot 'NativeProbe.cs')
    }
}
$script:probeClock = $null

function Invoke-BacumiProbe([string] $Executable, [string[]] $Arguments, [string] $Directory, [int] $OutputLimit = 4096, [int] $TimeoutMilliseconds = 180) {
    $remaining = $TimeoutMilliseconds
    if ($null -ne $script:probeClock) { $remaining -= [int]$script:probeClock.ElapsedMilliseconds }
    return [BacumiPrompt.NativeProbe]::Run($Executable, $Arguments, $Directory, [Math]::Max(0, $remaining), $OutputLimit)
}

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
    $state = [ordered]@{ branch = ''; unborn = $false; detached = $false; staged = 0; unstaged = 0; untracked = 0; conflicts = 0; ahead = $null; behind = $null; operation = ''; unavailable = $false }
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

function Get-BacumiGitHead([string] $GitDirectory) {
    # Read only a small HEAD record. Never parse truncated data as a branch or commit.
    $stream = $null; $reader = $null
    try {
        $headPath = [IO.Path]::Combine($GitDirectory, 'HEAD')
        if (-not [IO.File]::Exists($headPath)) { return $null }
        $stream = [IO.File]::Open($headPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 512)
        $buffer = New-Object char[] 512
        $count = $reader.Read($buffer, 0, $buffer.Length)
        if ($count -eq 0 -or $count -eq $buffer.Length) { return $null }
        $head = [string]::new($buffer, 0, $count)
        $branch = ''; $detached = $false
        if ($head -match '^ref: refs/heads/([^\r\n]+)(?:\r?\n)?$') { $branch = $Matches[1] }
        elseif ($head -match '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})(?:\r?\n)?$') { $branch = $head.Substring(0, 7); $detached = $true }
        else { return $null }
        return [pscustomobject][ordered]@{
            branch = (ConvertTo-BacumiText $branch); unborn = $false; detached = $detached
            staged = 0; unstaged = 0; untracked = 0; conflicts = 0
            ahead = $null; behind = $null; operation = ''; unavailable = $true
        }
    } catch { return $null }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-BacumiGit([string] $Directory) {
    if ($script:settings.GitMode -eq 'Off') { return $null }
    $gitDirectory = Get-BacumiGitDirectory $Directory
    if (-not $gitDirectory) { return $null }
    $git = Get-Command git -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    $state = $null
    if ($git) {
        $arguments = @('--no-optional-locks', '-c', 'core.fsmonitor=false', 'status', '--porcelain=v2', '--branch', '-z')
        if ($script:settings.GitMode -eq 'Fast') { $arguments += @('--untracked-files=no', '--ignore-submodules=all') }
        else { $arguments += @('--untracked-files=normal', '--ignore-submodules=dirty') }
        # Git for Windows can need more than the short runtime-version budget.
        $probe = Invoke-BacumiProbe $git.Source $arguments $Directory 262144 750
        if ($probe.Success) { $state = ConvertFrom-BacumiGitStatus $probe.Output }
    }
    if ($null -eq $state) { $state = Get-BacumiGitHead $gitDirectory }
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
        $cacheSeconds = if ($cached -and $cached.version) { $script:settings.CacheSeconds } else { [Math]::Min(2, $script:settings.CacheSeconds) }
        if (-not $cached -or $cached.key -ne $key -or ([datetime]::UtcNow - $cached.time).TotalSeconds -ge $cacheSeconds) {
            # Application only: aliases/functions and project scripts are never invoked.
            $probe = Invoke-BacumiProbe $command.Source @($definition.args) $Directory
            $version = ''
            if ($probe.Success -and ($probe.Output -match '(\d+\.\d+(?:\.\d+)?(?:[-+][A-Za-z0-9.-]+)?)')) { $version = $Matches[1] }
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
        [string[]] $Context = @(), [double] $Duration = 0,
        [ValidateSet('command failed', 'command not found')][string] $FailureLabel = 'command failed')
    $Width = [Math]::Max(16, $Width)
    $path = ConvertTo-BacumiText $Directory
    $homePath = [Environment]::GetFolderPath('UserProfile')
    if ($homePath -and ($path -eq $homePath -or $path.StartsWith($homePath + [IO.Path]::DirectorySeparatorChar))) { $path = '~' + $path.Substring($homePath.Length) }
    if (-not $path) { $path = '.' }
    $failure = if ($Success) { '' } elseif ($NativeExit -ne 0) { '!' + $NativeExit } else { '!1' }
    if ($failure) { $failure = Limit-BacumiText ($failure + ' ' + $FailureLabel) ($Width - 6) }
    $layout = $script:settings.Layout
    $marker = if ($script:settings.Icons) { [string][char]0x276f } else { '>' }
    # Every badge has one cell of padding on either side, with one empty cell
    # between badges. Measure the unstyled output so escapes cannot affect fitting.
    $inputText = if ($failure) { ' ' + $failure + '  ' + $marker + ' ' } else { $marker + ' ' }
    $branchPrefix = ''; $branch = ''; $gitSuffix = ''; $gitText = ''; $unknownGit = $false
    if ($null -ne $Git) {
        $branchPrefix = if ($Git.detached) { 'git:@' } else { 'git:' }
        $branch = ConvertTo-BacumiText $Git.branch
        if (-not $branch) { $branch = '?' }
        if ($Git.conflicts -gt 0) { $gitSuffix = ' conflict:' + $Git.conflicts }
        $unknownGit = $null -ne $Git.PSObject.Properties['unavailable'] -and [bool]$Git.unavailable
        if ($unknownGit) { $gitSuffix += ' status:?' }
    }
    $minimumFirst = 3
    if ($null -ne $Git) { $minimumFirst += 4 + (Get-BacumiWidth ($branchPrefix + $gitSuffix)) }
    # Let compact failures wrap before sacrificing their explanation or Git state.
    if ($failure -and $minimumFirst + (Get-BacumiWidth $inputText) + 1 -gt $Width) { $layout = 'Developer' }
    $inputReserve = if ($layout -eq 'Compact') { (Get-BacumiWidth $inputText) + 1 } else { 0 }
    $contentWidth = $Width - $inputReserve
    $fixedWidth = 2
    if ($null -ne $Git) { $fixedWidth += 3 + (Get-BacumiWidth ($branchPrefix + $gitSuffix)) }
    $textBudget = [Math]::Max(1, $contentWidth - $fixedWidth)
    if ($null -ne $Git -and (Get-BacumiWidth ($path + $branch)) -gt $textBudget) {
        # Keep both location and branch identifiable before admitting optional data.
        $pathBudget = [Math]::Max(1, [int][Math]::Floor($textBudget / 2))
        $branchBudget = [Math]::Max(1, $textBudget - $pathBudget)
        if ((Get-BacumiWidth $branch) -lt $branchBudget) { $pathBudget += $branchBudget - (Get-BacumiWidth $branch) }
        if ((Get-BacumiWidth $path) -lt $pathBudget) { $branchBudget += $pathBudget - (Get-BacumiWidth $path) }
        if ((Get-BacumiWidth $path) -gt $pathBudget) {
            $leaf = ($path -split '[/\\]')[-1]
            if ($leaf -and $pathBudget -ge 7) { $path = '.../' + $leaf }
            $path = Limit-BacumiText $path $pathBudget
        }
        $branch = Limit-BacumiText $branch $branchBudget
    } elseif ($null -eq $Git) { $path = Limit-BacumiText $path $textBudget }
    $firstWidth = (Get-BacumiWidth $path) + 2
    if ($null -ne $Git) {
        $gitText = $branchPrefix + $branch + $gitSuffix
        $firstWidth += (Get-BacumiWidth $gitText) + 3
        $gitOptional = @()
        if ($Git.operation) { $gitOptional += ConvertTo-BacumiText $Git.operation }
        if (-not $unknownGit -and $script:settings.GitMode -eq 'Full') {
            if ($Git.staged) { $gitOptional += '+' + $Git.staged }
            if ($Git.unstaged) { $gitOptional += '~' + $Git.unstaged }
            if ($Git.untracked) { $gitOptional += '?' + $Git.untracked }
        }
        if (-not $unknownGit -and $null -ne $Git.ahead -and $Git.ahead -gt 0) { $gitOptional += 'ahead:' + $Git.ahead }
        if (-not $unknownGit -and $null -ne $Git.behind -and $Git.behind -gt 0) { $gitOptional += 'behind:' + $Git.behind }
        foreach ($item in $gitOptional) {
            $extra = (Get-BacumiWidth $item) + 1
            if ($item -and $firstWidth + $extra -le $contentWidth) { $gitText += ' ' + $item; $firstWidth += $extra }
        }
    }
    # On normal-width terminals, a shorter location can make room for the
    # first relevant runtime without losing Git counts or any critical state.
    if ($Width -ge 80) {
        foreach ($item in $Context) {
            $runtimeText = ConvertTo-BacumiText $item
            if (-not $runtimeText) { continue }
            $needed = $firstWidth + (Get-BacumiWidth $runtimeText) + 3 - $contentWidth
            if ($needed -le 0) { break }
            $pathBudget = (Get-BacumiWidth $path) - $needed
            if ($pathBudget -ge 7) {
                $oldPathWidth = Get-BacumiWidth $path
                $leaf = ($path -split '[/\\]')[-1]
                if ($leaf) { $path = '.../' + $leaf }
                $path = Limit-BacumiText $path $pathBudget
                $firstWidth -= $oldPathWidth - (Get-BacumiWidth $path)
                break
            }
        }
    }
    $badges = @(@{ role = 'directory'; text = $path })
    if ($gitText) { $badges += @{ role = $(if ($Git.conflicts -gt 0 -or $unknownGit) { 'error' } else { 'git' }); text = $gitText } }
    $optional = @($Context)
    if ($Duration -ge 2) { $optional += $Duration.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + 's' }
    foreach ($item in $optional) {
        $text = ConvertTo-BacumiText $item
        $extra = (Get-BacumiWidth $text) + 3
        # A long context does not prevent later, shorter contexts from appearing.
        if ($text -and $firstWidth + $extra -le $contentWidth) {
            $badges += @{ role = 'context'; text = $text }; $firstWidth += $extra
        }
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
    if ($env:NO_COLOR -or $env:TERM -eq 'dumb') { $mode = 'Plain' }
    $escape = [string][char]27
    $reset = if ($mode -eq 'Plain') { '' } else { $escape + '[0m' }
    $styles = @{ directory = ''; git = ''; context = ''; error = ''; marker = '' }
    if ($mode -eq 'TrueColor') {
        $colors = if ($script:settings.Appearance -eq 'Light') {
            @{ directory = @('250;250;248', '163;65;0'); git = @('250;250;248', '66;101;60'); context = @('48;52;60', '221;229;238'); error = @('250;250;248', '180;35;24'); marker = '163;65;0' }
        } else {
            @{ directory = @('23;25;31', '255;179;71'); git = @('23;25;31', '173;196;161'); context = @('216;217;221', '50;60;75'); error = @('23;25;31', '255;138;128'); marker = '255;179;71' }
        }
        foreach ($role in @('directory', 'git', 'context', 'error')) { $styles[$role] = $escape + '[38;2;' + $colors[$role][0] + ';48;2;' + $colors[$role][1] + 'm' }
        $styles.marker = $escape + '[38;2;' + $colors.marker + 'm'
    } elseif ($mode -eq 'Ansi') {
        # Inverse uses the terminal's default background as badge text. Bacumi's
        # ANSI black/white slots are readable text colors, not background colors.
        $styles = @{ directory = $escape + '[33;49;7m'; git = $escape + '[32;49;7m'; context = $escape + '[90;49;7m'; error = $escape + '[31;49;7m'; marker = $escape + '[33m' }
    }
    $rendered = @()
    foreach ($badge in $badges) { $rendered += $styles[$badge.role] + ' ' + $badge.text + ' ' + $reset }
    $first = $rendered -join ' '
    $inputLine = $styles.marker + $marker + ' ' + $reset
    if ($failure) { $inputLine = $styles.error + ' ' + $failure + ' ' + $reset + ' ' + $inputLine }
    if ($layout -eq 'Compact') { return $first + ' ' + $inputLine }
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
    $script:probeClock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $location = Get-Location
        $directory = $location.Path
        $git = $null; $context = @(); $duration = 0
        if ($location.Provider.Name -eq 'FileSystem') {
            $git = Get-BacumiGit $directory
            $script:probeClock.Restart()
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
        $failureLabel = 'command failed'
        if (-not $PreviousSuccess -and $PreviousError -and
            -not [object]::ReferenceEquals($PreviousError, $script:lastObservedError) -and
            $PreviousError.Exception -is [Management.Automation.CommandNotFoundException]) { $failureLabel = 'command not found' }
        Format-BacumiPrompt -Directory $directory -Git $git -Success $PreviousSuccess -NativeExit $failureCode -Context $context -Duration $duration -Width $width -FailureLabel $failureLabel
    } catch { '> ' }
    finally {
        $script:probeClock = $null
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
