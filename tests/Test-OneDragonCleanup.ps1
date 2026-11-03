param([string]$SourcePath = (Join-Path $PSScriptRoot '..\Automation\OneDragonCleanup.ps1'))
$ErrorActionPreference = 'Stop'
. $SourcePath
$removeTaskImplementation = ${function:Remove-OneDragonCleanupTask}
$getChildImplementation = ${function:Get-OneDragonCleanupChildSession}

function Assert-Case([string]$Name, [bool]$Passed) {
    if (-not $Passed) { throw "OneDragon cleanup regression failed: $Name" }
    [pscustomobject]@{ Case = $Name; Passed = $true } | ConvertTo-Json -Compress
}

function Reset-Fixture {
    $script:fixture = @{
        CurrentChild = $null; SessionPresent = $false
        LauncherExited = $true; HostExited = $true
        ExitOnWait = $true; ClearSessionOnWait = $true
        LogoffCompletes = $true; ExitOnLogoff = $true
        QueryFails = $false; SessionQueryFails = $false; LogoffFails = $false
        TaskCleanupFails = $false; HostChildrenExited = $true
        StopFails = $false; WaitFails = $false
        Polls = 0; ClearOnPoll = 0; WaitCalls = 0; QueryCalls = 0
        Stops = (New-Object 'System.Collections.Generic.List[string]')
        Logoffs = (New-Object 'System.Collections.Generic.List[int]')
        RemovedTasks = (New-Object 'System.Collections.Generic.List[string]')
    }
}

# Mock only operating-system boundaries. No native session type is loaded by these tests.
function Get-OneDragonCleanupChildSession {
    $fixture.QueryCalls++
    if ($fixture.QueryFails) { throw 'Simulated child-session query failure.' }
    return $fixture.CurrentChild
}

function Test-OneDragonCleanupSessionPresent([int]$SessionId) {
    if ($fixture.SessionQueryFails) { throw 'Simulated session enumeration failure.' }
    if ($SessionId -ne 7) { throw 'An unowned session was queried for teardown.' }
    return $fixture.SessionPresent
}

function Request-OneDragonCleanupLogoff([int]$SessionId) {
    $fixture.Logoffs.Add($SessionId)
    if ($fixture.LogoffFails) { throw 'Simulated native logoff refusal.' }
    if ($fixture.LogoffCompletes) {
        $fixture.SessionPresent = $false
        if ($fixture.CurrentChild -eq $SessionId) { $fixture.CurrentChild = $null }
    }
    if ($fixture.ExitOnLogoff) { $fixture.LauncherExited = $true; $fixture.HostExited = $true }
}

function Test-OneDragonCleanupProcessExited($Process) {
    if ($Process.Kind -eq 'launcher') { return $fixture.LauncherExited }
    if ($Process.Kind -eq 'host') { return $fixture.HostExited }
    throw 'An unowned process was queried for teardown.'
}

function Wait-OneDragonCleanupProcessExit($Process) {
    $fixture.WaitCalls++
    if ($fixture.WaitFails) { throw 'Simulated host wait failure.' }
    if ($fixture.ExitOnWait) { $fixture.LauncherExited = $true; $fixture.HostExited = $true }
    if ($fixture.ClearSessionOnWait) {
        $fixture.SessionPresent = $false
        if ($fixture.CurrentChild -eq 7) { $fixture.CurrentChild = $null }
    }
    return $fixture.LauncherExited
}

function Test-OneDragonCleanupHostChildrenExited($DesktopHost) {
    return $fixture.HostChildrenExited
}

function Request-OneDragonCleanupHostStop([string]$RunDirectory) {
    $fixture.Stops.Add($RunDirectory)
    if ($fixture.StopFails) { throw 'Simulated stop marker failure.' }
}

function Wait-OneDragonCleanupPoll {
    $fixture.Polls++
    if ($fixture.ClearOnPoll -gt 0 -and $fixture.Polls -ge $fixture.ClearOnPoll) {
        $fixture.SessionPresent = $false
        if ($fixture.CurrentChild -eq 7) { $fixture.CurrentChild = $null }
        $fixture.LauncherExited = $true
        $fixture.HostExited = $true
    }
}

