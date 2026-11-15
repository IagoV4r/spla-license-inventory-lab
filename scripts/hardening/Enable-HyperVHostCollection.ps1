<#
.SYNOPSIS
    Prepares a standalone (workgroup) Hyper-V host to be inventoried by the collector. Run elevated on the host.

.DESCRIPTION
    - Local service account in Remote Management Users and Hyper-V Administrators (by SID, any OS language).
      Not Administrators: local admin accounts get a filtered token over the network (UAC remote restrictions).
      Note: Hyper-V Administrators can also change VMs; there is no built-in read-only Hyper-V role.
    - WinRM enabled even if a network is "Public" (client Windows refuses otherwise), then the firewall rules
      are restricted to the lab subnet so Wi-Fi stays Public and closed.
    Afterwards, run Set-WmiRemoteEnable.ps1 on this host.

    On the COLLECTOR (not here), trust only this host for NTLM:
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value '<host IP>' -Concatenate -Force
    Better for production: an HTTPS WinRM listener with a certificate from the internal CA (no TrustedHosts needed).
#>
param(
    [string]$AccountName   = 'svc-collector',
    [string]$AllowedSubnet = '10.10.10.0/24'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue)) {
    $password = Read-Host "Password for local $AccountName" -AsSecureString
    New-LocalUser -Name $AccountName -Password $password -PasswordNeverExpires -UserMayNotChangePassword `
        -Description 'Inventory collector (local)' | Out-Null
}
foreach ($groupSid in 'S-1-5-32-580', 'S-1-5-32-578') {    # Remote Management Users, Hyper-V Administrators
    if (-not (Get-LocalGroupMember -SID $groupSid | Where-Object Name -like "*\$AccountName")) {
        Add-LocalGroupMember -SID $groupSid -Member $AccountName
    }
}

# May end with a misleading error after configuring everything; verify the state below instead of trusting the message.
try { Enable-PSRemoting -Force -SkipNetworkProfileCheck } catch { Write-Warning "Enable-PSRemoting: $($_.Exception.Message)" }

Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' | Set-NetFirewallRule -RemoteAddress $AllowedSubnet

# Verification
Test-WSMan localhost | Select-Object ProductVendor, ProductVersion
Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' | ForEach-Object {
    [pscustomobject]@{ Rule = $_.Name; Profile = $_.Profile; Enabled = $_.Enabled; RemoteAddress = ($_ | Get-NetFirewallAddressFilter).RemoteAddress }
}
Get-LocalGroupMember -SID 'S-1-5-32-578' | Select-Object Name
