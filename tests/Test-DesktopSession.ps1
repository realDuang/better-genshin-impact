param([string]$SourcePath=(Join-Path $PSScriptRoot '..\Automation\DesktopSession.cs'))
$ErrorActionPreference='Stop'
Add-Type -Path $SourcePath -ReferencedAssemblies System.dll,System.Core.dll,System.Windows.Forms.dll,System.Drawing.dll

function Assert-Case([string]$name,[bool]$passed) {
    if(-not $passed){throw "Desktop-session regression failed: $name"}
    [pscustomobject]@{Case=$name;Passed=$true}|ConvertTo-Json -Compress
}

function New-Session([int]$id,[string]$user,[int]$state,[int]$protocol=0) {
    $session=New-Object DesktopSessionInfo
    $session.Id=$id;$session.User=$user;$session.State=$state;$session.Protocol=$protocol
    return $session
}

$child=New-Session 10 'test-user' 0
$state=New-Object RdpLogonState
$state.Observe('connected',0)
Assert-Case 'transport_connected_is_not_a_logged_on_desktop' (-not $state.IsReady($child,'test-user'))
$state.Observe('logon',-2)
Assert-Case 'continue_logon_notification_is_not_completion' (-not $state.IsReady($child,'test-user'))
$state.Observe('login-complete',0)
Assert-Case 'login_complete_with_active_expected_user_is_ready' $state.IsReady($child,'test-user')
Assert-Case 'different_user_cannot_receive_the_game' (-not $state.IsReady($child,'another-user'))
Assert-Case 'missing_child_session_is_not_ready' (-not $state.IsReady($null,'test-user'))
$child.State=4
Assert-Case 'disconnected_child_is_not_ready' (-not $state.IsReady($child,'test-user'))
$child.State=0
$state.Observe('disconnected',12)
Assert-Case 'disconnect_revokes_logon_readiness' (-not $state.IsReady($child,'test-user'))

# Replay the real 2026-10-08 failure: Connected, child ID, logon code 0xFFFFFFF8, no LoginComplete.
$night=New-Object RdpLogonState
$night.Observe('connected',0)
$night.Observe('logon',-8)
Assert-Case 'nighttime_arbitration_failure_blocks_launch' (-not $night.IsReady($child,'test-user'))
Assert-Case 'nighttime_failure_preserves_the_native_error' ($night.Failure.Contains('0xFFFFFFF8'))
