# Scheduled OneDragon

The reference deployment uses a Windows task `\BetterGI\BetterGI-Daily-OneDragon` at 08:00 (UTC+8).
Its only workflow is:

1. Open a background Windows child session.
2. Start `BetterGI.exe startOneDragon "Headless-Daily"` inside that session.
3. Wait for BetterGI to exit, then close the owned child session.
4. If that attempt failed and cleanup is confirmed, repeat once with a fresh child session.
5. Evaluate the final attempt's game logs, then build one report and send it through the configured Feishu app bot.
6. Shut down only when the gateway's WOL record belongs to this Windows boot.

BetterGI itself launches Genshin, enters the game, and executes the selected
profile. The profile must enable tasks and use `关闭游戏和软件` as its completion
action. Linked game startup must be enabled in BetterGI.

The game workflow has no UI clicking, Computer Use dependency, daily skip marker,
focus recovery, entry timeout, or overall task deadline. Reporting
parses the completed run with fixed rules and does not use an agent or model.
The Windows task also has no execution time limit. The runner records the original
`ProcessExitCode` separately from `BusinessOutcome` and the scheduled `ExitCode`.
Process/lifecycle failures retain their nonzero exit code. After a zero lifecycle
exit, explicit game errors produce `partial` and exit 2; missing or incomplete
evidence produces `incomplete` and exit 3. Unexpected warnings retain exit 0 with `needs-attention`. Recognized ordinary
messages, including a proven normal resin stop, remain informational. Delivery
status is recorded separately.

Command-line OneDragon awaits the selected workflow and always exits the software
after that workflow returns. Startup cancellation, explicit task cancellation, an
empty configuration, and unhandled orchestration exceptions exit with code 1.
Manual GUI execution keeps its existing completion behavior. Ordinary gameplay
errors logged by the task runner still finish the process normally and are evaluated
through `BusinessOutcome` after cleanup.

## One recovery attempt

A nonzero BetterGI exit (including `0xC0000005`) or a child-desktop startup/lifecycle
failure allows one retry. Each attempt has its own `attempt-N` directory, process
IDs, timestamps, and result in the root `status.json`. Before another attempt,
the runner verifies that its temporary task, desktop host, and child session are
gone. If cleanup cannot be confirmed or another child session is present, it
stops instead of starting a second instance. It never closes applications in the
parent session, including manually opened BetterGI or Genshin.

There are at most two attempts in one scheduled run. A successful exit, gameplay
warnings, depleted resin, and sold-out items do not trigger a retry. A process that
remains running is still allowed to continue; no hang deadline has been added.
Reporting and the existing WOL shutdown decision run only after all attempts end.
The Windows task's own `RestartCount` stays zero to avoid a second retry mechanism.
Business evaluation also runs once after final cleanup, so game errors and missing
evidence do not trigger another attempt. Evaluation failures are recorded as
`incomplete`; they do not suppress reporting or change the WOL ownership decision.

## Entry points

- `Automation\HeadlessLauncher.exe --run`: run manually without automatic shutdown.
- `Automation\HeadlessLauncher.exe --check`: validate required configuration without starting the game.
- `Automation\HeadlessLauncher.exe --scheduled`: scheduled workflow with WOL shutdown.
- `Automation\Invoke-HeadlessOneDragon.ps1 -NoPublish`: run without sending a report.
  WOL shutdown remains controlled separately by `-Scheduled`, which defaults off.

`HeadlessLauncher.exe` is a small windowless PowerShell launcher.
`ChildDesktopHost.ps1` and `DesktopSession.cs` keep the Windows child session
alive without taking the parent desktop's input. A temporary Windows task starts
BetterGI with elevation in the child session and is deleted after it exits.

The installed BetterGI 0.66.0 has a native desktop-clone UI, but no CLI/IPC command
to create it. Its existing-instance activation handler also does not execute
`startOneDragon`. This runner therefore creates the Windows session directly and
starts a fresh BetterGI process there; it does not automate the native UI.

## WOL shutdown

OpenWrt's existing `bettergi-prepare` job runs at 07:51 (UTC+8). It wakes the PC only when
needed and calls the restricted Windows `GatewayControl.ps1` endpoint. A wake
record is eligible only when the observed Windows boot follows the WOL request.
The runner verifies the record's day and boot at startup and checks the boot again
before shutdown. An already-online PC, stale record, or ordinary manual run does
not shut down. Game errors do not override the WOL ownership decision.

