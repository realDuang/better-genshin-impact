param([string]$ProfileName = 'Headless-Daily', [switch]$Scheduled, [switch]$Check, [switch]$NoPublish)
$ErrorActionPreference = 'Stop'
$installDirectory = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $installDirectory 'BetterGI.exe'
$launcher = Join-Path $PSScriptRoot 'HeadlessLauncher.exe'
$profilePath = Join-Path $installDirectory ("User\OneDragon\{0}.json" -f $ProfileName)
$stateDirectory = 'C:\ProgramData\BetterGI-Automation'
. (Join-Path $PSScriptRoot 'OneDragonPower.ps1')
. (Join-Path $PSScriptRoot 'OneDragonRetry.ps1')
. (Join-Path $PSScriptRoot 'OneDragonCleanup.ps1')

foreach ($path in @($executable, $launcher, $profilePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required file is missing: $path" }
}
$profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($profile.Name -cne $ProfileName -or $profile.CompletionAction -ne '关闭游戏和软件') {
    throw 'The selected profile must close the game and BetterGI when its tasks finish.'
}
$config = Get-Content -LiteralPath (Join-Path $installDirectory 'User\config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $config.genshinStartConfig.linkedStartEnabled) { throw 'Enable BetterGI linked game startup before running OneDragon.' }
if ($Check) {
    foreach ($dependency in @('C:\Python314\python.exe', (Join-Path $PSScriptRoot 'publish_bettergi_report.py'), (Join-Path $PSScriptRoot 'compact_bettergi_log.py'), (Join-Path $PSScriptRoot 'evaluate_bettergi_result.py'), (Join-Path $stateDirectory 'reporting.json'))) {
        if (-not (Test-Path -LiteralPath $dependency -PathType Leaf)) { throw "Reporting dependency is missing: $dependency" }
    }
    Write-Output "Ready: $ProfileName; at most one retry after verified cleanup; shutdown only for this WOL boot."
    exit 0
}

Add-Type -Path (Join-Path $PSScriptRoot 'DesktopSession.cs') -ReferencedAssemblies System.dll,System.Core.dll,System.Windows.Forms.dll,System.Drawing.dll
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OneDragonSession {
    [DllImport("wtsapi32.dll", SetLastError=true)] public static extern bool WTSIsChildSessionsEnabled(out bool enabled);
    [DllImport("wtsapi32.dll", SetLastError=true)] public static extern bool WTSEnableChildSessions(bool enabled);
    [DllImport("wtsapi32.dll", SetLastError=true)] public static extern bool WTSGetChildSessionId(out uint session);
    [DllImport("wtsapi32.dll", SetLastError=true)] public static extern bool WTSLogoffSession(IntPtr server, uint session, bool wait);
}
'@
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDirectory = Join-Path $installDirectory ("log\one-dragon-runs\{0}" -f $runId)
$null = New-Item -ItemType Directory -Path $runDirectory
$status = [ordered]@{
    RunId = $runId; Started = (Get-Date).ToString('o'); Profile = $ProfileName
    Phase = 'starting'; Result = 'running'; ChildSession = $null; BetterGiPid = $null
    ShutdownEligible = $false; ExitCode = $null; Detail = ''; AttemptCount = 0; Attempts = @()
    ProcessExitCode = $null; BusinessOutcome = 'unknown'; BusinessEvidenceIssues = @()
}
$mutex = New-Object Threading.Mutex($false, 'Global\BetterGI-Headless-OneDragon-Runner')
$ownsMutex = $false
$exitCode = 1
$boot = 0L
$parentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId

function Write-RunLog([string]$message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message
    Add-Content -LiteralPath (Join-Path $runDirectory 'runner.log') -Value $line -Encoding UTF8
    Add-Content -LiteralPath (Join-Path $installDirectory 'log\one-dragon-schedule.log') -Value $line -Encoding UTF8
    Write-Host $line
    $status['Updated'] = (Get-Date).ToString('o')
    $json = $status | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $runDirectory 'status.json'), $json, [Text.UTF8Encoding]::new($false))
    if ($ownsMutex) {
        [IO.File]::WriteAllText((Join-Path $stateDirectory 'latest-run.json'), $json, [Text.UTF8Encoding]::new($false))
    }
}

