# Tests for profile-etw-common.ps1 (profile-etw.ps1's app and bench modes). No ETW sessions,
# UAC prompts or application windows. Registered in CTest on Windows with PowerShell 7; can also
# run directly with pwsh -File.
#Requires -Version 7
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'profile-etw-common.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $false
    try { & $Action }
    catch {
        $caught = $true
        Assert-True ($_.ToString() -like "*$Pattern*") "Unexpected exception: $_"
    }
    Assert-True $caught "Expected failure: $Pattern"
}

# #874: a filter matching nothing is an error, several matches a warning, one match fine.
$none = Resolve-BenchmarkFilterMatches -ListOutput @() -Filter 'BM_Nope$'
Assert-True ($none.Severity -eq 'error') 'Zero matches must be an error'
Assert-True ($none.Message -like "*matches no benchmarks*") 'Zero-match message'
$blank = Resolve-BenchmarkFilterMatches -ListOutput @('', '   ') -Filter 'BM_Nope$'
Assert-True ($blank.Severity -eq 'error') 'Blank list output must count as zero matches'

$one = Resolve-BenchmarkFilterMatches -ListOutput @('BM_SystemModel_Refresh') -Filter 'BM_SystemModel_Refresh$'
Assert-True ($one.Severity -eq 'ok') 'One match must be accepted'
Assert-True (@($one.Names).Count -eq 1 -and $one.Names[0] -eq 'BM_SystemModel_Refresh') 'Matched name lost'

$many = Resolve-BenchmarkFilterMatches -ListOutput @('BM_A', 'BM_B', 'BM_C') -Filter 'BM_.*'
Assert-True ($many.Severity -eq 'warning') 'Several matches must warn'
Assert-True (@($many.Names).Count -eq 3) 'Matched names lost'
Assert-True ($many.Message -like '*matches 3 benchmarks*' -and $many.Message -like '*- BM_B*') 'Warning must list the matches'

# Listing goes through the real benchmark binary's exit code: a failing lister throws.
$hostExe = (Get-Process -Id $PID).Path
$root = Join-Path ([IO.Path]::GetTempPath()) "tasksmack-etw-tests-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $fakeLister = Join-Path $root 'lister.cmd'
    Set-Content -LiteralPath $fakeLister -Value "@echo BM_One`r`n@echo BM_Two`r`n@exit /b 0" -Encoding ascii
    $listed = Get-BenchmarkFilterMatches -BinaryPath $fakeLister -Filter 'BM_.*'
    Assert-True ($listed.Severity -eq 'warning' -and @($listed.Names).Count -eq 2) 'Lister output not parsed'
    # Google Benchmark reports a non-matching filter on stderr and exits 0; that message must not
    # be counted as a benchmark name.
    $noMatchLister = Join-Path $root 'nomatch.cmd'
    Set-Content -LiteralPath $noMatchLister -Value "@echo Failed to match any benchmarks against regex: BM_Nope 1>&2`r`n@exit 0" -Encoding ascii
    $noMatch = Get-BenchmarkFilterMatches -BinaryPath $noMatchLister -Filter 'BM_Nope$'
    Assert-True ($noMatch.Severity -eq 'error') "A stderr-only no-match report was counted as a benchmark: $(@($noMatch.Names) -join ',')"
    $failingLister = Join-Path $root 'failing.cmd'
    Set-Content -LiteralPath $failingLister -Value "@echo boom`r`n@exit /b 3" -Encoding ascii
    Assert-Throws { Get-BenchmarkFilterMatches -BinaryPath $failingLister -Filter 'BM_.*' } 'exit 3'

    # #872: the integrity level is measured from the process's own token.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $own = Get-ProcessIntegrityLevel -ProcessId $PID
    $expected = if ($isAdmin) { 'High' } else { 'Medium' }
    Assert-True ($own -eq $expected) "This process's integrity measured as '$own', expected '$expected'"
    Assert-True ((Get-ProcessIntegrityLevel -ProcessId 999999) -eq 'Unknown') 'A missing process must be Unknown'
    Assert-True ((ConvertTo-IntegrityLevelName 0x2000) -eq 'Medium' -and (ConvertTo-IntegrityLevelName 0x3000) -eq 'High') 'Well-known RIDs'
    Assert-True ((ConvertTo-IntegrityLevelName 0x2500) -eq '0x2500') 'An unknown RID must be shown as hex, not mislabelled'

    # The orchestrator fails fast when the collector exits before it starts recording.
    $exited = Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile', '-Command', 'exit 5') -PassThru -WindowStyle Hidden
    $null = $exited.Handle
    $exited.WaitForExit()
    Assert-Throws { Wait-CollectorMarker -Path (Join-Path $root 'never') -TimeoutSeconds 30 -Collector $exited } 'exited (code 5)'
    # A collector that recorded why it failed has that reason reported.
    Set-Content -LiteralPath (Join-Path $root 'collector-error.txt') -Value 'wpr: profile not found'
    Assert-Throws { Wait-CollectorMarker -Path (Join-Path $root 'never') -TimeoutSeconds 30 -Collector $exited } 'Collector error: wpr: profile not found'
    Assert-Throws { Wait-CollectorMarker -Path (Join-Path $root 'never') -TimeoutSeconds 1 } 'Timed out'
    $marker = Join-Path $root 'started'
    Set-Content -LiteralPath $marker -Value '{}'
    Wait-CollectorMarker -Path $marker -TimeoutSeconds 1
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'profile-etw tests passed'
