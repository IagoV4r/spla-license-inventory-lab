<#
.SYNOPSIS
    Quick SPLA estimate from the latest vSphere CSVs: which hosts are in scope and how many cores to license.

.NOTES
    Rule per host: max(physical cores, 8 x sockets, 16). Without a "Must run on" VM-host rule,
    every host in a cluster that runs a Windows VM is in scope.
    Powered-off Windows VMs are still counted: a VM registered on a host may have run there during the month.
#>
param([string]$ReportDir = 'C:\oc-lab\reports')

$ErrorActionPreference = 'Stop'
$hosts = Import-Csv (Get-ChildItem "$ReportDir\hosts-*.csv" | Sort-Object LastWriteTime | Select-Object -Last 1).FullName
$vms   = Import-Csv (Get-ChildItem "$ReportDir\vms-*.csv"   | Sort-Object LastWriteTime | Select-Object -Last 1).FullName

$windowsVms = @($vms | Where-Object { $_.GuestOS -match 'Windows' -or $_.GuestId -match '^windows' })

$scope = foreach ($vm in $windowsVms) {
    if ($vm.Cluster) { $cluster = $vm.Cluster; $hosts | Where-Object Cluster -eq $cluster }
    else             { $hostName = $vm.Host;   $hosts | Where-Object Host -eq $hostName }
}

$result = foreach ($h in ($scope | Sort-Object Host -Unique)) {
    $licensed = [math]::Max([int]$h.Cores, [math]::Max(8 * [int]$h.Sockets, 16))
    [pscustomobject]@{
        Host          = $h.Host
        Cluster       = $h.Cluster
        PhysicalCores = [int]$h.Cores
        LicensedCores = $licensed
        TwoCorePacks  = $licensed / 2
    }
}

$windowsVms | Select-Object VM, Host, Cluster, PowerState, GuestId | Format-Table -AutoSize
$result | Format-Table -AutoSize
"Windows VMs: $($windowsVms.Count) | Hosts in scope: $(@($result).Count) | Licensed cores: $(($result | Measure-Object LicensedCores -Sum).Sum)"
