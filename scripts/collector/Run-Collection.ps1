<#
.SYNOPSIS
    Runs the daily collection. Started by the scheduled task as the service account, with nobody logged on.

.NOTES
    Credentials live in C:\oc-lab\creds\*.xml, created with Export-Clixml BY THE SERVICE ACCOUNT ITSELF
    on this machine (DPAPI: only that user, on this machine, can open them). Example, run as the service account:
        Get-Credential 'LAB\svc-collector' | Export-Clixml C:\oc-lab\creds\domain.xml
    Exit codes: 0 = all OK | 1 = a stage failed | 2 = credentials could not be loaded
#>
$ErrorActionPreference = 'Stop'
$basePath = 'C:\oc-lab'
$credPath = Join-Path $basePath 'creds'
$log      = Join-Path $basePath "reports\run-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
function Write-Log($msg) { "$(Get-Date -Format s) $msg" | Tee-Object -FilePath $log -Append }

Write-Log "Scheduled collection started as $(whoami)"

try {
    $domainCred = Import-Clixml (Join-Path $credPath 'domain.xml')
    $hyperVCred = Import-Clixml (Join-Path $credPath 'hyperv-host.xml')
    $vCenterCred = Import-Clixml (Join-Path $credPath 'vcenter.xml')
}
catch {
    Write-Log "ERROR loading credentials (DPAPI/file): $($_.Exception.Message)"
    exit 2
}

$failedStages = 0

# 1. Domain servers (Kerberos, by FQDN)
$global:LASTEXITCODE = 0
& (Join-Path $basePath 'Collect-WindowsInventory.ps1') -ComputerName dc01.lab.internal, sql01.lab.internal -Credential $domainCred
if ($LASTEXITCODE -ne 0) { $failedStages++; Write-Log 'Stage "Windows (domain)" ended with errors' }

# 2. Hyper-V host outside the domain (NTLM + TrustedHosts)
$global:LASTEXITCODE = 0
& (Join-Path $basePath 'Collect-WindowsInventory.ps1') -ComputerName 10.10.10.254 -Credential $hyperVCred
if ($LASTEXITCODE -ne 0) { $failedStages++; Write-Log 'Stage "Windows (Hyper-V host)" ended with errors' }

# 3. vCenter (PowerCLI)
try   { & (Join-Path $basePath 'Collect-VSphere.ps1') -Server vcenter01.lab.internal -Credential $vCenterCred }
catch { $failedStages++; Write-Log "Stage ""vSphere"" ended with errors: $($_.Exception.Message)" }

Write-Log "End: $failedStages stage(s) failed"
if ($failedStages -gt 0) { exit 1 } else { exit 0 }
