function Read-OneDragonCleanupChildSession {
    [uint32]$sessionId = 0
    $succeeded = [OneDragonSession]::WTSGetChildSessionId([ref]$sessionId)
    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    return [pscustomobject]@{ Succeeded = $succeeded; SessionId = $sessionId; ErrorCode = $errorCode }
}

function Get-OneDragonCleanupChildSession {
    $query = Read-OneDragonCleanupChildSession
    if (-not $query.Succeeded) {
        # Windows reports no child with ERROR_NOT_FOUND and the documented absent-ID sentinel.
        if ($query.ErrorCode -eq 1168 -and $query.SessionId -eq [uint32]::MaxValue) { return $null }
        throw ('Cannot query the current Windows child session: ' + $query.ErrorCode)
    }
    if ($query.SessionId -ne [uint32]::MaxValue) { return [int]$query.SessionId }
    return $null
}

function Test-OneDragonCleanupSessionPresent([int]$SessionId) {
    return $null -ne [DesktopSessions]::Find($SessionId)
}

function Request-OneDragonCleanupLogoff([int]$SessionId) {
    # Submit asynchronously; the caller verifies disappearance with a bounded wait.
    if (-not [OneDragonSession]::WTSLogoffSession([IntPtr]::Zero, [uint32]$SessionId, $false)) {
        throw ('Child-session logoff failed: ' + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
}

function Test-OneDragonCleanupProcessExited($Process) {
    return $Process.HasExited
}

function Wait-OneDragonCleanupProcessExit($Process) {
    return $Process.WaitForExit(30000)
}

function Test-OneDragonCleanupHostChildrenExited($DesktopHost) {
    # A failed launcher may exit before its PowerShell child. Never terminate these processes here.
    $children = @(Get-CimInstance Win32_Process -Filter ("ParentProcessId={0}" -f $DesktopHost.Id) -ErrorAction Stop)
    return $children.Count -eq 0
}

function Request-OneDragonCleanupHostStop([string]$RunDirectory) {
    $null = New-Item -ItemType File -Path (Join-Path $RunDirectory 'child-host.stop') -Force -ErrorAction Stop
}

function Wait-OneDragonCleanupPoll {
    Start-Sleep -Milliseconds 500
}

function Remove-OneDragonCleanupTask([string]$TaskName) {
    $tasks = @(Get-ScheduledTask -TaskPath '\BetterGI\' -ErrorAction Stop | Where-Object TaskName -EQ $TaskName)
    foreach ($task in $tasks) {
        if ($task.State -in @('Running', 'Queued')) {
            Stop-ScheduledTask -InputObject $task -ErrorAction Stop
        }
        Unregister-ScheduledTask -InputObject $task -Confirm:$false -ErrorAction Stop
    }
    $remaining = @(Get-ScheduledTask -TaskPath '\BetterGI\' -ErrorAction Stop | Where-Object TaskName -EQ $TaskName)
    if ($remaining.Count -gt 0) { throw 'The owned OneDragon task still exists after removal.' }
}

function Wait-OneDragonCleanupTeardown($DesktopHost, $HostProcess, [Nullable[int]]$ChildSession) {
    # At most 30 seconds of polling after the initial host wait and logoff request.
    for ($poll = 0; $poll -le 60; $poll++) {
        $launcherExited = $null -eq $DesktopHost -or (Test-OneDragonCleanupProcessExited $DesktopHost)
        $hostExited = $null -eq $HostProcess -or (Test-OneDragonCleanupProcessExited $HostProcess)
        $sessionGone = $null -eq $ChildSession -or -not (Test-OneDragonCleanupSessionPresent ([int]$ChildSession))
        if ($launcherExited -and $hostExited -and $sessionGone) { return $true }
        if ($poll -lt 60) { Wait-OneDragonCleanupPoll }
    }
    return $false
}

function Complete-OneDragonAttempt {
    [CmdletBinding()]
    param(
        [AllowNull()]$DesktopHost,
        [AllowNull()][Nullable[int]]$ChildSession,
        [AllowNull()][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][int]$ParentSession,
        [AllowNull()]$HostProcess = $null
    )

    if ($ParentSession -le 0 -or ($null -ne $ChildSession -and ($ChildSession -le 0 -or $ChildSession -eq $ParentSession))) {
        return [pscustomobject]@{ Succeeded = $false; Detail = 'Refusing cleanup for an invalid or parent session identity.' }
    }
    if ($TaskName -and $TaskName -notmatch '^BetterGI-OneDragon-[0-9a-f]{32}$') {
        return [pscustomobject]@{ Succeeded = $false; Detail = 'Refusing cleanup for an unrecognized task identity.' }
    }

    $errors = New-Object 'System.Collections.Generic.List[string]'
    $teardownConfirmed = $false
    # Remove only the recorded task, so no queued launch survives into the next attempt.
    if ($TaskName) {
        try { Remove-OneDragonCleanupTask $TaskName }
        catch { $errors.Add('Owned task cleanup failed: ' + $_.Exception.Message) }
    }

    try {
        if ($null -ne $DesktopHost -and -not (Test-OneDragonCleanupProcessExited $DesktopHost)) {
            Request-OneDragonCleanupHostStop $RunDirectory
            $null = Wait-OneDragonCleanupProcessExit $DesktopHost
        }
    } catch {
        $errors.Add('Desktop host stop failed: ' + $_.Exception.Message)
    }

    # A failed stop request must not skip owned-session cleanup or final verification.
    try {
        $currentChild = Get-OneDragonCleanupChildSession
        if ($null -ne $currentChild -and ($null -eq $ChildSession -or $currentChild -ne $ChildSession)) {
            $errors.Add('An unowned Windows child session exists; it was left untouched.')
        }
    } catch {
        $errors.Add('Child-session ownership query failed: ' + $_.Exception.Message)
    }
    try {
        if ($null -ne $ChildSession -and (Test-OneDragonCleanupSessionPresent ([int]$ChildSession))) {
            Request-OneDragonCleanupLogoff ([int]$ChildSession)
        }
    } catch {
        $errors.Add('Owned child-session logoff failed: ' + $_.Exception.Message)
    }

    try {
        $teardownConfirmed = Wait-OneDragonCleanupTeardown $DesktopHost $HostProcess $ChildSession
        if (-not $teardownConfirmed) {
            $errors.Add('The owned desktop host or child session did not finish cleanup within the bounded wait.')
        }
    } catch {
        $errors.Add('Desktop teardown could not be verified: ' + $_.Exception.Message)
    }
    try {
        if ($null -ne (Get-OneDragonCleanupChildSession)) {
            $errors.Add('A Windows child session still exists; another attempt is blocked.')
        }
    } catch {
        $errors.Add('Final child-session query failed: ' + $_.Exception.Message)
    }
    try {
        if ($teardownConfirmed -and $null -ne $DesktopHost -and $null -eq $HostProcess -and $DesktopHost.ExitCode -ne 0) {
            if (-not (Test-OneDragonCleanupHostChildrenExited $DesktopHost)) {
                $errors.Add('The failed desktop launcher still has a child process; another attempt is blocked.')
            }
        }
    } catch {
        $errors.Add('Desktop cleanup could not be verified: ' + $_.Exception.Message)
    }

    $succeeded = $teardownConfirmed -and $errors.Count -eq 0
    $detail = if ($succeeded) {
        'No owned task, desktop host, or child session remains.'
    } else {
        $errors -join ' '
    }
    return [pscustomobject]@{ Succeeded = $succeeded; Detail = $detail }
}
