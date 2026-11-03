$ErrorActionPreference='Stop'
$controller=Join-Path (Split-Path -Parent $PSScriptRoot) 'Automation\GatewayControl.ps1'
$root=Join-Path $env:TEMP ('BetterGI-PolicyTest-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$cases=@(
    @{Name='fresh_wol';Mode='wake';BootAge=5;IssueAge=10;Game=$false;Seen=0;Eligible=$true},
    @{Name='network_outage_on_existing_boot';Mode='wake';BootAge=86400;IssueAge=10;Game=$false;Seen=0;Eligible=$false},
    @{Name='boot_started_before_wol';Mode='wake';BootAge=12;IssueAge=10;Game=$false;Seen=0;Eligible=$false},
    @{Name='boot_in_future';Mode='wake';BootAge=-10;IssueAge=10;Game=$false;Seen=0;Eligible=$false},
    @{Name='already_online';Mode='online';BootAge=5;IssueAge=10;Game=$false;Seen=0;Eligible=$false},
    @{Name='game_open_after_wol';Mode='wake';BootAge=5;IssueAge=10;Game=$true;Seen=0;Eligible=$true},
    @{Name='legacy_game_seen_ignored';Mode='wake';BootAge=5;IssueAge=10;Game=$false;Seen=1;Eligible=$true},
    @{Name='legacy_skip_file_ignored';Mode='wake';BootAge=5;IssueAge=10;Game=$false;Seen=0;SeedSkip=$true;Eligible=$true},
    @{Name='legacy_skip_control_ignored';Mode='wake';BootAge=5;IssueAge=10;Game=$false;Seen=0;SeedControl=$true;Eligible=$true},
    @{Name='old_wol_marker_different_boot';Mode='online';BootAge=5;IssueAge=10;Game=$false;Seen=0;SeedControl=$true;Eligible=$false},
    @{Name='expired_request';Mode='wake';BootAge=5;IssueAge=1300;Game=$false;Seen=0;Reject=$true},
    @{Name='future_request';Mode='wake';BootAge=5;IssueAge=-300;Game=$false;Seen=0;Reject=$true}
)
try {
    foreach($case in $cases){
        $directory=Join-Path $root $case.Name;$null=New-Item -ItemType Directory -Path $directory
        $skipPath=Join-Path $directory 'skip-day.json'
        $skipBefore=$null
        if($case.SeedSkip){
            @{day=Get-Date -Format 'yyyy-MM-dd';reason='Earlier game detection'}|ConvertTo-Json|Set-Content -LiteralPath $skipPath -Encoding UTF8
            $skipBefore=Get-Content -LiteralPath $skipPath -Raw
        }
        if($case.SeedControl){
            @{day=Get-Date -Format 'yyyy-MM-dd';mode='wake';boot=1;skip=$true;shutdownEligible=$true}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $directory 'daily-control.json') -Encoding UTF8
        }
        $gameLiteral=if($case.Game){'$true'}else{'$false'}
        $code=@'
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';
function Get-CimInstance { param($ClassName) [pscustomobject]@{LastBootUpTime=(Get-Date).AddSeconds(-(BOOTAGE))} }
function Get-Process { param($Name,$ErrorAction) if(GAMEFLAG){[pscustomobject]@{Id=-1;ProcessName='YuanShen'}} }
$issued=[DateTimeOffset]::Now.ToUnixTimeSeconds()-(ISSUEAGE);
$day=Get-Date -Format 'yyyy-MM-dd';$run=(Get-Date -Format 'yyyyMMdd')+'-policy-test-12345678';
$env:SSH_ORIGINAL_COMMAND="arm $run $day MODE $issued SEEN";
& 'CONTROLLER' -StateDirectory 'DIRECTORY'
'@
        $code=$code.Replace('BOOTAGE',[string]$case.BootAge).Replace('GAMEFLAG',$gameLiteral).Replace('ISSUEAGE',[string]$case.IssueAge).Replace('MODE',$case.Mode).Replace('SEEN',[string]$case.Seen).Replace('CONTROLLER',$controller.Replace("'","''")).Replace('DIRECTORY',$directory.Replace("'","''"))
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $output=& powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded
        $resultCode=$LASTEXITCODE
        $result=($output -join "`n")|ConvertFrom-Json
        if($null -eq $result){throw "Controller returned no protocol response: $($case.Name)"}
        if($case.Reject){if($resultCode -eq 0 -or $result.ok){throw "Expected rejection: $($case.Name)"}}
        else {
            if($resultCode -ne 0 -or -not $result.ok){throw "Unexpected rejection: $($case.Name)"}
            if($result.control.shutdownEligible -ne $case.Eligible){throw "Shutdown eligibility mismatch: $($case.Name)"}
            if($result.control.PSObject.Properties.Name -contains 'skip' -or $result.control.PSObject.Properties.Name -contains 'skipReason'){throw "Legacy skip state was retained: $($case.Name)"}
            if($result.control.boot -eq 1){throw "A previous boot marker was reused: $($case.Name)"}
            $saved=Get-Content -LiteralPath (Join-Path $directory 'daily-control.json') -Raw|ConvertFrom-Json
            if($saved.runId -ne $result.control.runId -or $saved.shutdownEligible -ne $case.Eligible){throw "Saved record mismatch: $($case.Name)"}
            if($case.SeedSkip){
                if((Get-Content -LiteralPath $skipPath -Raw) -cne $skipBefore){throw "Legacy skip file was modified: $($case.Name)"}
            }elseif(Test-Path -LiteralPath $skipPath){throw "A skip file was created: $($case.Name)"}
        }
        [pscustomobject]@{Case=$case.Name;Passed=$true}|ConvertTo-Json -Compress
    }
} finally {
    $resolvedRoot=[IO.Path]::GetFullPath($root)
    $tempPrefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if(-not $resolvedRoot.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolvedRoot) -notmatch '^BetterGI-PolicyTest-[a-f0-9]{32}$'){throw 'Refusing to clean an unexpected test directory'}
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