function Remove-OneDragonCleanupTask([string]$TaskName) {
    $fixture.RemovedTasks.Add($TaskName)
    if ($fixture.TaskCleanupFails) { throw 'Simulated owned task cleanup failure.' }
}

# Any accidental fallback to broad process or filesystem actions must fail the test.
function Stop-Process { throw 'Tests must never stop a real process.' }
function Start-Process { throw 'Tests must never start a real process.' }
function New-Item { throw 'Tests must never create a real stop file.' }

$launcher = [pscustomobject]@{ Kind = 'launcher'; Id = 501; ExitCode = 0 }
$hostProcess = [pscustomobject]@{ Kind = 'host'; Id = 502 }
$taskName = 'BetterGI-OneDragon-0123456789abcdef0123456789abcdef'
$directory = 'C:\Fixture\run\attempt-1'
$common = @{ DesktopHost = $launcher; HostProcess = $hostProcess; ChildSession = 7; TaskName = $taskName; RunDirectory = $directory; ParentSession = 1 }

Reset-Fixture
$result = Complete-OneDragonAttempt -DesktopHost $null -ChildSession $null -TaskName $null -RunDirectory $directory -ParentSession 1
Assert-Case 'failure_before_any_resource_creation_can_retry' ($result.Succeeded -and $fixture.Logoffs.Count -eq 0 -and @($result).Count -eq 1)

Reset-Fixture
$fixture.CurrentChild = 7; $fixture.SessionPresent = $true
$fixture.LauncherExited = $false; $fixture.HostExited = $false
$result = Complete-OneDragonAttempt @common
Assert-Case 'graceful_stop_confirms_all_owned_resources_gone' ($result.Succeeded -and $fixture.Stops[0] -eq $directory -and $fixture.WaitCalls -eq 1 -and $fixture.Logoffs.Count -eq 0 -and $fixture.RemovedTasks[0] -eq $taskName)

Reset-Fixture
$fixture.CurrentChild = 7; $fixture.SessionPresent = $true
$fixture.LauncherExited = $false; $fixture.HostExited = $false
$fixture.ExitOnWait = $false; $fixture.ClearSessionOnWait = $false
$result = Complete-OneDragonAttempt @common
Assert-Case 'fallback_logoff_targets_only_the_recorded_child' ($result.Succeeded -and $fixture.Logoffs.Count -eq 1 -and $fixture.Logoffs[0] -eq 7)

Reset-Fixture
$fixture.CurrentChild = 7; $fixture.SessionPresent = $true
$fixture.LauncherExited = $false; $fixture.HostExited = $false; $fixture.StopFails = $true
$fixture.LogoffCompletes = $false; $fixture.ExitOnLogoff = $false; $fixture.ClearOnPoll = 1
$result = Complete-OneDragonAttempt @common
Assert-Case 'stop_marker_failure_still_logs_off_owned_child_and_verifies_teardown' (-not $result.Succeeded -and $result.Detail -match 'Simulated stop marker failure' -and $fixture.Logoffs.Count -eq 1 -and $fixture.Logoffs[0] -eq 7 -and $fixture.Polls -eq 1 -and $fixture.QueryCalls -eq 2)

Reset-Fixture
$fixture.CurrentChild = 7; $fixture.SessionPresent = $true
$fixture.LauncherExited = $false; $fixture.HostExited = $false; $fixture.WaitFails = $true
$fixture.LogoffCompletes = $false; $fixture.ExitOnLogoff = $false; $fixture.ClearOnPoll = 1
$result = Complete-OneDragonAttempt @common
Assert-Case 'host_wait_failure_still_logs_off_owned_child_and_verifies_teardown' (-not $result.Succeeded -and $result.Detail -match 'Simulated host wait failure' -and $fixture.Logoffs.Count -eq 1 -and $fixture.Logoffs[0] -eq 7 -and $fixture.Polls -eq 1 -and $fixture.QueryCalls -eq 2)

