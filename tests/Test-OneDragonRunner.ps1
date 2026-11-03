param(
    [string]$SourceDirectory = (Join-Path $PSScriptRoot '..\Automation'),
    [string]$FixturePath,
    [ValidateSet('success', 'retry-success', 'retry-failure', 'cleanup-failure', 'preexisting-child', 'manual-success', 'business-failure', 'evidence-incomplete', 'evaluation-failure', 'no-publish')]
    [string]$Scenario = 'success'
)
$ErrorActionPreference = 'Stop'

if ($FixturePath) {
    $fixtureRoot = [IO.Path]::GetFullPath($FixturePath)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $fixtureRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path (Split-Path $fixtureRoot -Parent) -Leaf) -notlike 'bettergi-runner-test-*') {
        throw 'The child harness accepts only its temporary fixture directory.'
    }
    # Run the real orchestration in a separate PowerShell process. Only operating-system
    # boundaries below are mocked; production retry, cleanup, and finally blocks remain intact.
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;

public sealed class RunnerTestProcess {
    public int Id;
    public int SessionId;
    public string Path;
    public string ProcessName;
    public DateTime StartTime;
    public bool HasExited;
    public int ExitCode;
    public IntPtr Handle { get { return new IntPtr(Id); } }
    public bool WaitForExit(int milliseconds) {
        if (!File.Exists(System.IO.Path.Combine(RunnerTestEnvironment.AttemptDirectory, "child-host.stop")))
            throw new InvalidOperationException("Host wait happened before its stop request.");
        RunnerTestEnvironment.Events.Add("host-stop:" + RunnerTestEnvironment.StartCount);
        if (RunnerTestEnvironment.CleanupFails) return false;
        HasExited = true;
        RunnerTestEnvironment.HostProcess.HasExited = true;
        RunnerTestEnvironment.ChildAlive = false;
        RunnerTestEnvironment.CurrentChild = UInt32.MaxValue;
        return true;
    }
}
public sealed class RunnerTestSession {
    public int Id;
}
public static class RunnerTestEnvironment {
    public static int ParentSession = 7;
    public static int StartCount;
    public static int RunCount;
    public static int ReportCount;
    public static int EvaluationCount;
    public static int ShutdownCount;
    public static bool CleanupFails;
    public static bool ChildAlive;
    public static bool TaskExists;
    public static uint CurrentChild = UInt32.MaxValue;
    public static string AttemptDirectory;
    public static string TaskName;
    public static string Executable;
    public static int[] ExitCodes;
    public static RunnerTestProcess DesktopHost;
    public static RunnerTestProcess HostProcess;
    public static RunnerTestProcess BetterGi;
    public static RunnerTestTask Task;
    public static List<string> Events = new List<string>();
    public static List<int> ChildIds = new List<int>();
    public static List<int> BetterGiIds = new List<int>();
    public static List<int> LoggedOffIds = new List<int>();
    public static List<string> AttemptDirectories = new List<string>();
    public static List<string> RemovedTasks = new List<string>();
    public static void Logoff(uint id) {
        if (id != CurrentChild || id == ParentSession || id == 900)
            throw new InvalidOperationException("Cleanup tried to log off an unowned session.");
        LoggedOffIds.Add((int)id);
        Events.Add("logoff:" + id);
        if (!CleanupFails) { ChildAlive = false; CurrentChild = UInt32.MaxValue; }
    }
}
public static class OneDragonSession {
    public static bool WTSIsChildSessionsEnabled(out bool enabled) { enabled = true; return true; }
    public static bool WTSEnableChildSessions(bool enabled) { return true; }
    public static bool WTSGetChildSessionId(out uint session) {
        session = RunnerTestEnvironment.CurrentChild;
        return true;
    }
    public static bool WTSLogoffSession(IntPtr server, uint session, bool wait) {
        RunnerTestEnvironment.Logoff(session);
        return true;
    }
}
public static class DesktopSessions {
    public static RunnerTestSession Find(int id) {
        return RunnerTestEnvironment.ChildAlive && id == RunnerTestEnvironment.CurrentChild
            ? new RunnerTestSession { Id = id } : null;
    }
}
public sealed class RunnerTestMutex {
    public bool WaitOne(int timeout) { return true; }
    public void ReleaseMutex() { RunnerTestEnvironment.Events.Add("mutex-release"); }
    public void Dispose() { }
}
public sealed class RunnerTestTask {
    private int polls;
    public int LastTaskResult;
    public int State {
        get {
            polls++;
            if (polls < 2) return 4;
            RunnerTestEnvironment.BetterGi.HasExited = true;
            return 3;
        }
    }
    public object RunEx(object parameters, int flags, int session, object user) {
        if (flags != 4 || session != RunnerTestEnvironment.CurrentChild)
            throw new InvalidOperationException("Task was not launched in the fresh child session.");
        RunnerTestEnvironment.RunCount++;
        RunnerTestEnvironment.Events.Add("task-run:" + RunnerTestEnvironment.RunCount);
        return this;
    }
}
public sealed class RunnerTestFolder {
    public RunnerTestTask GetTask(string name) {
        if (name != RunnerTestEnvironment.TaskName) throw new InvalidOperationException("Unexpected task.");
        return RunnerTestEnvironment.Task;
    }
}
public sealed class RunnerTestScheduler {
    public void Connect() { }
    public RunnerTestFolder GetFolder(string path) { return new RunnerTestFolder(); }
}
'@
    $bootTime = (Get-Date).AddMinutes(-10)
    $bootEpoch = ([DateTimeOffset]$bootTime).ToUnixTimeSeconds()
    $control = @{day=(Get-Date -Format 'yyyy-MM-dd'); mode='wake'; shutdownEligible=$true; issued=$bootEpoch-5; boot=$bootEpoch; observed=$bootEpoch+5}
    $control | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixtureRoot 'state\daily-control.json') -Encoding UTF8
    [RunnerTestEnvironment]::Executable = Join-Path $fixtureRoot 'BetterGI.exe'
    [RunnerTestEnvironment]::CleanupFails = $Scenario -eq 'cleanup-failure'
    [RunnerTestEnvironment]::ExitCodes = switch ($Scenario) {
        'retry-success' { @(-1073741819, 0) }
        'retry-failure' { @(-1073741819, -1073741819) }
        'cleanup-failure' { @(-1073741819) }
        default { @(0) }
    }
    if ($Scenario -eq 'preexisting-child') {
        [RunnerTestEnvironment]::CurrentChild = 900
        [RunnerTestEnvironment]::ChildAlive = $true
    }

    function Add-Type { param($Path, $TypeDefinition, $ReferencedAssemblies) }
    function Start-Sleep { param($Seconds, $Milliseconds) }
    function New-Object {
        param([Parameter(Position=0)]$TypeName, [Parameter(Position=1)]$ArgumentList, [string]$ComObject)
        if ($ComObject) {
            if ($ComObject -ne 'Schedule.Service') { throw "Unexpected COM object: $ComObject" }
            return [RunnerTestScheduler]::new()
        }
        if ($TypeName -eq 'Threading.Mutex') { return [RunnerTestMutex]::new() }
        if ($TypeName -notin @('System.Collections.Generic.List[object]', 'System.Collections.Generic.List[string]')) {
            throw "Unexpected object construction: $TypeName"
        }
        Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList
    }
    function Start-Process {
        param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru)
        if ($FilePath -ne (Join-Path $fixtureRoot 'Automation\HeadlessLauncher.exe') -or $WindowStyle -ne 'Hidden' -or -not $PassThru) {
            throw 'An unexpected process launch reached the test boundary.'
        }
        if ([RunnerTestEnvironment]::ChildAlive) { throw 'A new attempt started before cleanup completed.' }
        [RunnerTestEnvironment]::StartCount++
        $number = [RunnerTestEnvironment]::StartCount
        if ($number -gt 2) { throw 'A third attempt was launched.' }
        $directory = [string]$ArgumentList[-1]
        $directory = $directory.Trim('"')
        if (-not $directory.StartsWith($fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Host output escaped the fixture.' }
        [RunnerTestEnvironment]::AttemptDirectory = $directory
        [RunnerTestEnvironment]::AttemptDirectories.Add($directory)
        [RunnerTestEnvironment]::Events.Add("host-start:$number")
        [RunnerTestEnvironment]::CurrentChild = 200 + $number
        [RunnerTestEnvironment]::ChildAlive = $true
        [RunnerTestEnvironment]::ChildIds.Add(200 + $number)
        $started = Get-Date
        $desktopProcess = [RunnerTestProcess]::new()
        $desktopProcess.Id = 1000 + $number; $desktopProcess.StartTime = $started; $desktopProcess.SessionId = 7
        $worker = [RunnerTestProcess]::new()
        $worker.Id = 2000 + $number; $worker.StartTime = $started.AddMilliseconds(1); $worker.SessionId = 7
        $worker.ProcessName = 'powershell'
        $bgi = [RunnerTestProcess]::new()
        $bgi.Id = 3000 + $number; $bgi.SessionId = 200 + $number; $bgi.Path = [RunnerTestEnvironment]::Executable
        [RunnerTestEnvironment]::BetterGiIds.Add($bgi.Id)
        [RunnerTestEnvironment]::DesktopHost = $desktopProcess
        [RunnerTestEnvironment]::HostProcess = $worker
        [RunnerTestEnvironment]::BetterGi = $bgi
        @{State='ready'; LoginCompleted=$true; ParentSession=7; HostPid=$worker.Id; ChildSession=(200+$number)} |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'child-host-status.json') -Encoding UTF8
        return $desktopProcess
    }
    function Get-CimInstance {
        param([Parameter(Position=0)]$ClassName, $Filter)
        if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{LastBootUpTime=$bootTime} }
        if ($ClassName -ne 'Win32_Process') { throw "Unexpected CIM class: $ClassName" }
        $worker = [RunnerTestEnvironment]::HostProcess
        if ($worker -and $Filter -eq "ProcessId=$($worker.Id)") {
            return [pscustomobject]@{ProcessId=$worker.Id; ParentProcessId=[RunnerTestEnvironment]::DesktopHost.Id; SessionId=7; Name='powershell.exe'; CreationDate=$worker.StartTime}
        }
        if ($Filter -like 'ParentProcessId=*') { return @() }
        throw "Unexpected process query: $Filter"
    }
    function Get-Process {
        param($Name, $Id)
        if ($Id) {
            if ($Id -ne [RunnerTestEnvironment]::HostProcess.Id) { throw "Unexpected process ID: $Id" }
            return [RunnerTestEnvironment]::HostProcess
        }
        if ($Name -ne 'BetterGI') { throw "Unexpected process lookup: $Name" }
        [pscustomobject]@{Id=4000; SessionId=7; Path=[RunnerTestEnvironment]::Executable}
        if ([RunnerTestEnvironment]::BetterGi -and -not [RunnerTestEnvironment]::BetterGi.HasExited) { [RunnerTestEnvironment]::BetterGi }
    }
    function Stop-Process { throw 'No real or mocked process may be killed by this runner test.' }
    function New-ScheduledTaskAction { param($Execute, $Argument, $WorkingDirectory) [pscustomobject]@{Execute=$Execute; Argument=$Argument; WorkingDirectory=$WorkingDirectory} }
    function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) [pscustomobject]@{UserId=$UserId} }
    function New-ScheduledTaskSettingsSet {
        param($ExecutionTimeLimit, [switch]$Hidden, [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries)
        if ($ExecutionTimeLimit -ne [TimeSpan]::Zero) { throw 'The runner added a task timeout.' }
        [pscustomobject]@{ExecutionTimeLimit=$ExecutionTimeLimit}
    }
    function Register-ScheduledTask {
        param($TaskPath, $TaskName, $Action, $Principal, $Settings)
        if ($TaskPath -ne '\BetterGI\' -or $TaskName -notmatch '^BetterGI-OneDragon-[0-9a-f]{32}$' -or $Action.Execute -ne [RunnerTestEnvironment]::Executable) {
            throw 'Unexpected task registration.'
        }
        if ($Action.Argument -ne 'startOneDragon "Fixture" --instance childSession') { throw 'The OneDragon command changed.' }
        [RunnerTestEnvironment]::TaskName = $TaskName
        [RunnerTestEnvironment]::TaskExists = $true
        $task = [RunnerTestTask]::new()
        $task.LastTaskResult = [RunnerTestEnvironment]::ExitCodes[[RunnerTestEnvironment]::StartCount-1]
        [RunnerTestEnvironment]::Task = $task
    }
    function Get-ScheduledTask {
        param($TaskPath, $TaskName)
        [pscustomobject]@{TaskName='Unrelated-User-Task'; State='Ready'}
        if ([RunnerTestEnvironment]::TaskExists) { [pscustomobject]@{TaskName=[RunnerTestEnvironment]::TaskName; State='Ready'} }
    }
    function Stop-ScheduledTask { param($InputObject) throw 'The mock completed task must not be stopped.' }
    function Unregister-ScheduledTask {
        param($InputObject, [switch]$Confirm)
        if ($InputObject.TaskName -ne [RunnerTestEnvironment]::TaskName) { throw 'An unrelated task was removed.' }
        [RunnerTestEnvironment]::RemovedTasks.Add($InputObject.TaskName)
        [RunnerTestEnvironment]::Events.Add("task-remove:$([RunnerTestEnvironment]::StartCount)")
        [RunnerTestEnvironment]::TaskExists = $false
    }
    function Invoke-RunnerTestEvaluation {
        param($RunDirectory)
        $final = Get-Content -LiteralPath (Join-Path $RunDirectory 'status.json') -Raw | ConvertFrom-Json
        if ($final.Phase -ne 'finished' -or [RunnerTestEnvironment]::ReportCount -ne 0) {
            throw 'Business evaluation did not run after all attempts and before publishing.'
        }
        $count = [RunnerTestEnvironment]::StartCount
        if ($count -gt 0 -and -not [RunnerTestEnvironment]::Events.Contains("host-stop:$count")) {
            throw 'Business evaluation ran before child cleanup.'
        }
        [RunnerTestEnvironment]::EvaluationCount++
        [RunnerTestEnvironment]::Events.Add('evaluation')
        $global:LASTEXITCODE = if ($Scenario -eq 'evaluation-failure') { 1 } else { 0 }
        if ($global:LASTEXITCODE -ne 0) { return 'Evaluation failed.' }
        $outcome = switch ($Scenario) {
            'business-failure' { 'partial' }
            'evidence-incomplete' { 'incomplete' }
            'preexisting-child' { 'incomplete' }
            default { 'finished' }
        }
        $code = $final.ExitCode
        if ($code -eq 0) {
            if ($outcome -eq 'partial') { $code = 2 }
            elseif ($outcome -eq 'incomplete') { $code = 3 }
        }
        @{ProcessExitCode=$final.ProcessExitCode; ExitCode=$code; BusinessOutcome=$outcome; BusinessEvidenceIssues=@()} |
            ConvertTo-Json -Compress
    }
    function Invoke-RunnerTestReport {
        param($RunDirectory)
        $final = Get-Content -LiteralPath (Join-Path $RunDirectory 'status.json') -Raw | ConvertFrom-Json
        if ($final.Phase -ne 'finished' -or [RunnerTestEnvironment]::EvaluationCount -ne 1 -or $final.BusinessOutcome -eq 'unknown') { throw 'Reporting ran before the final business outcome was saved.' }
        [RunnerTestEnvironment]::ReportCount++
        [RunnerTestEnvironment]::Events.Add("report:$($final.AttemptCount)")
        $global:LASTEXITCODE = 0
    }
    function Invoke-RunnerTestShutdown {
        if ([RunnerTestEnvironment]::ReportCount -ne 1) { throw 'Shutdown ran before the single final report.' }
        [RunnerTestEnvironment]::ShutdownCount++
        [RunnerTestEnvironment]::Events.Add('shutdown')
        $global:LASTEXITCODE = 0
    }

    $runner = Join-Path $fixtureRoot 'Automation\Invoke-HeadlessOneDragon.ps1'
    $runExit = 1
    try {
        if ($Scenario -eq 'no-publish') { & $runner -ProfileName Fixture -NoPublish }
        elseif ($Scenario -in @('preexisting-child', 'manual-success')) { & $runner -ProfileName Fixture }
        else { & $runner -ProfileName Fixture -Scheduled }
        $runExit = $LASTEXITCODE
    } finally {
        [ordered]@{
            StartCount=[RunnerTestEnvironment]::StartCount; RunCount=[RunnerTestEnvironment]::RunCount
            ReportCount=[RunnerTestEnvironment]::ReportCount; EvaluationCount=[RunnerTestEnvironment]::EvaluationCount; ShutdownCount=[RunnerTestEnvironment]::ShutdownCount
            Events=@([RunnerTestEnvironment]::Events); ChildIds=@([RunnerTestEnvironment]::ChildIds)
            BetterGiIds=@([RunnerTestEnvironment]::BetterGiIds); AttemptDirectories=@([RunnerTestEnvironment]::AttemptDirectories)
            LoggedOffIds=@([RunnerTestEnvironment]::LoggedOffIds); RemovedTasks=@([RunnerTestEnvironment]::RemovedTasks)
            CurrentChild=[RunnerTestEnvironment]::CurrentChild; ChildAlive=[RunnerTestEnvironment]::ChildAlive
            TaskExists=[RunnerTestEnvironment]::TaskExists
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $fixtureRoot 'mock-state.json') -Encoding UTF8
    }
    exit $runExit
}

