<#
.SYNOPSIS
    Registers the nightly collection task on the collector server. Run elevated.

.DESCRIPTION
    - Folders with minimal permissions: creds (Administrators + service account only), reports (service account can write)
    - Task runs as the service account, not elevated, with nobody logged on
    - Server settings: allowed on battery (a VM on a laptop sees a virtual battery), 1 h limit, no overlapping runs
    The account needs "Log on as a batch job" (granted by the GPO in New-CollectorAccess.ps1).

    After registering, create the credential files AS THE SERVICE ACCOUNT on this server (DPAPI), e.g.:
        Enter-PSSession -VMName <collector> -Credential LAB\svc-collector     # or log on to the console
        Get-Credential 'LAB\svc-collector' | Export-Clixml C:\oc-lab\creds\domain.xml
    Check the file owner afterwards: it must be the service account, not BUILTIN\Administrators.
#>
param(
    [string]$ServiceAccount = 'LAB\svc-collector',
    [string]$BasePath       = 'C:\oc-lab',
    [string]$TaskName       = 'Inventory Collection',
    [datetime]$StartTime    = '02:00'
)

$ErrorActionPreference = 'Stop'

$credPath   = Join-Path $BasePath 'creds'
$reportPath = Join-Path $BasePath 'reports'
New-Item -ItemType Directory $credPath, $reportPath -Force | Out-Null
icacls $credPath   /inheritance:r /grant 'BUILTIN\Administrators:(OI)(CI)F' "${ServiceAccount}:(OI)(CI)M" | Out-Null
icacls $reportPath /grant "${ServiceAccount}:(OI)(CI)M" | Out-Null

$action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
              -Argument "-NoProfile -ExecutionPolicy Bypass -File $BasePath\Run-Collection.ps1"
$trigger  = New-ScheduledTaskTrigger -Daily -At $StartTime
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew

$credential = Get-Credential $ServiceAccount
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -User $ServiceAccount -Password $credential.GetNetworkCredential().Password -RunLevel Limited |
    Select-Object TaskName, State

# Task history is off by default; without it, "has not yet run" (0x41303) hides the real reason.
wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true

if (-not (Test-Path (Join-Path $BasePath 'Run-Collection.ps1'))) {
    Write-Warning "Run-Collection.ps1 not found in ${BasePath}: the task would fail with 0xFFFD0000."
}
