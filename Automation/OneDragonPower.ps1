function Test-OneDragonWolBoot {
    param($Control, [long]$Boot, [string]$Day)
    # A stale record or an unreachable, already-running PC is not evidence of a WOL boot.
    if ($null -eq $Control -or $Boot -le 0) { return $false }
    foreach ($field in @('issued', 'observed', 'boot')) {
        [long]$value = 0
        if (-not [long]::TryParse([string]$Control.$field, [ref]$value) -or $value -le 0) { return $false }
    }
    return $Control.day -eq $Day -and
        $Control.mode -eq 'wake' -and $Control.shutdownEligible -eq $true -and
        [long]$Control.boot -eq $Boot -and [long]$Control.issued -le $Boot -and [long]$Control.observed -ge $Boot
}
