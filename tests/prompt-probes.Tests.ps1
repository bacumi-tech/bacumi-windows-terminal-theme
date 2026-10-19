# Native executable regressions. Run under an external test-runner deadline.
param([ValidateSet('all','slow','hung','stdin','large','failing','environment','budget','child')][string] $Case = 'all')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
Import-Module (Join-Path $PSScriptRoot '../prompt/BacumiPrompt.psd1') -Force
$module = Get-Module BacumiPrompt
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('bacumi-probes with space %PATH% ! &-' + [guid]::NewGuid().ToString('N'))
$oldPath = $env:PATH; $oldLocation = Get-Location
$isWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$utf8 = New-Object Text.UTF8Encoding $false
$realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
function Write-Tool([string] $Name, [string] $UnixBody, [string] $WindowsBody) {
    $path = Join-Path $sandbox $(if ($isWindowsHost) { $Name + '.cmd' } else { $Name })
    [IO.File]::WriteAllText($path, $(if ($isWindowsHost) { "@echo off`r`n" + $WindowsBody.Replace('`r`n', "`r`n") + "`r`n" } else { "#!/bin/sh`n" + $UnixBody + "`n" }), $utf8)
    if (-not $isWindowsHost) { & /bin/chmod +x $path }
}
function Read-Context {
    & $module { param($directory) $script:runtimeCache = @{}; Get-BacumiRuntimes $directory } $sandbox
}
try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    & $realGit -C $sandbox init -q -b main
    Assert ($LASTEXITCODE -eq 0) 'Could not create native Git regression repository'
    [IO.File]::WriteAllText((Join-Path $sandbox 'package.json'), '{}')
    $env:PATH = $sandbox + [IO.Path]::PathSeparator + $oldPath
    Set-Location -LiteralPath $sandbox
    Enable-BacumiPrompt -ColorMode Plain
    $cases = if ($Case -eq 'all') { @('slow','hung','stdin','large','failing','environment','budget','child') } else { @($Case) }
    foreach ($scenario in $cases) {
        Write-Tool git "printf '# branch.oid abcdef1234567890\\n# branch.head main\\n'" "echo # branch.oid abcdef1234567890`r`necho # branch.head main"
        switch ($scenario) {
            'slow' { Write-Tool node 'sleep 1; echo v22.4.0' 'ping -n 3 127.0.0.1 >nul & echo v22.4.0' }
            'hung' { Write-Tool node 'while :; do sleep 1; done' ':again`r`nping -n 3 127.0.0.1 >nul`r`ngoto again' }
            'stdin' { Write-Tool node 'read answer; echo v22.4.0' 'set /p answer= & echo v22.4.0' }
            'large' { Write-Tool node 'while :; do printf "v22.4.0 %0200d\\n" 0; done' 'for /L %%i in (1,1,100000) do echo v22.4.0 xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' }
            'failing' { Write-Tool node 'echo v22.4.0; exit 9' 'echo v22.4.0`r`nexit /b 9' }
            'environment' { Write-Tool node 'test "$GOTOOLCHAIN" = local && test "$RUSTUP_AUTO_INSTALL" = 0 && test "$DOTNET_SKIP_FIRST_TIME_EXPERIENCE" = 1 && test "$DOTNET_CLI_TELEMETRY_OPTOUT" = 1 && echo v22.4.0' 'if "%GOTOOLCHAIN%:%RUSTUP_AUTO_INSTALL%:%DOTNET_SKIP_FIRST_TIME_EXPERIENCE%:%DOTNET_CLI_TELEMETRY_OPTOUT%"=="local:0:1:1" echo v22.4.0' }
            'budget' {
                foreach ($name in @('git','node','python','python3','go','rustc','dotnet')) { Write-Tool $name 'sleep 1; echo v22.4.0' 'ping -n 3 127.0.0.1 >nul & echo v22.4.0' }
                foreach ($name in @('requirements.txt','go.mod','Cargo.toml','global.json')) { [IO.File]::WriteAllText((Join-Path $sandbox $name), '') }
            }
            'child' {
                $priorPingIds = @(Get-Process -Name ping -ErrorAction Ignore | ForEach-Object { $_.Id })
                $pidFile = Join-Path $sandbox 'child.pid'
                Write-Tool node ('sleep 30 & echo $! > "' + $pidFile + '"; wait') 'ping -n 30 127.0.0.1 >nul'
            }
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $context = if ($scenario -eq 'budget') { & $module { $script:runtimeCache = @{}; Invoke-BacumiPrompt -PreviousSuccess $true -PreviousNativeExit 37 } } else { @(Read-Context) }
        $elapsed = $clock.ElapsedMilliseconds
        $limit = if ($scenario -eq 'budget') { 1200 } else { 700 }
        Assert ($elapsed -lt $limit) "$scenario probe exceeded prompt deadline: ${elapsed}ms"
        if ($scenario -in @('slow','hung','large','failing','child')) { Assert ($context -notcontains 'node:22.4.0') "$scenario probe must omit unavailable context" }
        if ($scenario -in @('stdin','environment')) { Assert ($context -contains 'node:22.4.0') "$scenario probe lost expected version (stdin must be closed; manager downloads disabled)" }
        if ($scenario -eq 'failing') {
            Write-Tool node 'echo v22.4.0' 'echo v22.4.0'
            & $module { $script:runtimeCache.node.time = [datetime]::UtcNow.AddSeconds(-3) }
            $recovered = @(& $module { param($directory) Get-BacumiRuntimes $directory } $sandbox)
            Assert ($recovered -contains 'node:22.4.0') 'A failed version probe must retry within two seconds rather than the full successful cache TTL'
        }
        if ($scenario -eq 'budget') {
            Assert ($global:LASTEXITCODE -eq 37) 'Probes overwrote captured native exit status'
            $engine = (Get-Process -Id $PID).Path
            & $engine -NoLogo -NoProfile -Command 'exit 7'
            $nativeText = prompt
            $nativeState = $?
            Assert ($nativeText -match '!7' -and -not $nativeState -and $global:LASTEXITCODE -eq 7) 'Timed out probes changed real native failure state'
        }
        if ($scenario -eq 'child' -and -not $isWindowsHost) {
            $childId = [int][IO.File]::ReadAllText($pidFile)
            Assert (-not (Get-Process -Id $childId -ErrorAction Ignore)) "Timed out probe left child $childId alive"
        }
        if ($scenario -eq 'child' -and $isWindowsHost) {
            $survivors = @(Get-Process -Name ping -ErrorAction Ignore | Where-Object { $_.Id -notin $priorPingIds })
            Assert ($survivors.Count -eq 0) 'Timed out .cmd probe left a native child alive'
        }
        if ($scenario -eq 'budget') {
            foreach ($name in @('requirements.txt','go.mod','Cargo.toml','global.json')) { Remove-Item -LiteralPath (Join-Path $sandbox $name) }
        }
        Write-Host "$scenario probe passed (${elapsed}ms)."
    }
    Write-Tool git 'sleep 0.4; printf "# branch.oid abcdef1234567890\\n# branch.head main\\n"' 'powershell.exe -NoLogo -NoProfile -NonInteractive -Command "Start-Sleep -Milliseconds 300"`r`necho # branch.oid abcdef1234567890`r`necho # branch.head main'
    $clock.Restart()
    $state = & $module { param($directory) Get-BacumiGit $directory } $sandbox
    Assert ($null -ne $state -and $state.branch -eq 'main' -and -not $state.unavailable) 'Git taking longer than 180ms must return real status within the 750ms Git budget'
    Assert ($clock.ElapsedMilliseconds -lt 1100) 'Moderate Git probe exceeded its bounded deadline'
    Write-Tool git 'printf "# branch.oid abcdef1234567890\n# branch.head main\n"; i=0; while [ "$i" -lt 1000 ]; do printf "1 .M N... 100644 100644 100644 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb changed%s\n" "$i"; i=$((i+1)); done' 'echo # branch.oid abcdef1234567890`r`necho # branch.head main`r`nfor /L %%i in (1,1,1000) do echo 1 .M N... 100644 100644 100644 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb changed%%i'
    $state = & $module { param($directory) Get-BacumiGit $directory } $sandbox
    Assert ($null -ne $state -and -not $state.unavailable -and $state.unstaged -eq 1000) 'Valid Git status above 64KiB must fit the bounded 256KiB capture'
    # Git uses the same closed-input, bounded-output and timeout path.
    Write-Tool git 'sleep 1; echo "# branch.head late"' 'ping -n 3 127.0.0.1 >nul & echo # branch.head late'
    $clock.Restart()
    $state = & $module { param($directory) Get-BacumiGit $directory } $sandbox
    Assert ($clock.ElapsedMilliseconds -lt 1100 -and $null -ne $state -and $state.branch -eq 'main' -and $state.unavailable) 'Timed out Git must preserve the HEAD branch and explicitly mark status unavailable within deadline'
    Assert ($state.staged -eq 0 -and $state.unstaged -eq 0 -and $state.untracked -eq 0 -and $null -eq $state.ahead -and $null -eq $state.behind) 'Timed out Git must discard partial counts and upstream data'
    foreach ($gitCase in @('failing','large')) {
        if ($gitCase -eq 'failing') { Write-Tool git 'printf "# branch.head fake\n"; exit 9' "echo # branch.head fake`r`nexit /b 9" }
        else { Write-Tool git 'while :; do printf "# branch.head fake %0200d\n" 0; done' 'for /L %%i in (1,1,100000) do echo # branch.head fake xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' }
        $clock.Restart()
        $state = & $module { param($directory) Get-BacumiGit $directory } $sandbox
        Assert ($clock.ElapsedMilliseconds -lt 1100 -and $null -ne $state -and $state.branch -eq 'main' -and $state.unavailable) "$gitCase Git must preserve HEAD and mark partial status unavailable within deadline"
    }
    $headPath = Join-Path $sandbox '.git/HEAD'
    $originalHead = [IO.File]::ReadAllText($headPath)
    try {
        [IO.File]::WriteAllText($headPath, ('a' * 40) + "`n")
        $head = & $module { param($directory) Get-BacumiGitHead $directory } (Join-Path $sandbox '.git')
        Assert ($head.detached -and $head.branch -eq 'aaaaaaa' -and $head.unavailable) 'Unavailable detached status must preserve a verified HEAD abbreviation'
        [IO.File]::WriteAllText($headPath, 'ref: refs/heads/' + ('x' * 600))
        $head = & $module { param($directory) Get-BacumiGitHead $directory } (Join-Path $sandbox '.git')
        Assert ($null -eq $head) 'Oversized HEAD must not yield a truncated branch'
        [IO.File]::WriteAllText($headPath, 'not a git HEAD')
        $head = & $module { param($directory) Get-BacumiGitHead $directory } (Join-Path $sandbox '.git')
        Assert ($null -eq $head) 'Malformed HEAD must omit unknown branch data'
    } finally { [IO.File]::WriteAllText($headPath, $originalHead) }
    Write-Tool git 'read answer; printf "# branch.oid abcdef1234567890\\n# branch.head main\\n"' 'set /p answer= >nul`r`necho # branch.oid abcdef1234567890`r`necho # branch.head main'
    $state = & $module { param($directory) Get-BacumiGit $directory } $sandbox
    Assert ($state.branch -eq 'main' -and -not $state.unavailable) 'Git probe must receive EOF on stdin and preserve porcelain text'
} finally {
    Disable-BacumiPrompt
    $env:PATH = $oldPath
    Set-Location -LiteralPath $oldLocation.Path
    Remove-Item -LiteralPath $sandbox -Recurse -Force
}
