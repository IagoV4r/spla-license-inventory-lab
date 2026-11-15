<#
.SYNOPSIS
    Inventories Windows machines over WinRM/CIM for the SPLA estimate.

.DESCRIPTION
    Per target: OS, hardware (sockets/cores), SQL Server instances with edition,
    RDS Session Host role and installed software (registry, never Win32_Product).
    Logs the remote identity and how many registry keys were read, so that
    "really empty" can be told apart from "could not read" (RCA-6 and RCA-7).

.EXAMPLE
    .\Collect-WindowsInventory.ps1 -ComputerName dc01.lab.internal, sql01.lab.internal -Credential $cred
#>
param(
    [Parameter(Mandatory)]
    [string[]]$ComputerName,

    # RCA-7: New-CimSession accepts -Credential $null silently and runs as the current user.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [pscredential]$Credential,

    [string]$OutDir = 'C:\oc-lab\reports'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory $OutDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log   = Join-Path $OutDir "winv-$stamp.log"
function Write-Log($msg) { "$(Get-Date -Format s) $msg" | Tee-Object -FilePath $log -Append }

Write-Log "Start: $($ComputerName.Count) target(s), credential $($Credential.UserName)"

$servers  = [System.Collections.Generic.List[object]]::new()
$software = [System.Collections.Generic.List[object]]::new()

# Runs ON THE TARGET: installed software and SQL Server instances from the registry.
$remoteBlock = {
    $paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $keys = @(foreach ($p in $paths) { Get-ItemProperty $p })

    $sql  = @()
    $inst = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if (Test-Path $inst) {
        $props = Get-ItemProperty $inst
        foreach ($name in ($props.PSObject.Properties.Name | Where-Object { $_ -notlike 'PS*' })) {
            $setup = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($props.$name)\Setup"
            $sql  += [pscustomobject]@{ Instance = $name; Edition = $setup.Edition; Version = $setup.Version }
        }
    }

    [pscustomobject]@{
        Identity = whoami
        SwKeys   = $keys.Count
        Products = @($keys | Where-Object DisplayName | Select-Object DisplayName, DisplayVersion, Publisher)
        Sql      = $sql
    }
}

foreach ($pc in $ComputerName) {
    $row = [ordered]@{
        Computer = $pc; Status = 'ERROR'; Identity = $null; OS = $null; Build = $null
        Manufacturer = $null; Model = $null; Virtual = $null
        Sockets = $null; Cores = $null; LogicalCPUs = $null
        SqlInstances = $null; RdsSessionHost = $null; SwKeys = $null; SwNamed = $null; Error = $null
    }
    $cim = $null
    try {
        $cim = New-CimSession -ComputerName $pc -Credential $Credential
        $os  = Get-CimInstance -CimSession $cim Win32_OperatingSystem
        $cs  = Get-CimInstance -CimSession $cim Win32_ComputerSystem
        $cpu = @(Get-CimInstance -CimSession $cim Win32_Processor)

        # Win32_ServerFeature exists only on Windows Server (ProductType 1 = workstation, 2 = DC, 3 = server)
        $isServer = $os.ProductType -ne 1
        $features = if ($isServer) { @(Get-CimInstance -CimSession $cim Win32_ServerFeature) } else { @() }

        $remote = Invoke-Command -ComputerName $pc -Credential $Credential -ScriptBlock $remoteBlock

        $row.Identity       = $remote.Identity
        $row.OS             = $os.Caption
        $row.Build          = $os.BuildNumber
        $row.Manufacturer   = $cs.Manufacturer
        $row.Model          = $cs.Model
        $row.Virtual        = $cs.Model -match 'Virtual|VMware|KVM'
        $row.Sockets        = $cpu.Count
        $row.Cores          = ($cpu | Measure-Object NumberOfCores -Sum).Sum
        $row.LogicalCPUs    = $cs.NumberOfLogicalProcessors
        $row.SqlInstances   = ($remote.Sql | ForEach-Object { "$($_.Instance) ($($_.Edition) $($_.Version))" }) -join '; '
        $row.RdsSessionHost = if ($isServer) { [bool]($features | Where-Object Name -match 'Remote Desktop Session Host') } else { 'N/A (client OS)' }
        $row.SwKeys         = $remote.SwKeys
        $row.SwNamed        = @($remote.Products).Count
        $row.Status         = 'OK'

        foreach ($p in $remote.Products) {
            $software.Add([pscustomobject]@{
                Computer = $pc; Name = $p.DisplayName; Version = $p.DisplayVersion; Publisher = $p.Publisher
            })
        }

        Write-Log ("OK    {0} | id={1} | {2} | {3} socket(s)/{4} core(s) | SQL: {5} | RDSH: {6} | software: {7} keys, {8} named" -f
            $pc, $row.Identity, $row.OS, $row.Sockets, $row.Cores,
            $(if ($row.SqlInstances) { $row.SqlInstances } else { 'none' }),
            $row.RdsSessionHost, $row.SwKeys, $row.SwNamed)

        $expectedUser = $Credential.UserName.Split('\')[-1]
        if ($row.Identity -notlike "*\$expectedUser") {
            Write-Log ("WARN  {0}: remote identity ({1}) differs from the credential ({2})" -f $pc, $row.Identity, $Credential.UserName)
        }
    }
    catch {
        $row.Error = $_.Exception.Message
        Write-Log "ERROR $pc | $($row.Error)"
    }
    finally {
        if ($cim) { Remove-CimSession $cim }
        $servers.Add([pscustomobject]$row)
    }
}

$servers  | Export-Csv (Join-Path $OutDir "winv-servers-$stamp.csv")  -NoTypeInformation -Encoding UTF8
$software | Export-Csv (Join-Path $OutDir "winv-software-$stamp.csv") -NoTypeInformation -Encoding UTF8

$failed = @($servers | Where-Object Status -ne 'OK').Count
Write-Log "End: $($servers.Count - $failed) OK, $failed failed"

$servers | Format-Table Computer, Status, Identity, OS, Sockets, Cores, Virtual, SqlInstances, RdsSessionHost, SwNamed, Error -AutoSize

# Non-zero exit when a target failed: the scheduled task shows it as "Last Run Result".
if ($failed -gt 0) { exit 1 }