Reset-Fixture
$fixture.CurrentChild = 7; $fixture.SessionPresent = $true
$fixture.LauncherExited = $false; $fixture.HostExited = $false
$fixture.ExitOnWait = $false; $fixture.ClearSessionOnWait = $false
$fixture.LogoffCompletes = $false; $fixture.ExitOnLogoff = $false; $fixture.ClearOnPoll = 3
$result = Complete-OneDragonAttempt @common
Assert-Case 'asynchronous_logoff_waits_for_actual_disappearance' ($result.Succeeded -and $fixture.Polls -eq 3)

Reset-Fixture
$fixture.CurrentChild = 7; $fixture.SessionPresent = $true
$fixture.LogoffCompletes = $false; $fixture.ExitOnLogoff = $false
$result = Complete-OneDragonAttempt @common
Assert-Case 'accepted_logoff_with_surviving_session_blocks_retry' (-not $result.Succeeded -and $fixture.Polls -eq 60)

Reset-Fixture
$fixture.LauncherExited = $false; $fixture.ExitOnWait = $false
$result = Complete-OneDragonAttempt @common
Assert-Case 'surviving_launcher_blocks_retry_even_when_session_is_gone' (-not $result.Succeeded -and $fixture.Polls -eq 60)

Reset-Fixture
$fixture.HostExited = $false
$result = Complete-OneDragonAttempt @common
Assert-Case 'surviving_host_powershell_blocks_retry_even_when_launcher_exited' (-not $result.Succeeded -and $fixture.Polls -eq 60)

Reset-Fixture
$fixture.CurrentChild = 9
$result = Complete-OneDragonAttempt -DesktopHost $null -ChildSession $null -TaskName $null -RunDirectory $directory -ParentSession 1
Assert-Case 'preexisting_unowned_child_blocks_retry_without_logoff' (-not $result.Succeeded -and $fixture.Logoffs.Count -eq 0)

Reset-Fixture
$fixture.CurrentChild = 9; $fixture.SessionPresent = $true
$result = Complete-OneDragonAttempt @common
Assert-Case 'replacement_child_is_preserved_while_old_owned_child_is_cleaned' (-not $result.Succeeded -and $fixture.CurrentChild -eq 9 -and $fixture.Logoffs.Count -eq 1 -and $fixture.Logoffs[0] -eq 7)

Reset-Fixture
$result = Complete-OneDragonAttempt -DesktopHost $launcher -ChildSession 1 -TaskName $taskName -RunDirectory $directory -ParentSession 1
Assert-Case 'parent_session_identity_is_rejected_before_any_cleanup' (-not $result.Succeeded -and $fixture.Logoffs.Count -eq 0 -and $fixture.Stops.Count -eq 0 -and $fixture.RemovedTasks.Count -eq 0)

Reset-Fixture
$result = Complete-OneDragonAttempt -DesktopHost $launcher -ChildSession 7 -TaskName 'BetterGI-Daily-OneDragon' -RunDirectory $directory -ParentSession 1
Assert-Case 'daily_or_manual_task_identity_is_rejected_before_cleanup' (-not $result.Succeeded -and $fixture.Logoffs.Count -eq 0 -and $fixture.RemovedTasks.Count -eq 0)

Reset-Fixture
$fixture.QueryFails = $true
$result = Complete-OneDragonAttempt @common
Assert-Case 'unknown_global_session_state_blocks_retry' (-not $result.Succeeded -and $fixture.Logoffs.Count -eq 0)

Reset-Fixture
$fixture.SessionQueryFails = $true
$result = Complete-OneDragonAttempt @common
Assert-Case 'failed_session_enumeration_is_not_treated_as_absence' (-not $result.Succeeded -and $fixture.Logoffs.Count -eq 0)

Reset-Fixture
$fixture.TaskCleanupFails = $true
$fixture.CurrentChild = 7; $fixture.SessionPresent = $true
$result = Complete-OneDragonAttempt @common
Assert-Case 'task_cleanup_failure_blocks_retry_but_other_cleanup_continues' (-not $result.Succeeded -and $fixture.Logoffs.Count -eq 1)

