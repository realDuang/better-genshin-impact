$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Automation\OneDragonPower.ps1')

$day = '2026-10-27'
$boot = 1000L
function New-Control {
    param([hashtable]$Changes = @{}, [string[]]$Remove = @())
    $values = @{ day = $day; mode = 'wake'; shutdownEligible = $true; boot = $boot; issued = 990L; observed = 1010L }
    foreach ($name in $Changes.Keys) { $values[$name] = $Changes[$name] }
    foreach ($name in $Remove) { $values.Remove($name) }
    [pscustomobject]$values
}

$cases = @(
    @{ Name = 'missing_record'; Control = $null; Expected = $false },
    @{ Name = 'empty_record'; Control = [pscustomobject]@{}; Expected = $false },
    @{ Name = 'missing_day'; Control = (New-Control -Remove day); Expected = $false },
    @{ Name = 'missing_boot'; Control = (New-Control -Remove boot); Expected = $false },
    @{ Name = 'missing_issue_time'; Control = (New-Control -Remove issued); Expected = $false },
    @{ Name = 'missing_observation_time'; Control = (New-Control -Remove observed); Expected = $false },
    @{ Name = 'missing_eligibility'; Control = (New-Control -Remove shutdownEligible); Expected = $false },
    @{ Name = 'invalid_issue_time'; Control = (New-Control @{ issued = 'invalid' }); Expected = $false },
    @{ Name = 'invalid_observation_time'; Control = (New-Control @{ observed = 'invalid' }); Expected = $false },
    @{ Name = 'invalid_boot_time'; Control = (New-Control @{ boot = 'invalid' }); Expected = $false },
    @{ Name = 'zero_issue_time'; Control = (New-Control @{ issued = 0L }); Expected = $false },
    @{ Name = 'zero_observation_time'; Control = (New-Control @{ observed = 0L }); Expected = $false },
    @{ Name = 'zero_boot_time'; Control = (New-Control @{ boot = 0L }); Expected = $false },
    @{ Name = 'old_day'; Control = (New-Control @{ day = '2026-10-26' }); Expected = $false },
    @{ Name = 'future_day'; Control = (New-Control @{ day = '2026-10-28' }); Expected = $false },
    @{ Name = 'new_boot_since_record'; Control = (New-Control @{ boot = 900L; issued = 890L; observed = 910L }); Expected = $false },
    @{ Name = 'already_online'; Control = (New-Control @{ mode = 'online' }); Expected = $false },
    @{ Name = 'reachable_pc_misreported_as_wake'; Control = (New-Control @{ issued = 1005L; observed = 1010L }); Expected = $false },
    @{ Name = 'observation_precedes_boot'; Control = (New-Control @{ observed = 999L }); Expected = $false },
    @{ Name = 'numeric_string_observation_precedes_boot'; Control = (New-Control @{ observed = '999' }); Expected = $false },
    @{ Name = 'gateway_rejected_ownership'; Control = (New-Control @{ shutdownEligible = $false }); Expected = $false },
    @{ Name = 'valid_wol_boot'; Control = (New-Control); Expected = $true },
    @{ Name = 'inclusive_time_bounds'; Control = (New-Control @{ issued = $boot; observed = $boot }); Expected = $true }
)

$failures = @()
foreach ($case in $cases) {
    $actual = Test-OneDragonWolBoot -Control $case.Control -Boot $boot -Day $day
    $passed = $actual -eq $case.Expected
    [pscustomobject]@{ Case = $case.Name; Passed = $passed; Expected = $case.Expected; Actual = $actual } | ConvertTo-Json -Compress
    if (-not $passed) { $failures += $case.Name }
}
if ($failures.Count -gt 0) { throw ('WOL ownership checks failed: ' + ($failures -join ', ')) }
