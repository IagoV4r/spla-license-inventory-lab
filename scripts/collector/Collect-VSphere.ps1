<#
.SYNOPSIS
    Collects vSphere hosts and VMs for the license estimate (PowerCLI, read-only account).

.NOTES
    Uses Get-View with explicit properties: faster on large vCenters and avoids the
    "OK with empty columns" problem (RCA-6). GuestId is collected because it is stable,
    while GuestFullName is a display string.
#>
param(
    [string]$Server = 'vcenter01.lab.internal',

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [pscredential]$Credential,

    [string]$OutDir = 'C:\oc-lab\reports'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory $OutDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log   = Join-Path $OutDir "collect-$stamp.log"
function Write-Log($msg) { "$(Get-Date -Format s) $msg" | Tee-Object -FilePath $log -Append }

$vc = $null
try {
    Write-Log "Connecting to $Server as $($Credential.UserName)"
    $vc = Connect-VIServer $Server -Credential $Credential

    $hosts = Get-VMHost | ForEach-Object {
        [pscustomobject]@{
            Host    = $_.Name
            Cluster = ($_ | Get-Cluster -ErrorAction SilentlyContinue).Name
            Sockets = $_.ExtensionData.Hardware.CpuInfo.NumCpuPackages
            Cores   = $_.ExtensionData.Hardware.CpuInfo.NumCpuCores
            State   = $_.ConnectionState
        }
    }

    $properties = 'Name', 'Runtime.PowerState', 'Runtime.Host', 'Config.Hardware.NumCPU', 'Config.GuestId',
                  'Config.GuestFullName', 'Guest.ToolsRunningStatus', 'Guest.HostName'
    $vms = Get-View -ViewType VirtualMachine -Property $properties | ForEach-Object {
        $vmHost = Get-VMHost -Id $_.Runtime.Host
        [pscustomobject]@{
            VM            = $_.Name
            PowerState    = $_.Runtime.PowerState
            vCPU          = $_.Config.Hardware.NumCPU
            Host          = $vmHost.Name
            Cluster       = ($vmHost | Get-Cluster -ErrorAction SilentlyContinue).Name
            GuestId       = $_.Config.GuestId
            GuestOS       = $_.Config.GuestFullName
            ToolsStatus   = $_.Guest.ToolsRunningStatus
            GuestHostName = $_.Guest.HostName
        }
    }

    # Data-quality check: an empty GuestId means the OS is unknown and could be Windows.
    $noGuestId = @($vms | Where-Object { -not $_.GuestId })
    if ($noGuestId.Count -gt 0) {
        Write-Log "WARN  $($noGuestId.Count) of $($vms.Count) VMs without GuestId: $($noGuestId.VM -join ', ')"
    }

    $hosts | Export-Csv (Join-Path $OutDir "hosts-$stamp.csv") -NoTypeInformation
    $vms   | Export-Csv (Join-Path $OutDir "vms-$stamp.csv")   -NoTypeInformation
    Write-Log "OK: $(@($hosts).Count) hosts, $(@($vms).Count) VMs"
}
catch {
    Write-Log "ERROR $($_.Exception.Message)"
    throw
}
finally {
    if ($vc) { Disconnect-VIServer $vc -Confirm:$false }
}