function Invoke-OneDragonAttempt([int]$Number) {
    $attemptDirectory = Join-Path $runDirectory ("attempt-{0}" -f $Number)
    $null = New-Item -ItemType Directory -Path $attemptDirectory
    $attempt = [pscustomobject][ordered]@{
        Number = $Number; Started = (Get-Date).ToString('o'); Updated = $null
        ChildSession = $null; BetterGiPid = $null; ExitCode = 1; ProcessExitCode = $null; Result = 'running'
        Detail = ''; CleanupSucceeded = $false; Retryable = $true
    }
    $status.Attempts += $attempt
    $status.AttemptCount = $Number
    $status.ChildSession = $null; $status.BetterGiPid = $null; $status.ProcessExitCode = $null
    $status.Phase = 'starting attempt'; $status.Result = 'running'; $status.Detail = ''
    $desktopHost = $null; $hostProcess = $null; $taskName = $null
    try {
        $existingChild = Get-OneDragonCleanupChildSession
        if ($null -ne $existingChild) {
            $attempt.Retryable = $false
            throw "A pre-existing child session is in use: $existingChild. It will not be closed."
        }
        Write-RunLog "Attempt $Number starting with a fresh child desktop."
        $desktopHost = Start-Process -FilePath $launcher -ArgumentList @('--host', '-RunDirectory', ('"{0}"' -f $attemptDirectory)) -WindowStyle Hidden -PassThru
        $desktopStatusPath = Join-Path $attemptDirectory 'child-host-status.json'
        do {
            Start-Sleep -Milliseconds 500
            $desktop = $null
            if (Test-Path -LiteralPath $desktopStatusPath) {
                try { $desktop = Get-Content -LiteralPath $desktopStatusPath -Raw | ConvertFrom-Json } catch { continue }
                if ($desktop.ParentSession -ne $parentSession -or $desktop.HostPid -le 0) {
                    $attempt.Retryable = $false
                    throw 'The child-host status has an unexpected identity.'
                }
                if (-not $hostProcess) {
                    $hostInfo = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f [int]$desktop.HostPid)
                    if ($hostInfo) {
                        if ($hostInfo.ParentProcessId -ne $desktopHost.Id -or $hostInfo.SessionId -ne $parentSession -or
                            $hostInfo.Name -ne 'powershell.exe' -or $hostInfo.CreationDate -lt $desktopHost.StartTime) {
                            $attempt.Retryable = $false
                            throw 'The reported host process is not owned by this attempt.'
                        }
                        $hostProcess = Get-Process -Id $hostInfo.ProcessId -ErrorAction SilentlyContinue
                        if ($hostProcess) { $null = $hostProcess.Handle }
                    }
                }
                if ($hostProcess -and $null -ne $desktop.ChildSession) {
                    $childId = [int]$desktop.ChildSession
                    if ($childId -le 0 -or $childId -eq $parentSession -or
                        ($null -ne $attempt.ChildSession -and $attempt.ChildSession -ne $childId)) {
                        $attempt.Retryable = $false
                        throw 'The child-session identity changed or belongs to the parent.'
                    }
                    $attempt.ChildSession = $childId
                    $status.ChildSession = $childId
                }
                if ($desktop.State -in @('failed', 'cleanup-required')) { throw $desktop.Message }
            }
            if ($desktopHost.HasExited) { throw 'The Windows child desktop exited before login completed.' }
        } until ($desktop.State -eq 'ready' -and $desktop.LoginCompleted -and $null -ne $attempt.ChildSession)

        $arguments = 'startOneDragon "{0}"' -f $ProfileName
        $rootInstance = Get-Process -Name BetterGI -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $parentSession -and $_.Path -eq $executable }
        if ($rootInstance) { $arguments += ' --instance childSession' }
        $taskName = 'BetterGI-OneDragon-' + [guid]::NewGuid().ToString('N')
        $action = New-ScheduledTaskAction -Execute $executable -Argument $arguments -WorkingDirectory $installDirectory
        $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $null = Register-ScheduledTask -TaskPath '\BetterGI\' -TaskName $taskName -Action $action -Principal $principal -Settings $settings
        $scheduler = New-Object -ComObject 'Schedule.Service'
        $scheduler.Connect()
        $task = $scheduler.GetFolder('\BetterGI').GetTask($taskName)
        $null = $task.RunEx($null, 4, $attempt.ChildSession, $null)
        $status.Phase = 'running OneDragon'
        Write-RunLog "Attempt ${Number}: child session=$($attempt.ChildSession); launched BetterGI $arguments."
        do {
            Start-Sleep -Seconds 2
            if ($desktopHost.HasExited) { throw 'The child desktop closed while OneDragon was running.' }
            if (-not $attempt.BetterGiPid) {
                $bgi = Get-Process -Name BetterGI -ErrorAction SilentlyContinue | Where-Object SessionId -eq $attempt.ChildSession | Select-Object -First 1
                if ($bgi) {
                    $attempt.BetterGiPid = $bgi.Id; $status.BetterGiPid = $bgi.Id
                    Write-RunLog "Attempt ${Number}: BetterGI PID=$($bgi.Id)."
                }
            }
        } while ($task.State -in @(2, 4))
        $attempt.ProcessExitCode = [int]$task.LastTaskResult
        $attempt.ExitCode = $attempt.ProcessExitCode
        $attempt.Result = if ($attempt.ExitCode -eq 0) { 'exited' } else { 'failed' }
        if ($attempt.ExitCode -ne 0) { $attempt.Detail = "BetterGI exited with code $($attempt.ExitCode)." }
    } catch {
        $attempt.ExitCode = 1; $attempt.Result = 'failed'; $attempt.Detail = $_.Exception.Message
    } finally {
        $cleanup = Complete-OneDragonAttempt -DesktopHost $desktopHost -HostProcess $hostProcess -ChildSession $attempt.ChildSession -TaskName $taskName -RunDirectory $attemptDirectory -ParentSession $parentSession
        $attempt.CleanupSucceeded = $cleanup.Succeeded
        if (-not $cleanup.Succeeded) {
            if ($attempt.ExitCode -eq 0) { $attempt.ExitCode = 1 }
            $attempt.Result = 'failed'; $attempt.Retryable = $false
            $attempt.Detail = ($attempt.Detail + ' Cleanup not confirmed: ' + $cleanup.Detail).Trim()
        }
        $attempt.Updated = (Get-Date).ToString('o')
        $status.Result = $attempt.Result; $status.ExitCode = $attempt.ExitCode; $status.Detail = $attempt.Detail
        $status.ProcessExitCode = $attempt.ProcessExitCode
        [IO.File]::WriteAllText((Join-Path $attemptDirectory 'status.json'), ($attempt | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        Write-RunLog "Attempt $Number ended: exit=$($attempt.ExitCode); cleanup=$($attempt.CleanupSucceeded); $($attempt.Detail)"
    }
    return $attempt
}

try {
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'Another OneDragon run is already active.' }
    $boot = ([DateTimeOffset](Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToUnixTimeSeconds()
    $controlPath = Join-Path $stateDirectory 'daily-control.json'
    $control = if (Test-Path -LiteralPath $controlPath) { Get-Content -LiteralPath $controlPath -Raw | ConvertFrom-Json } else { $null }
    $status.ShutdownEligible = $Scheduled -and (Test-OneDragonWolBoot -Control $control -Boot $boot -Day (Get-Date -Format 'yyyy-MM-dd'))
    [bool]$enabled = $false
    if (-not [OneDragonSession]::WTSIsChildSessionsEnabled([ref]$enabled)) { throw 'Cannot query Windows child-session support.' }
    if (-not $enabled -and -not [OneDragonSession]::WTSEnableChildSessions($true)) { throw 'Cannot enable Windows child sessions.' }
    Write-RunLog "Starting OneDragon profile=$ProfileName; WOL shutdown=$($status.ShutdownEligible)."
    $attempts = @(Invoke-OneDragonWithRetry -RunAttempt { param($number) Invoke-OneDragonAttempt $number } -OnRetry {
        param($previous)
        $status.Phase = 'retrying'
        Write-RunLog "Attempt $($previous.Number) failed and cleanup is complete. Retrying once in a fresh child session."
    })
    $exitCode = $attempts[-1].ExitCode
} catch {
    $exitCode = 1; $status.Result = 'failed'; $status.Detail = $_.Exception.Message
    Write-RunLog "ERROR: $($status.Detail)"
} finally {
    try {
        $status.Phase = 'finished'; $status.ExitCode = $exitCode
        Write-RunLog "OneDragon attempts ended: process exit=$($status.ProcessExitCode); lifecycle exit=$exitCode."
        if ($ownsMutex) {
            try {
                $evaluationJson = & 'C:\Python314\python.exe' (Join-Path $PSScriptRoot 'evaluate_bettergi_result.py') --run-dir $runDirectory
                if ($LASTEXITCODE -ne 0) { throw "Result evaluator exited with code $LASTEXITCODE." }
                $evaluation = $evaluationJson | ConvertFrom-Json
                if ($null -eq $evaluation.ExitCode -or $evaluation.BusinessOutcome -notin @('finished', 'needs-attention', 'partial', 'incomplete', 'unknown')) {
                    throw 'The result evaluator returned an invalid outcome.'
                }
                $status.BusinessOutcome = $evaluation.BusinessOutcome
                $status.BusinessEvidenceIssues = @($evaluation.BusinessEvidenceIssues)
                $exitCode = [int]$evaluation.ExitCode
            } catch {
                $status.BusinessOutcome = 'incomplete'
                $status.BusinessEvidenceIssues = @($_.Exception.Message)
                if ($exitCode -eq 0) { $exitCode = 3 }
            }
            $status.ExitCode = $exitCode
            Write-RunLog "OneDragon run ended after $($status.AttemptCount) attempt(s). Result=$($status.Result); business=$($status.BusinessOutcome); exit=$exitCode; logs=$runDirectory."
            if (-not $NoPublish) {
                try {
                    & 'C:\Python314\python.exe' (Join-Path $PSScriptRoot 'publish_bettergi_report.py') --run-dir $runDirectory --config (Join-Path $stateDirectory 'reporting.json')
                    if ($LASTEXITCODE -ne 0) { Write-RunLog "Report delivery failed with exit code $LASTEXITCODE." }
                } catch { Write-RunLog "Report could not start: $($_.Exception.Message)" }
            }
            if ($status.ShutdownEligible) {
                $currentBoot = ([DateTimeOffset](Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToUnixTimeSeconds()
                if ($currentBoot -eq $boot) {
                    Write-RunLog 'This boot was started by WOL. Shutting down after all attempts.'
                    & "$env:SystemRoot\System32\shutdown.exe" /s /t 0
                }
            }
        }
    } finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
exit $exitCode