function Assert-RunnerCase([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Runner integration failed: $Message" }
}
function Replace-RunnerBoundary([string]$Text, [string]$Old, [string]$New) {
    Assert-RunnerCase ($Text.Contains($Old)) "Production boundary changed: $Old"
    return $Text.Replace($Old, $New)
}

$sourceRoot = [IO.Path]::GetFullPath($SourceDirectory)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('bettergi-runner-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$utf8 = [Text.UTF8Encoding]::new($true)
try {
    foreach ($case in @('success', 'retry-success', 'retry-failure', 'cleanup-failure', 'preexisting-child', 'manual-success', 'business-failure', 'evidence-incomplete', 'evaluation-failure', 'no-publish')) {
        $fixture = Join-Path $testRoot $case
        foreach ($relative in @('Automation', 'User\OneDragon', 'state', 'log')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $fixture $relative) -Force
        }
        foreach ($name in @('OneDragonRetry.ps1', 'OneDragonCleanup.ps1', 'OneDragonPower.ps1', 'DesktopSession.cs')) {
            Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $fixture ('Automation\' + $name))
        }
        foreach ($relative in @('BetterGI.exe', 'Automation\HeadlessLauncher.exe')) { [IO.File]::WriteAllText((Join-Path $fixture $relative), '') }
        $completion = -join (@(0x5173,0x95ED,0x6E38,0x620F,0x548C,0x8F6F,0x4EF6) | ForEach-Object { [char]$_ })
        @{Name='Fixture'; CompletionAction=$completion} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'User\OneDragon\Fixture.json') -Encoding UTF8
        @{genshinStartConfig=@{linkedStartEnabled=$true}} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'User\config.json') -Encoding UTF8
        $text = Get-Content -LiteralPath (Join-Path $sourceRoot 'Invoke-HeadlessOneDragon.ps1') -Raw -Encoding UTF8
        $text = Replace-RunnerBoundary $text "`$stateDirectory = 'C:\ProgramData\BetterGI-Automation'" ("`$stateDirectory = '{0}'" -f (Join-Path $fixture 'state').Replace("'", "''"))
        $text = Replace-RunnerBoundary $text '[Diagnostics.Process]::GetCurrentProcess().SessionId' '[RunnerTestEnvironment]::ParentSession'
        $evaluationCall = "& 'C:\Python314\python.exe' (Join-Path `$PSScriptRoot 'evaluate_bettergi_result.py') --run-dir `$runDirectory"
        $text = Replace-RunnerBoundary $text $evaluationCall 'Invoke-RunnerTestEvaluation -RunDirectory $runDirectory'
        $reportCall = "& 'C:\Python314\python.exe' (Join-Path `$PSScriptRoot 'publish_bettergi_report.py') --run-dir `$runDirectory --config (Join-Path `$stateDirectory 'reporting.json')"
        $text = Replace-RunnerBoundary $text $reportCall 'Invoke-RunnerTestReport -RunDirectory $runDirectory'
        $text = Replace-RunnerBoundary $text '& "$env:SystemRoot\System32\shutdown.exe" /s /t 0' 'Invoke-RunnerTestShutdown'
        [IO.File]::WriteAllText((Join-Path $fixture 'Automation\Invoke-HeadlessOneDragon.ps1'), $text, $utf8)
        $output = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -FixturePath $fixture -Scenario $case 2>&1
        $actualExit = $LASTEXITCODE
        $mockPath = Join-Path $fixture 'mock-state.json'
        Assert-RunnerCase (Test-Path -LiteralPath $mockPath) "$case did not produce mock evidence: $output"
        $mock = Get-Content -LiteralPath $mockPath -Raw | ConvertFrom-Json
        $final = Get-Content -LiteralPath (Join-Path $fixture 'state\latest-run.json') -Raw | ConvertFrom-Json
        $expectedStarts = if ($case -eq 'preexisting-child') { 0 } elseif ($case -like 'retry-*') { 2 } else { 1 }
        $expectedAttempts = [Math]::Max(1, $expectedStarts)
        $shouldSucceed = $case -in @('success', 'retry-success', 'manual-success', 'no-publish')
        Assert-RunnerCase (($actualExit -eq 0) -eq $shouldSucceed) "$case exit=$actualExit; output=$output"
        Assert-RunnerCase ($mock.StartCount -eq $expectedStarts -and $mock.RunCount -eq $expectedStarts) "$case launch count"
        Assert-RunnerCase ($final.AttemptCount -eq $expectedAttempts -and @($final.Attempts).Count -eq $expectedAttempts) "$case final attempt count"
        Assert-RunnerCase ($mock.EvaluationCount -eq 1) "$case must evaluate exactly once"
        $expectedReports = if ($case -eq 'no-publish') { 0 } else { 1 }
        Assert-RunnerCase ($mock.ReportCount -eq $expectedReports) "$case report count"
        if ($case -in @('business-failure', 'evidence-incomplete', 'evaluation-failure')) {
            $expectedCode = if ($case -eq 'business-failure') { 2 } else { 3 }
            $expectedOutcome = if ($case -eq 'business-failure') { 'partial' } else { 'incomplete' }
            Assert-RunnerCase ($actualExit -eq $expectedCode -and $final.ExitCode -eq $expectedCode) "$case scheduled result"
            Assert-RunnerCase ($final.BusinessOutcome -eq $expectedOutcome -and $final.ProcessExitCode -eq 0) "$case process and business results"
            Assert-RunnerCase ($final.Attempts[0].ExitCode -eq 0 -and $final.Attempts[0].ProcessExitCode -eq 0) "$case must not rewrite process history or retry"
        }
        $expectedShutdown = if ($case -in @('manual-success', 'preexisting-child', 'no-publish')) { 0 } else { 1 }
        Assert-RunnerCase ($mock.ShutdownCount -eq $expectedShutdown) "$case shutdown count"
        Assert-RunnerCase (-not $mock.TaskExists -and @($mock.RemovedTasks).Count -eq $expectedStarts) "$case owned task cleanup"
        Assert-RunnerCase (@($mock.AttemptDirectories | Select-Object -Unique).Count -eq $expectedStarts) "$case fresh attempt directories"
        Assert-RunnerCase (@($mock.ChildIds | Select-Object -Unique).Count -eq $expectedStarts) "$case fresh child identities"
        Assert-RunnerCase (@($mock.BetterGiIds | Select-Object -Unique).Count -eq $expectedStarts) "$case fresh process identities"
        if ($expectedStarts -eq 2) {
            Assert-RunnerCase ($mock.Events.IndexOf('host-stop:1') -lt $mock.Events.IndexOf('host-start:2')) "$case retried before cleanup"
            Assert-RunnerCase ($mock.Events.IndexOf('report:2') -gt $mock.Events.IndexOf('host-stop:2')) "$case reported before final cleanup"
            Assert-RunnerCase ($final.Attempts[0].ExitCode -eq -1073741819 -and $final.Attempts[0].CleanupSucceeded) "$case preserves first crash evidence"
        }
        if ($case -eq 'cleanup-failure') {
            Assert-RunnerCase (-not $final.Attempts[0].CleanupSucceeded -and -not $final.Attempts[0].Retryable) 'Unverified cleanup must block retry'
        } elseif ($case -eq 'preexisting-child') {
            Assert-RunnerCase ($mock.CurrentChild -eq 900 -and $mock.ChildAlive -and @($mock.LoggedOffIds).Count -eq 0) 'Pre-existing child must remain untouched'
            Assert-RunnerCase (-not $final.Attempts[0].Retryable) 'Pre-existing child must not trigger retry'
        } else {
            Assert-RunnerCase (-not $mock.ChildAlive -and $mock.CurrentChild -eq [uint32]::MaxValue) "$case child teardown"
        }
        [pscustomobject]@{Case=$case; Passed=$true; Attempts=$final.AttemptCount; Reports=$mock.ReportCount; Shutdowns=$mock.ShutdownCount} | ConvertTo-Json -Compress
    }
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolvedRoot -Leaf) -notlike 'bettergi-runner-test-*') {
        throw 'Refusing cleanup outside the verified runner test directory.'
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