Reset-Fixture
$fixture.CurrentChild = 7; $fixture.SessionPresent = $true; $fixture.LogoffFails = $true
$result = Complete-OneDragonAttempt @common
Assert-Case 'native_logoff_failure_blocks_retry' (-not $result.Succeeded)

Reset-Fixture
$failedLauncher = [pscustomobject]@{ Kind = 'launcher'; Id = 501; ExitCode = 1 }
$fixture.HostChildrenExited = $false
$result = Complete-OneDragonAttempt -DesktopHost $failedLauncher -ChildSession $null -TaskName $null -RunDirectory $directory -ParentSession 1
Assert-Case 'failed_launcher_without_recorded_host_requires_descendant_check' (-not $result.Succeeded)

Reset-Fixture
$result = Complete-OneDragonAttempt -DesktopHost $failedLauncher -ChildSession $null -TaskName $null -RunDirectory $directory -ParentSession 1
Assert-Case 'failed_launcher_with_no_remaining_children_can_retry' $result.Succeeded

# Exercise the real exact-task cleanup adapter against fake Task Scheduler cmdlets.
$script:tasks = @(
    [pscustomobject]@{ TaskName = $taskName; State = 'Queued' },
    [pscustomobject]@{ TaskName = 'BetterGI-Daily-OneDragon'; State = 'Running' },
    [pscustomobject]@{ TaskName = 'User-Manual-BetterGI'; State = 'Running' }
)
$script:stoppedTasks = @()
function Get-ScheduledTask {
    [CmdletBinding()]param([string]$TaskPath)
    if ($TaskPath -ne '\BetterGI\') { throw 'Unexpected task folder.' }
    return $script:tasks
}
function Stop-ScheduledTask {
    [CmdletBinding()]param($InputObject)
    $script:stoppedTasks += $InputObject.TaskName
}
function Unregister-ScheduledTask {
    [CmdletBinding()]param($InputObject, [switch]$Confirm)
    $script:tasks = @($script:tasks | Where-Object TaskName -NE $InputObject.TaskName)
}
& $removeTaskImplementation $taskName
Assert-Case 'queued_owned_task_is_removed_without_touching_daily_or_manual_tasks' ($script:tasks.Count -eq 2 -and $script:stoppedTasks.Count -eq 1 -and $script:stoppedTasks[0] -eq $taskName)
& $removeTaskImplementation $taskName
Assert-Case 'already_removed_owned_task_cleanup_is_idempotent' ($script:tasks.Count -eq 2 -and $script:stoppedTasks.Count -eq 1)

# Replay the real Windows no-child response, while keeping all other query failures distinct.
function Read-OneDragonCleanupChildSession { return $script:nativeQuery }
$script:nativeQuery = [pscustomobject]@{ Succeeded = $false; SessionId = [uint32]::MaxValue; ErrorCode = 1168 }
$child = & $getChildImplementation
Assert-Case 'windows_not_found_with_absent_id_is_a_confirmed_no_child_result' ($null -eq $child)
$script:nativeQuery = [pscustomobject]@{ Succeeded = $false; SessionId = [uint32]::MaxValue; ErrorCode = 5 }
$rejected = $false
try { $null = & $getChildImplementation } catch { $rejected = $true }
Assert-Case 'access_denied_is_never_treated_as_no_child' $rejected
$script:nativeQuery = [pscustomobject]@{ Succeeded = $false; SessionId = 7; ErrorCode = 1168 }
$rejected = $false
try { $null = & $getChildImplementation } catch { $rejected = $true }
Assert-Case 'inconsistent_not_found_response_is_rejected' $rejected
$script:nativeQuery = [pscustomobject]@{ Succeeded = $true; SessionId = 7; ErrorCode = 0 }
Assert-Case 'successful_native_query_preserves_the_child_id' ((& $getChildImplementation) -eq 7)
