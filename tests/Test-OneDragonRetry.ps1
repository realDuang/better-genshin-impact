$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Automation\OneDragonRetry.ps1')

$cases = @(
    @{ Name = 'first_success'; Codes = @(0); Cleanup = @($true); Expected = 1 },
    @{ Name = 'access_violation_then_success'; Codes = @(-1073741819, 0); Cleanup = @($true, $true); Expected = 2 },
    @{ Name = 'both_attempts_fail'; Codes = @(-1073741819, 1); Cleanup = @($true, $true); Expected = 2 },
    @{ Name = 'cleanup_failure_blocks_retry'; Codes = @(1); Cleanup = @($false); Expected = 1 },
    @{ Name = 'unowned_session_blocks_retry'; Codes = @(1); Cleanup = @($true); Retryable = $false; Expected = 1 }
)
foreach ($case in $cases) {
    $events = New-Object 'System.Collections.Generic.List[string]'
    $results = @(Invoke-OneDragonWithRetry -RunAttempt {
        param($number)
        if ($number -gt $case.Codes.Count) { throw 'Unexpected extra attempt.' }
        $events.Add("start-$number")
        $events.Add("cleanup-$number")
        [pscustomobject]@{
            Number = $number; ExitCode = $case.Codes[$number - 1]
            CleanupSucceeded = $case.Cleanup[$number - 1]
            Retryable = $case.Retryable -ne $false
        }
    } -OnRetry {
        param($previous)
        if ($events[$events.Count - 1] -ne "cleanup-$($previous.Number)") { throw 'Retry preceded cleanup.' }
        $events.Add('retry')
    })
    if ($results.Count -ne $case.Expected) { throw "Wrong attempt count: $($case.Name)" }
    if ($results[-1].ExitCode -ne $case.Codes[$case.Expected - 1]) { throw 'The final exit code was lost.' }
    $expectedEvents = if ($case.Expected -eq 2) { 'start-1,cleanup-1,retry,start-2,cleanup-2' } else { 'start-1,cleanup-1' }
    if (($events -join ',') -cne $expectedEvents) { throw "Wrong lifecycle order: $($case.Name)" }
    Write-Output "PASS $($case.Name)"
}

$retried = $false
$threw = $false
try {
    Invoke-OneDragonWithRetry -RunAttempt { throw 'Cleanup state unknown.' } -OnRetry { $script:retried = $true }
} catch { $threw = $true }
if (-not $threw -or $retried) { throw 'An unknown cleanup state must not be retried.' }
Write-Output 'PASS unexpected_exception_blocks_retry'
