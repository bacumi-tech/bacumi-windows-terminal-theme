# Exercise the real PowerShell formatter; fixtures also feed honest preview captures.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
Import-Module (Join-Path $PSScriptRoot '../prompt/BacumiPrompt.psd1') -Force
$module = Get-Module BacumiPrompt
$oldTerm = $env:TERM; $oldNoColor = $env:NO_COLOR; $oldColorTerm = $env:COLORTERM; $oldWt = $env:WT_SESSION
$fixtures = Get-Content (Join-Path $PSScriptRoot 'fixtures/prompt-segments.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$escape = [string][char]27
function Remove-Color([string]$Text) { [regex]::Replace($Text, '\x1b\[[0-9;]*m', '') }
function Render($Case, [int]$Width) {
    & $module {
        param($c, $w)
        $git = [pscustomobject]@{ branch = $c.branch; detached = $false; unborn = $false; conflicts = $c.conflicts; operation = $c.operation; staged = 2; unstaged = 1; untracked = 3; ahead = 1; behind = 2 }
        if ($null -ne $c.PSObject.Properties['unavailable']) { $git | Add-Member -NotePropertyName unavailable -NotePropertyValue $c.unavailable }
        Format-BacumiPrompt -Directory $c.directory -Git $git -Width $w -Success $c.success -NativeExit $c.exit -Context $c.context -Duration $c.duration
    } $Case $Width
}
try {
    $env:TERM = 'xterm-256color'; $env:NO_COLOR = $null
    $captures = @()
    foreach ($appearance in @('Dark', 'Light')) {
        foreach ($layout in @('Developer', 'Compact')) {
            foreach ($mode in @('TrueColor', 'Ansi', 'Plain')) {
                foreach ($icons in @($false, $true)) {
                    Enable-BacumiPrompt -Appearance $appearance -Layout $layout -ColorMode $mode -Icons:$icons
                    foreach ($case in $fixtures) {
                        foreach ($width in @(40, 80, 120)) {
                            $text = Render $case $width
                            $plain = Remove-Color $text
                            foreach ($line in ($plain -split "`n")) {
                                $columns = & $module { param($t) Get-BacumiWidth $t } $line.TrimEnd("`r")
                                Assert ($columns -le $width) "Overflow: $appearance/$layout/$mode/$icons/$($case.name)/$width ($columns): $plain"
                            }
                            Assert ($plain -match 'git:') 'Branch badge missing'
                            if ($null -ne $case.PSObject.Properties['unavailable'] -and $case.unavailable) {
                                Assert ($plain.Contains('status:?')) 'Unavailable Git status must stay visible at every width'
                                foreach ($staleToken in @('+2', '~1', '?3', 'ahead:', 'behind:')) {
                                    Assert (-not $plain.Contains($staleToken)) "Unavailable Git status showed stale $staleToken"
                                }
                            }
                            if ($case.conflicts) { Assert ($plain.Contains('conflict:1')) 'Conflict lost while fitting badges' }
                            if (-not $case.success) { Assert ($plain.Contains('!' + $case.exit)) 'Failure lost while fitting badges' }
                            $expectedMarker = if ($icons) { [string][char]0x276f } else { '>' }
                            Assert ($plain.EndsWith($expectedMarker + ' ')) 'Input marker or trailing input space changed'
                            Assert ($icons -or -not $plain.Contains([string][char]0x276f)) 'Default prompt requires an icon font'
                            if ($mode -eq 'Plain') { Assert (-not $text.Contains($escape)) 'Plain mode emitted an escape' }
                            else {
                                Assert ($text.Contains(';48;2;') -or $mode -eq 'Ansi') 'TrueColor badges have no backgrounds'
                                Assert ($text.Contains($escape + '[0m ' + $escape)) 'Badges must reset before the one-cell gap'
                            }
                            if ($width -eq 80 -and $case.name -eq 'developer-clean') {
                                Assert ($plain.Contains('node:22.4.0')) 'Normal-width prompt should shorten the location to admit its first runtime'
                            }
                            if ($width -eq 120 -and $case.name -eq 'developer-clean') {
                                foreach ($token in @('+2', '~1', '?3', 'ahead:1', 'behind:2', 'node:22.4.0', '3.2s')) {
                                    Assert ($plain.Contains($token)) "Roomy prompt dropped $token"
                                }
                                if ($case.operation) { Assert ($plain.Contains($case.operation)) 'Roomy prompt dropped Git operation' }
                            }
                            if ($mode -eq 'TrueColor' -and -not $icons) { $captures += [pscustomobject]@{ appearance = $appearance; layout = $layout; name = $case.name; width = $width; ansi = $text; plain = $plain } }
                        }
                    }
                }
            }
        }
    }
    $clean = $fixtures[0]
    foreach ($appearance in @('Dark', 'Light')) {
        Enable-BacumiPrompt -Appearance $appearance -ColorMode TrueColor
        $text = Render $clean 120
        $expected = if ($appearance -eq 'Dark') {
            @('38;2;23;25;31;48;2;255;179;71', '38;2;23;25;31;48;2;173;196;161', '38;2;216;217;221;48;2;50;60;75', '38;2;255;179;71m> ')
        } else {
            @('38;2;250;250;248;48;2;163;65;0', '38;2;250;250;248;48;2;66;101;60', '38;2;48;52;60;48;2;221;229;238', '38;2;163;65;0m> ')
        }
        foreach ($style in $expected) { Assert ($text.Contains($style)) "Wrong $appearance role colors: $style" }
        Enable-BacumiPrompt -Appearance $appearance -ColorMode Ansi
        $ansiText = Render $clean 120
        foreach ($style in @('[33;49;7m', '[32;49;7m', '[90;49;7m')) { Assert ($ansiText.Contains($escape + $style)) 'ANSI badges must use terminal background as readable text' }
        Assert ((Render $fixtures[1] 120).Contains($escape + '[31;49;7m')) 'ANSI failure badge missing'
        Enable-BacumiPrompt -Appearance $appearance -ColorMode TrueColor
        $errorStyle = if ($appearance -eq 'Dark') { '38;2;23;25;31;48;2;255;138;128' } else { '38;2;250;250;248;48;2;180;35;24' }
        $errorText = Render $fixtures[1] 120
        Assert (([regex]::Matches($errorText, [regex]::Escape($errorStyle))).Count -eq 2) 'Conflict and failure must each receive the error background'
        $unknownText = Render $fixtures[3] 120
        Assert (([regex]::Matches($unknownText, [regex]::Escape($errorStyle))).Count -eq 2) 'Unavailable status and failure must each receive an error badge'
        # Branch and counts are one complete Git badge, and each runtime is separate.
        Assert ($text.Contains(' git:feature/bacumi +2 ~1 ?3 ahead:1 behind:2 ' + $escape + '[0m')) 'Git counts escaped their single badge'
        Assert ($text.Contains(' node:22.4.0 ' + $escape + '[0m ' + $escape)) 'Runtime badge missing its padding or gap'
    }
    Enable-BacumiPrompt -ColorMode Plain
    $shortAfterLong = & $module {
        Format-BacumiPrompt -Directory '/work' -Git $null -Width 40 -Context @(('node:' + ('x' * 100)), 'venv:ok') -Duration 2.3
    }
    Assert ($shortAfterLong.Contains('venv:ok') -and $shortAfterLong.Contains('2.3s')) 'Long optional context suppressed later shorter segments'
    $literal = & $module {
        $git = [pscustomobject]@{ branch = ('feature%$(' + [char]27 + '[31m' + [char]0x202e + 'unsafe)'); detached = $false; conflicts = 0; operation = ''; staged = 0; unstaged = 0; untracked = 0; ahead = $null; behind = $null }
        Format-BacumiPrompt -Directory ('/work/%$(literal)' + [char]10 + [char]0x202e) -Git $git -Width 120 -Context @('venv:$(literal)%')
    }
    Assert ($literal.Contains('%$(literal)') -and $literal.Contains('feature%$(')) 'Shell-looking text stopped being literal'
    Assert ($literal -notmatch '[\x1b\u202e]') 'Untrusted terminal controls survived rendering'
    # Optional state must be StrictMode-safe and must not label a known status
    # unavailable. The worst compact budget includes both critical Git suffixes.
    foreach ($layout in @('Developer', 'Compact')) {
        Enable-BacumiPrompt -ColorMode Plain -Layout $layout
        $unknownAndConflict = & $module {
            $git = [pscustomobject]@{ branch = 'feature/long-name'; detached = $false; conflicts = 1; operation = 'merge'; staged = 0; unstaged = 0; untracked = 0; ahead = $null; behind = $null; unavailable = $true }
            Format-BacumiPrompt -Directory '/a/long/path/project' -Git $git -Width 40 -Success $false -NativeExit 9
        }
        Assert ($unknownAndConflict.Contains('status:?') -and $unknownAndConflict.Contains('conflict:1') -and $unknownAndConflict.Contains('!9')) 'Critical unavailable/conflict/failure combination lost a label'
        foreach ($line in ($unknownAndConflict -split "`n")) {
            Assert ((& $module { param($t) Get-BacumiWidth $t } $line.TrimEnd("`r")) -le 40) 'Combined critical Git states exceeded the compact budget'
        }
    }
    Enable-BacumiPrompt -ColorMode Plain
    $knownStatus = & $module {
        $git = [pscustomobject]@{ branch = 'main'; detached = $false; conflicts = 0; operation = ''; staged = 0; unstaged = 0; untracked = 0; ahead = $null; behind = $null; unavailable = $false }
        Format-BacumiPrompt -Directory '/project' -Git $git -Width 40
    }
    Assert (-not $knownStatus.Contains('status:?')) 'Known Git state incorrectly shows unavailable'
    $env:NO_COLOR = '1'
    Enable-BacumiPrompt -ColorMode TrueColor
    Assert (-not (Render $clean 120).Contains($escape)) 'NO_COLOR did not override explicit color mode'
    $env:NO_COLOR = $null; $env:TERM = 'dumb'
    Assert (-not (Render $clean 120).Contains($escape)) 'TERM=dumb did not override explicit color mode'
    $env:TERM = 'xterm-256color'; $env:COLORTERM = 'truecolor'; $env:WT_SESSION = $null
    Enable-BacumiPrompt -ColorMode Auto
    Assert ((Render $clean 120).Contains(';48;2;')) 'Auto missed truecolor capability'
    $env:COLORTERM = $null
    Assert ((Render $clean 120).Contains($escape + '[33;49;7m')) 'Auto missed ANSI fallback'
    if ($env:BACUMI_SEGMENT_CAPTURE) { $captures | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:BACUMI_SEGMENT_CAPTURE -Encoding UTF8 }
    Write-Host 'Segment prompt checks passed: 288 fixture renders, 40/80/120 columns, both layouts/appearances, colors, fallbacks, literal Unicode, icons, critical states and independent runtime badges.'
} finally {
    Disable-BacumiPrompt
    $env:TERM = $oldTerm; $env:NO_COLOR = $oldNoColor; $env:COLORTERM = $oldColorTerm; $env:WT_SESSION = $oldWt
}
