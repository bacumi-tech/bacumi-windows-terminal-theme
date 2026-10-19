# Diagnostic local benchmark; no network, no benchmark dependencies.
[CmdletBinding()]
param([ValidateRange(3, 500)][int] $Samples = 30, [ValidateRange(100, 100000)][int] $Files = 3000)
$ErrorActionPreference = 'Stop'
$benchmarkRoot = Join-Path ([IO.Path]::GetTempPath()) ('bacumi-benchmark-' + [guid]::NewGuid().ToString('N'))
$oldLocation = Get-Location
function Summarize([double[]] $Values) {
    $sorted = @($Values | Sort-Object)
    return @{ median_ms = [Math]::Round($sorted[[int][Math]::Floor($sorted.Count / 2)], 2); p95_ms = [Math]::Round($sorted[[Math]::Min($sorted.Count - 1, [int][Math]::Ceiling($sorted.Count * 0.95) - 1)], 2); samples = $sorted.Count }
}
try {
    New-Item -ItemType Directory -Path $benchmarkRoot | Out-Null
    $modules = Join-Path $benchmarkRoot 'modules'
    & (Join-Path $PSScriptRoot '../Install-Prompt.ps1') -ModuleRoot $modules 6>$null
    $modulePath = Join-Path $modules 'BacumiPrompt/BacumiPrompt.psd1'
    $project = Join-Path $benchmarkRoot 'project'
    New-Item -ItemType Directory -Path $project | Out-Null
    Set-Location -LiteralPath $project
    $engine = (Get-Process -Id $PID).Path
    $escapedModule = $modulePath.Replace("'", "''")
    $command = @"
`$clock = [Diagnostics.Stopwatch]::StartNew()
Import-Module '$escapedModule'
`$import = `$clock.Elapsed.TotalMilliseconds
`$clock.Restart()
Enable-BacumiPrompt -ColorMode Plain
`$enable = `$clock.Elapsed.TotalMilliseconds
`$clock.Restart()
prompt | Out-Null
@{ import_ms = `$import; enable_ms = `$enable; first_prompt_ms = `$clock.Elapsed.TotalMilliseconds } | ConvertTo-Json -Compress
"@
    $cold = @(); $imports = @(); $enables = @(); $firstPrompts = @()
    for ($i = 0; $i -lt $Samples; $i++) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $phases = & $engine -NoLogo -NoProfile -NonInteractive -Command $command | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Cold prompt subprocess failed.' }
        $watch.Stop(); $cold += $watch.Elapsed.TotalMilliseconds
        $imports += $phases.import_ms; $enables += $phases.enable_ms; $firstPrompts += $phases.first_prompt_ms
    }
    Import-Module $modulePath -Force
    Enable-BacumiPrompt -ColorMode Plain
    prompt | Out-Null
    $warm = @()
    for ($i = 0; $i -lt $Samples; $i++) { $watch = [Diagnostics.Stopwatch]::StartNew(); prompt | Out-Null; $watch.Stop(); $warm += $watch.Elapsed.TotalMilliseconds }
    & git init -q -b main
    & git config user.name 'Bacumi Benchmark'
    & git config user.email 'benchmark@example.invalid'
    for ($i = 0; $i -lt $Files; $i++) { [IO.File]::WriteAllText((Join-Path $project ('tracked-' + $i + '.txt')), 'initial') }
    & git add -- .
    & git commit -qm baseline
    for ($i = 0; $i -lt 100; $i++) {
        [IO.File]::WriteAllText((Join-Path $project ('tracked-' + $i + '.txt')), 'modified')
        [IO.File]::WriteAllText((Join-Path $project ('untracked-' + $i + '.txt')), 'untracked')
    }
    prompt | Out-Null
    $large = @()
    for ($i = 0; $i -lt $Samples; $i++) { $watch = [Diagnostics.Stopwatch]::StartNew(); prompt | Out-Null; $watch.Stop(); $large += $watch.Elapsed.TotalMilliseconds }
    Enable-BacumiPrompt -ColorMode Plain -GitMode Fast
    $fast = @()
    for ($i = 0; $i -lt $Samples; $i++) { $watch = [Diagnostics.Stopwatch]::StartNew(); prompt | Out-Null; $watch.Stop(); $fast += $watch.Elapsed.TotalMilliseconds }
    $architecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')
    try { $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch { }
    [ordered]@{
        engine = $PSVersionTable.PSVersion.ToString(); os = [Environment]::OSVersion.VersionString
        architecture = $architecture; tracked_files = $Files
        modified_files = 100; untracked_files = 100
        cold_process_import_first_prompt = Summarize $cold; warm_non_git_prompt = Summarize $warm
        installed_module_import = Summarize $imports; prompt_enable = Summarize $enables
        first_prompt = Summarize $firstPrompts
        large_git_full_prompt = Summarize $large; large_git_fast_prompt = Summarize $fast
    } | ConvertTo-Json -Depth 4
} finally {
    if (Get-Command Disable-BacumiPrompt -ErrorAction SilentlyContinue) { Disable-BacumiPrompt }
    Set-Location -LiteralPath $oldLocation.Path
    if (Test-Path -LiteralPath $benchmarkRoot) { Remove-Item -LiteralPath $benchmarkRoot -Recurse -Force }
}
