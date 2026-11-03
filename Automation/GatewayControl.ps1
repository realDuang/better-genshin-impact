param([string]$StateDirectory='C:\ProgramData\BetterGI-Automation')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$directory=$StateDirectory
$statePath=Join-Path $directory 'daily-control.json'
function Get-Status {
    $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $games=@(Get-Process -Name YuanShen,GenshinImpact -ErrorAction SilentlyContinue)
    $state=$null
    if(Test-Path -LiteralPath $statePath){$state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json}
    [pscustomobject]@{ok=$true;host=$env:COMPUTERNAME;now=[DateTimeOffset]::Now.ToUnixTimeSeconds();boot=([DateTimeOffset]$boot).ToUnixTimeSeconds();gameRunning=($games.Count -gt 0);control=$state}
}
try {
    $parts=@(($env:SSH_ORIGINAL_COMMAND -as [string]).Trim() -split '\s+')
    if($parts.Count -eq 1 -and $parts[0] -eq 'status') { Get-Status|ConvertTo-Json -Depth 6 -Compress;exit 0 }
    if($parts.Count -ne 6 -or $parts[0] -ne 'arm'){throw 'Only status and arm are supported'}
    $run=$parts[1];$day=$parts[2];$mode=$parts[3];[long]$issued=0
    if($run -notmatch '^\d{8}-[a-zA-Z0-9-]{8,64}$'){throw 'Invalid run ID'}
    if($day -ne (Get-Date -Format 'yyyy-MM-dd')){throw 'The request must target today'}
    if($mode -notin @('online','wake')){throw 'Invalid preparation mode'}
    if($parts[5] -notin @('0','1')){throw 'Invalid game-state flag'}
    if(-not[long]::TryParse($parts[4],[ref]$issued)){throw 'Invalid issue time'}
    $status=Get-Status
    if($issued -gt $status.now+30 -or $status.now-$issued -gt 1200){throw 'The request has expired or is from the future'}
    # The gateway still sends its legacy game-state argument; it no longer affects execution.
    $eligible=$mode -eq 'wake' -and $status.boot -ge $issued -and $status.boot -le $status.now
    $state=[ordered]@{day=$day;runId=$run;mode=$mode;issued=$issued;observed=$status.now;boot=$status.boot;shutdownEligible=$eligible}
    $null=New-Item -ItemType Directory -Path $directory -Force
    [IO.File]::WriteAllText($statePath+'.tmp',($state|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath ($statePath+'.tmp') -Destination $statePath -Force
    [pscustomobject]@{ok=$true;control=$state}|ConvertTo-Json -Depth 5 -Compress
} catch {
    [pscustomobject]@{ok=$false;error=$_.Exception.Message}|ConvertTo-Json -Compress
    exit 1
}
