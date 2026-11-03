function Invoke-OneDragonWithRetry {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$RunAttempt,
        [scriptblock]$OnRetry = {}
    )
    $attempts = New-Object 'System.Collections.Generic.List[object]'
    for ($number = 1; $number -le 2; $number++) {
        $attempt = & $RunAttempt $number
        if ($null -eq $attempt -or $null -eq $attempt.ExitCode -or $null -eq $attempt.CleanupSucceeded) {
            throw 'The attempt did not return a complete lifecycle result; recovery is unsafe.'
        }
        $attempts.Add($attempt)
        if ($attempt.ExitCode -eq 0 -or -not $attempt.CleanupSucceeded -or
            $attempt.Retryable -eq $false -or $number -eq 2) { break }
        & $OnRetry $attempt | Out-Null
    }
    return $attempts.ToArray()
}
