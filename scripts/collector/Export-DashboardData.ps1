<#
.SYNOPSIS
    Merges the collector results (C:\oc-lab\reports) into one data.json for the dashboard.

.DESCRIPTION
    - vSphere: latest hosts-*.csv and vms-*.csv (Collect-VSphere.ps1)
    - Windows: latest row per target across all winv-servers-*.csv (Collect-WindowsInventory.ps1)
    - Hyper-V: lists the host's VMs over CIM (root/virtualization/v2) and links each VM to the Windows inventory by name
    - Licensing: per host, max(physical cores, 8 x sockets, 16); without a "Must run on" rule the whole cluster is in scope

.EXAMPLE
    .\Export-DashboardData.ps1 -HyperVCredential $hostCred
#>
param(
    [string]$ReportDir  = 'C:\oc-lab\reports',
    [string]$OutFile    = 'C:\oc-lab\dashboard\data.json',
    [string]$HyperVHost = '10.10.10.254',
    [pscredential]$HyperVCredential
)

$ErrorActionPreference = 'Stop'

function Get-Latest($pattern) {
    Get-ChildItem (Join-Path $ReportDir $pattern) -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -Last 1
}
function Get-LicensedCores([int]$sockets, [int]$cores) {
    [math]::Max($cores, [math]::Max(8 * $sockets, 16))
}

# ---------- vSphere ----------
$hostsCsv = Get-Latest 'hosts-*.csv'
$vmsCsv   = Get-Latest 'vms-*.csv'
if (-not $hostsCsv -or -not $vmsCsv) { throw "vSphere CSV files not found in $ReportDir" }
$vsHosts = @(Import-Csv $hostsCsv.FullName)
$vsVms   = @(Import-Csv $vmsCsv.FullName)

# ---------- Windows (latest row per target) ----------
$winFiles = @(Get-ChildItem (Join-Path $ReportDir 'winv-servers-*.csv') | Sort-Object LastWriteTime -Descending)
$winRows = foreach ($f in $winFiles) {
    Import-Csv $f.FullName | Add-Member -NotePropertyName CollectedAt -NotePropertyValue $f.LastWriteTime.ToString('s') -PassThru
}
$windows = @($winRows | Group-Object Computer | ForEach-Object { $_.Group | Select-Object -First 1 })

# ---------- Hyper-V ----------
$hvHostRow = $windows | Where-Object { $_.Computer -eq $HyperVHost -and $_.Status -eq 'OK' } | Select-Object -First 1
$hvVms = @()
if ($HyperVCredential) {
    $session = New-CimSession -ComputerName $HyperVHost -Credential $HyperVCredential
    try {
        $hvVms = @(Get-CimInstance -CimSession $session -Namespace root/virtualization/v2 -ClassName Msvm_ComputerSystem |
            Where-Object Name -match '^[0-9A-F-]{36}$' |      # VMs have a GUID as Name; the host has its computer name
            ForEach-Object {
                $vmName = $_.ElementName
                $inventory = $windows | Where-Object { ($_.Computer -split '\.')[0] -eq $vmName -and $_.Status -eq 'OK' } |
                             Select-Object -First 1
                [pscustomobject]@{
                    VM          = $vmName
                    PowerState  = @{ 2 = 'PoweredOn'; 3 = 'PoweredOff' }[[int]$_.EnabledState]
                    Host        = $HyperVHost
                    GuestOS     = if ($inventory) { $inventory.OS } else { '' }
                    Windows     = [bool]($inventory -and $inventory.OS -match 'Windows')
                    Inventoried = [bool]$inventory
                }
            })
    }
    finally { Remove-CimSession $session }
}

# ---------- Licensing ----------
$license = [System.Collections.Generic.List[object]]::new()

$vsWindowsVms = @($vsVms | Where-Object { $_.GuestOS -match 'Windows' -or $_.GuestId -match '^windows' })
$scope = foreach ($vm in $vsWindowsVms) {
    if ($vm.Cluster) { $cluster = $vm.Cluster; $vsHosts | Where-Object Cluster -eq $cluster }
    else             { $hostName = $vm.Host;   $vsHosts | Where-Object Host -eq $hostName }
}
foreach ($h in ($scope | Sort-Object Host -Unique)) {
    $count = @($vsWindowsVms | Where-Object { ($h.Cluster -and $_.Cluster -eq $h.Cluster) -or $_.Host -eq $h.Host }).Count
    $license.Add([pscustomobject]@{
        Host          = $h.Host
        Platform      = 'vSphere'
        Cluster       = $h.Cluster
        Sockets       = [int]$h.Sockets
        PhysicalCores = [int]$h.Cores
        LicensedCores = Get-LicensedCores $h.Sockets $h.Cores
        WindowsVMs    = $count
        Reason        = if ($h.Cluster) { 'Windows VM in cluster (no Must rule)' } else { 'Windows VM on standalone host' }
    })
}

$hvWindowsVms = @($hvVms | Where-Object Windows)
if ($hvWindowsVms.Count -gt 0 -and $hvHostRow) {
    $license.Add([pscustomobject]@{
        Host          = $HyperVHost
        Platform      = 'Hyper-V'
        Cluster       = ''
        Sockets       = [int]$hvHostRow.Sockets
        PhysicalCores = [int]$hvHostRow.Cores
        LicensedCores = Get-LicensedCores $hvHostRow.Sockets $hvHostRow.Cores
        WindowsVMs    = $hvWindowsVms.Count
        Reason        = 'Windows VM on Hyper-V host'
    })
}

# ---------- Output ----------
$lastRun = Get-Latest 'run-*.log'
$data = [ordered]@{
    generatedAt      = (Get-Date).ToString('s')
    lastScheduledRun = if ($lastRun) { $lastRun.LastWriteTime.ToString('s') } else { $null }
    sources          = [ordered]@{ vsphereHosts = $hostsCsv.Name; vsphereVms = $vmsCsv.Name; windowsFiles = $winFiles.Count }
    vsphere          = [ordered]@{ hosts = $vsHosts; vms = $vsVms }
    hyperv           = [ordered]@{ host = $hvHostRow; vms = $hvVms }
    windows          = $windows
    license          = @($license)
}

New-Item -ItemType Directory (Split-Path $OutFile) -Force | Out-Null
$data | ConvertTo-Json -Depth 6 | Set-Content $OutFile -Encoding UTF8

'OK: {0} ({1} bytes) | vSphere {2} hosts/{3} VMs | Hyper-V {4} VMs | Windows {5} targets | {6} host(s) in SPLA scope' -f
    $OutFile, (Get-Item $OutFile).Length, $vsHosts.Count, $vsVms.Count, $hvVms.Count, $windows.Count, $license.Count
