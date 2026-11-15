<#
.SYNOPSIS
    Creates the collector identity and its least-privilege access in Active Directory. Run on a domain controller.

.DESCRIPTION
    1. OU "Service Accounts" with the service account and the group GG-Inventory-Collectors
    2. Domain controllers: the group joins BUILTIN\Remote Management Users (never Administrators: on a DC that means domain-wide admin)
    3. Member servers: OU "Servers" + GPO with
       - Restricted Groups "Member of" Remote Management Users (adds, never replaces existing members)
       - "Log on as a batch job" for the scheduled task, KEEPING the Windows defaults (a GPO user right replaces the whole local list)
    Groups are referenced by SID, so the GPO works on any OS language.
    Move the member servers into OU=Servers afterwards (GPOs cannot be linked to the default CN=Computers container).
#>
param(
    [string]$AccountName = 'svc-collector',
    [string]$GroupName   = 'GG-Inventory-Collectors',
    [string]$GpoName     = 'SRV - Inventory Collector Access'
)

$ErrorActionPreference = 'Stop'
$domainDn = (Get-ADDomain).DistinguishedName
$dnsRoot  = (Get-ADDomain).DNSRoot

# 1. OU, group, account
$serviceOu = "OU=Service Accounts,$domainDn"
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$serviceOu'")) {
    New-ADOrganizationalUnit -Name 'Service Accounts' -Path $domainDn
}
if (-not (Get-ADGroup -Filter "Name -eq '$GroupName'")) {
    New-ADGroup -Name $GroupName -GroupScope Global -Path $serviceOu -Description 'Accounts that run inventory collection'
}
if (-not (Get-ADUser -Filter "SamAccountName -eq '$AccountName'")) {
    $password = Read-Host "Password for $AccountName" -AsSecureString
    # PasswordNeverExpires is a trade-off: an expired password silently stops collection. Prefer a gMSA where possible.
    New-ADUser -Name $AccountName -SamAccountName $AccountName -UserPrincipalName "$AccountName@$dnsRoot" `
        -Path $serviceOu -AccountPassword $password -Enabled $true -PasswordNeverExpires $true -CannotChangePassword $true `
        -Description 'Inventory collector service account'
}
Add-ADGroupMember -Identity $GroupName -Members $AccountName

# 2. Domain controllers: builtin domain group
Add-ADGroupMember -Identity 'Remote Management Users' -Members $GroupName

# 3. Member servers: OU + GPO
$serversOu = "OU=Servers,$domainDn"
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$serversOu'")) {
    New-ADOrganizationalUnit -Name 'Servers' -Path $domainDn
}
$gpo = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
if (-not $gpo) {
    $gpo = New-GPO -Name $GpoName -Comment "$GroupName -> Remote Management Users + batch logon"
    $gpo | New-GPLink -Target $serversOu | Out-Null
}

$guid     = "{$($gpo.Id)}"
$gpoPath  = "$env:SystemRoot\SYSVOL\domain\Policies\$guid"
$groupSid = (Get-ADGroup $GroupName).SID.Value
$secEdit  = "$gpoPath\Machine\Microsoft\Windows NT\SecEdit"
New-Item -ItemType Directory $secEdit -Force | Out-Null

# 544 Administrators, 551 Backup Operators, 559 Performance Log Users = Windows defaults for batch logon
@"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[Group Membership]
*${groupSid}__Memberof = *S-1-5-32-580
[Privilege Rights]
SeBatchLogonRight = *S-1-5-32-544,*S-1-5-32-551,*S-1-5-32-559,*$groupSid
"@ | Set-Content "$secEdit\GptTmpl.inf" -Encoding Unicode

# A GPO edited outside the GPMC needs a new version and the Security client-side extension registered
$gpoDn   = "CN=$guid,CN=Policies,CN=System,$domainDn"
$version = [int](Get-ADObject $gpoDn -Properties versionNumber).versionNumber + 1
Set-ADObject $gpoDn -Replace @{
    versionNumber            = $version
    gPCMachineExtensionNames = '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'
}
Set-Content "$gpoPath\GPT.INI" "[General]`r`nVersion=$version" -Encoding ASCII

"GPO '$GpoName' version $version linked to $serversOu. Move member servers into this OU, then run: gpupdate /target:computer /force"
