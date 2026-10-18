# Standalone integration tests; Windows PowerShell 5.1 and PowerShell 7.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$modulePath = Join-Path $PSScriptRoot '../prompt/BacumiPrompt.psd1'
Import-Module $modulePath -Force
$module = Get-Module BacumiPrompt
$fixtures = Get-Content (Join-Path $PSScriptRoot 'fixtures/git-cases.json') -Raw | ConvertFrom-Json
foreach ($case in $fixtures) {
    $actual = & $module { param($inputText) ConvertFrom-BacumiGitStatus $inputText } $case.porcelain
    if ($null -eq $case.expected) { Assert ($null -eq $actual) "Fixture $($case.name) must be absent"; continue }
    foreach ($property in $case.expected.PSObject.Properties) {
        Assert ($actual.($property.Name) -ceq $property.Value) "Fixture $($case.name): $($property.Name) differs"
    }
}
$renameStatus = '# branch.oid abcdef1234567890' + [char]0 + '# branch.head main' + [char]0 + '2 R. N... 100644 100644 100644 a b R100 renamed' + [char]0 + '? original filename' + [char]0 + '? new file' + [char]0
$renamed = & $module { param($text) ConvertFrom-BacumiGitStatus $text } $renameStatus
Assert ($renamed.staged -eq 1 -and $renamed.untracked -eq 1) 'NUL rename source must not be parsed as an extra file record'
Write-Host 'Shared Git semantic fixtures passed.'
$originalPrompt = (Get-Command prompt -CommandType Function).ScriptBlock
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('bacumi-runtime-test-' + [guid]::NewGuid().ToString('N'))
$originalLocation = Get-Location
$oldNoColor = $env:NO_COLOR
$env:NO_COLOR = $null
try {
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    function global:prompt { 'prior prompt> ' }
    Enable-BacumiPrompt -Appearance Dark -ColorMode Plain
    Enable-BacumiPrompt -Appearance Light -ColorMode Plain
    $global:LASTEXITCODE = 37
    $beforeLocation = (Get-Location).Path
    $rendered = prompt
    Assert ($global:LASTEXITCODE -eq 37) 'Prompt changed native exit code'
    Assert ((Get-Location).Path -eq $beforeLocation) 'Prompt changed directory'
    Assert ($rendered -notmatch '!37') 'Successful command must hide stale native exit status'
    Disable-BacumiPrompt
    Assert ((prompt) -eq 'prior prompt> ') 'Disable must restore the earlier prompt after repeated enabling'
    Enable-BacumiPrompt -ColorMode Plain -GitMode Off
    Write-Error 'Expected shell failure' -ErrorAction SilentlyContinue
    $failureText = prompt
    $failureState = $?
    Assert ($failureText -match '!1(?: |$)') 'Shell failure must ignore stale nonzero native exit status'
    Assert ($global:LASTEXITCODE -eq 37) 'Shell failure prompt must preserve stale native exit code'
    Assert (-not $failureState) 'Prompt must preserve the previous failure state'
    $engine = (Get-Process -Id $PID).Path
    & $engine -NoLogo -NoProfile -Command 'exit 7'
    $nativeText = prompt
    $nativeState = $?
    Assert ($nativeText -match '!7' -and -not $nativeState) 'Native failure must retain its exit code and failure state'
    Assert ($global:LASTEXITCODE -eq 7) 'Prompt probes changed a native failure code'
    & $engine -NoLogo -NoProfile -Command 'exit 7'
    $nativeText = prompt
    Assert ($nativeText -match '!7') 'Repeated same native failure code must remain accurate'
    Get-Location | Out-Null
    $beforeShellErrors = $global:Error.Count
    Write-Error 'Expected shell failure after successful cmdlet and native failure' -ErrorAction SilentlyContinue
    $shellText = prompt
    Assert ($shellText -match '!1(?: |$)' -and $global:LASTEXITCODE -eq 7) 'Shell failure must show !1 while retaining native exit 7'
    Assert ($global:Error.Count -eq ($beforeShellErrors + 1)) 'Prompt must not add errors to the user collection'
    $global:LASTEXITCODE = 0
    Write-Error 'Expected shell failure' -ErrorAction SilentlyContinue
    $failureText = prompt
    Assert ($failureText -match '!1') 'Shell failure with zero native exit must show !1'
    Disable-BacumiPrompt

    $state = & $module { ConvertFrom-BacumiGitStatus "# branch.oid abcdef1234567890`n# branch.head feature/very-long-name`nu UU N... conflict`n" }
    $state.operation = 'merge'
    foreach ($layout in @('Developer', 'Compact')) {
        Enable-BacumiPrompt -ColorMode Plain -Layout $layout
        foreach ($width in @(40, 80)) {
            $text = & $module { param($g, $w) Format-BacumiPrompt -Directory '/a very long path/percent% dollar$(unsafe)/project' -Git $g -Success $false -NativeExit 9 -Width $w -Context @('node:22.1.0', 'venv:test') -Duration 3.2 } $state $width
            Assert ($text -match 'conflict:1' -and $text -match '!9' -and $text -match '>') "Critical information missing at width $width ($layout)"
            foreach ($line in ($text -split "`n")) {
                $columns = & $module { param($t) Get-BacumiWidth $t } $line.TrimEnd("`r")
                Assert ($columns -le $width) "Prompt overflows width $width ($layout): $text"
            }
        }
    }
    $escaped = & $module { ConvertTo-BacumiText ('abc' + [char]27 + '[31m' + [char]10 + [char]0x202e + '$(touch fake)%') }
    Assert ($escaped -notmatch '[\x00-\x1f\u202e]') 'Terminal controls were not removed'
    Assert ($escaped.Contains('$(touch fake)%')) 'Shell-looking text must remain literal'
    $wide = & $module { Limit-BacumiText ([string][char]0x4e00 * 30) 12 }
    Assert ((& $module { param($t) Get-BacumiWidth $t } $wide) -le 12) 'Wide Unicode truncation overflows'
    foreach ($appearance in @('Dark', 'Light')) {
        foreach ($mode in @('TrueColor', 'Ansi', 'Plain')) {
            Enable-BacumiPrompt -Appearance $appearance -ColorMode $mode -Icons
            $text = & $module { param($g) Format-BacumiPrompt -Directory '/project' -Git $g } $state
            if ($mode -eq 'Plain') { Assert (-not $text.Contains([string][char]27)) 'Plain output contains ANSI escapes' }
            else { Assert ($text.Contains([string][char]27)) "$mode output must contain color escapes" }
            Assert ($text.Contains([string][char]0x276f)) 'Opt-in icon missing'
        }
    }
    $env:NO_COLOR = '1'
    Enable-BacumiPrompt -ColorMode TrueColor
    Assert (-not (prompt).Contains([string][char]27)) 'NO_COLOR must disable ANSI output'
    $env:NO_COLOR = $null

    $repo = Join-Path $sandbox 'repo with spaces'
    New-Item -ItemType Directory -Path $repo | Out-Null
    Set-Location -LiteralPath $repo
    & git init -q -b main
    & git config user.name 'Prompt Test'
    & git config user.email 'prompt-test@example.invalid'
    Enable-BacumiPrompt -ColorMode Plain
    $unborn = & $module { param($d) Get-BacumiGit $d } $repo
    Assert ($unborn.unborn -and $unborn.branch -eq 'main') 'Native Git unborn branch wrong'
    [IO.File]::WriteAllText((Join-Path $repo 'tracked.txt'), 'initial')
    & git add -- tracked.txt
    & git commit -qm initial
    $clean = & $module { param($d) Get-BacumiGit $d } $repo
    Assert ($clean.staged -eq 0 -and $null -eq $clean.ahead) 'Native clean Git state wrong'
    [IO.File]::WriteAllText((Join-Path $repo 'tracked.txt'), 'changed')
    [IO.File]::WriteAllText((Join-Path $repo 'new file.txt'), 'new')
    $changed = & $module { param($d) Get-BacumiGit $d } $repo
    Assert ($changed.unstaged -eq 1 -and $changed.untracked -eq 1) 'Native Git file counts wrong'
    & git add -- tracked.txt
    $staged = & $module { param($d) Get-BacumiGit $d } $repo
    Assert ($staged.staged -eq 1 -and $staged.unstaged -eq 0) 'Native Git staged count wrong'
    & git commit -qm changed
    & git checkout -q --detach
    $detached = & $module { param($d) Get-BacumiGit $d } $repo
    Assert ($detached.detached -and $detached.branch.Length -eq 7) 'Native detached Git state wrong'
    $detachedText = & $module { param($g) Format-BacumiPrompt -Directory '/repo' -Git $g } $detached
    Assert ($detachedText -match 'git:@[a-f0-9]{7}') 'Detached label missing @'
    & git checkout -q main
    & git branch upstream
    & git branch --set-upstream-to=upstream main 2>$null | Out-Null
    [IO.File]::WriteAllText((Join-Path $repo 'tracked.txt'), 'main change')
    & git add -- tracked.txt
    & git commit -qm main
    & git checkout -q upstream
    [IO.File]::WriteAllText((Join-Path $repo 'tracked.txt'), 'upstream change')
    & git add -- tracked.txt
    & git commit -qm upstream
    & git checkout -q main
    $diverged = & $module { param($d) Get-BacumiGit $d } $repo
    Assert ($diverged.ahead -eq 1 -and $diverged.behind -eq 1) 'Local ahead/behind counts wrong'
    & git merge upstream --no-edit 2>$null | Out-Null
    $conflict = & $module { param($d) Get-BacumiGit $d } $repo
    Assert ($conflict.conflicts -eq 1 -and $conflict.operation -eq 'merge') 'Merge/conflict state wrong'
    & git merge --abort
    New-Item -ItemType Directory -Path (Join-Path $repo '.git/rebase-merge') | Out-Null
    $rebase = & $module { param($d) Get-BacumiGit $d } $repo
    Assert ($rebase.operation -eq 'rebase') 'Rebase state wrong'
    Remove-Item -LiteralPath (Join-Path $repo '.git/rebase-merge')
    Enable-BacumiPrompt -ColorMode Plain -GitMode Fast
    $fast = & $module { param($d) Get-BacumiGit $d } $repo
    Assert ($fast.untracked -eq 0) 'Fast Git should skip untracked enumeration'
    Enable-BacumiPrompt -ColorMode Plain -GitMode Off
    Assert ($null -eq (& $module { param($d) Get-BacumiGit $d } $repo)) 'Git Off must skip probing'
    # Real executable doubles measure context relevance and bounded version caching.
    $fakeBin = Join-Path $sandbox 'fake tools'
    New-Item -ItemType Directory -Path $fakeBin | Out-Null
    $counter = Join-Path $sandbox 'node-calls.txt'
    $fakeNode = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { Join-Path $fakeBin 'node.cmd' } else { Join-Path $fakeBin 'node' }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [IO.File]::WriteAllText($fakeNode, "@echo off`r`necho call>>`"$counter`"`r`necho v22.4.0`r`n")
    } else {
        [IO.File]::WriteAllText($fakeNode, "#!/bin/sh`necho call >> '" + $counter.Replace("'", "'\''") + "'`nprintf 'v22.4.0\n'`n")
        & chmod +x $fakeNode
    }
    $oldPath = $env:PATH
    try {
        $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $oldPath
        $noProject = Join-Path $sandbox 'no-project'
        New-Item -ItemType Directory -Path $noProject | Out-Null
        & $module { param($d) Get-BacumiRuntimes $d } $noProject | Out-Null
        Assert (-not (Test-Path -LiteralPath $counter)) 'Node must not run without a relevant manifest'
        [IO.File]::WriteAllText((Join-Path $noProject 'package.json'), '{"scripts":{"preinstall":"never run"}}')
        $runtimes = @(& $module { param($d) Get-BacumiRuntimes $d } $noProject)
        Assert ($runtimes -contains 'node:22.4.0') 'Relevant active Node version missing'
        & $module { param($d) Get-BacumiRuntimes $d } $noProject | Out-Null
        Assert (@(Get-Content -LiteralPath $counter).Count -eq 1) 'Warm runtime version must be cached'
        [IO.File]::AppendAllText((Join-Path $noProject 'package.json'), ' ')
        & $module { param($d) Get-BacumiRuntimes $d } $noProject | Out-Null
        Assert (@(Get-Content -LiteralPath $counter).Count -eq 2) 'Manifest change must invalidate runtime cache'
        & $module { $script:runtimeCache.node.time = [datetime]::UtcNow.AddHours(-1) }
        & $module { param($d) Get-BacumiRuntimes $d } $noProject | Out-Null
        Assert (@(Get-Content -LiteralPath $counter).Count -eq 3) 'Bounded expiry must invalidate runtime cache'
        $oldVirtualEnv = $env:VIRTUAL_ENV
        try {
            $env:VIRTUAL_ENV = Join-Path $sandbox 'venv with spaces'
            $runtimes = @(& $module { param($d) Get-BacumiRuntimes $d } $noProject)
            Assert ($runtimes -contains 'venv:venv with spaces') 'Active virtual environment name missing'
            Assert (@(Get-Content -LiteralPath $counter).Count -eq 4) 'Environment changes must invalidate runtime cache'
        } finally { $env:VIRTUAL_ENV = $oldVirtualEnv }
    } finally { $env:PATH = $oldPath }
    Disable-BacumiPrompt
    Assert ((prompt) -eq 'prior prompt> ') 'Prompt restoration after all activation modes failed'
    Enable-BacumiPrompt -ColorMode Plain
    Remove-Module BacumiPrompt
    Assert ((prompt) -eq 'prior prompt> ') 'Module unload must restore previous prompt'
    Import-Module $modulePath -Force
    Write-Host 'Native prompt checks passed: Git states, local upstream, merge/rebase, status/PWD, restore/idempotence, widths, escaping, Unicode, colors, icons and Git modes.'
} finally {
    Disable-BacumiPrompt
    Set-Item Function:\global:prompt -Value $originalPrompt
    $env:NO_COLOR = $oldNoColor
    Set-Location -LiteralPath $originalLocation.Path
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}
