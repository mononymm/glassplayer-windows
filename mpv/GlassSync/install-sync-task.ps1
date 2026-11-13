# Run once, on the Windows profile that runs Plex (not as administrator).
# Creates a scheduled task that syncs mpv's watch progress to Plex at log-in and every 30 minutes.

$script = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'glass-plex-sync.ps1'
$action = New-ScheduledTaskAction -Execute 'conhost.exe' `
    -Argument ('--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script)
$atLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$every30 = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 30)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'Glass Plex Sync' -Action $action -Trigger $atLogon, $every30 -Settings $settings `
    -User $env:USERNAME -RunLevel Limited -Force | Out-Null
Write-Host 'Glass Plex Sync is installed. It runs at log-in and every 30 minutes.' -ForegroundColor Green
Write-Host ('Log: ' + (Join-Path (Split-Path -Parent $script) 'sync.log'))