The deployed gateway is `C:\ProgramData\BetterGI-Automation\GatewayControl.ps1`.
The remote protocol's legacy game-state argument remains accepted for compatibility
but does not cause a run to be skipped.

## Logs and validation

Each invocation writes `log\one-dragon-runs\<RunId>\runner.log` and `status.json`.
Per-attempt status and desktop-host logs are stored under `attempt-1` and, when
needed, `attempt-2`. The root status keeps the final attempt's PID/session for
compatibility and includes the complete `Attempts` history.
The latest status is also in `C:\ProgramData\BetterGI-Automation\latest-run.json`.
BetterGI retains its own normal daily application logs.

Run `tests\Test-DesktopSession.ps1`, `tests\Test-GatewayPolicy.ps1`, and
`tests\Test-OneDragonPower.ps1`, plus `tests\Test-OneDragonRetry.ps1` and
`tests\Test-OneDragonCleanup.ps1`, with Windows PowerShell 5.1.
`tests\Test-OneDragonRunner.ps1` executes the real orchestration in isolated
fixtures with Windows, notification, and shutdown boundaries mocked. It checks
crash-then-success, two failures, blocked cleanup, final business-result mapping,
evaluator failure, publication suppression, and one final report/shutdown.
Run `python -m unittest discover -s tests -p 'test_*.py'` for retry report coverage
and synthetic game-result regression fixtures. The result evaluator reuses the
reporter's native log selection and the same deterministic summary parser.
Live acceptance must
also confirm that the scheduled entry starts OneDragon in a child session and
cleans up when BetterGI exits. Unit tests do not prove game execution or a physical
WOL/shutdown cycle.

## Feishu reporting

`Automation\publish_bettergi_report.py` runs once during finalization, while the
runner mutex is still held and before any existing WOL shutdown. It uses
`C:\Python314\python.exe` and the existing native `lark-cli.exe` with the
`bettergi` profile. `C:\ProgramData\BetterGI-Automation\reporting.json` selects
the app, destination chat, CLI path, and bounded delivery timeouts. Credentials
remain in the PC user's restricted lark-cli configuration. No Webhook bot is used.

Each run writes a compact `report\summary.txt`, complete `report\summary.json`,
the selected native application records, a log archive, and `report\delivery.json`.
The app bot sends one compact report and one archive. Successful parts are not
sent again; unfinished delivery can be retried with the same run directory.
The native message idempotency key is stable per run and message part.

The reporter reads only this run's status, time window, PID, and child session.
For a recovered run, it lists both attempts and preserves both sets of attributed
logs, while evaluating gameplay results only from the final attempt.
Its exit code never replaces the game's original result. Report errors are stored
locally and do not prevent the existing WOL ownership policy from running.
There is no additional scheduled trigger or background server. Recovery runs
inside the original invocation, with reporting and shutdown outside its retry loop.

To regenerate or resume delivery for an existing run without launching the game:

```powershell
& 'C:\Python314\python.exe' 'C:\Program Files\BetterGI\Automation\publish_bettergi_report.py' `
  --run-dir 'C:\Program Files\BetterGI\log\one-dragon-runs\<RunId>' `
  --config 'C:\ProgramData\BetterGI-Automation\reporting.json'
```

Add `--dry-run` to generate the report without contacting Feishu. The existing
08:00 trigger keeps `WakeToRun`, `StartWhenAvailable`, and `IgnoreNew`; the OpenWrt
preparation runs nine minutes earlier.

## Building the launcher

The launcher source is included; compiled executables are not versioned. From the
repository root on Windows, build it with the existing .NET Framework compiler:

```powershell
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" `
  /nologo /target:winexe /platform:x64 `
  /out:Automation\HeadlessLauncher.exe Automation\HeadlessLauncher.cs
```

Place the Automation folder under a configured BetterGI installation when
deploying. Keep `User` data, `reporting.json`, gateway state, and credentials
outside Git. Cloning or building this repository does not register a task,
provision a gateway, change the daily schedule, or start a game.
