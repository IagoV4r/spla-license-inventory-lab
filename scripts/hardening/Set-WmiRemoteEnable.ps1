<#
.SYNOPSIS
    Grants "Enable Account" + "Remote Enable" on the root\cimv2 WMI namespace to a group (default: Remote Management Users).

.DESCRIPTION
    Needed so a non-admin account can read WMI remotely. GPO has no native setting for namespace security,
    so at scale this runs as a GPO startup script: it is guarded and idempotent.
    Guards: stops on any error, aborts if the descriptor read looks wrong, never writes the same entry twice.
    Rollback: re-apply the "BEFORE" SDDL printed by the script.

.EXAMPLE
    .\Set-WmiRemoteEnable.ps1          # run elevated on each target
#>
param([string]$Sid = 'S-1-5-32-580')   # BUILTIN\Remote Management Users

$ErrorActionPreference = 'Stop'
$security = Get-WmiObject -Namespace root\cimv2 -Class __SystemSecurity
$helper   = [wmiclass]'Win32_SecurityDescriptorHelper'

# Read the current descriptor
$buffer = @($null)
$rc = $security.PsBase.InvokeMethod('GetSD', $buffer)
if ($rc -ne 0 -or -not $buffer[0]) { throw "GetSD failed (rc=$rc)" }
$before = $helper.BinarySDToSDDL($buffer[0]).SDDL
if ($before -notmatch '\(A;[^)]*;;;BA\)') { throw "Descriptor has no Administrators entry, aborting: $before" }
"$env:COMPUTERNAME BEFORE: $before"

# Idempotency: Windows stores well-known SIDs by alias (S-1-5-32-580 becomes RM)
$alias   = @{ 'S-1-5-32-580' = 'RM' }[$Sid]
$pattern = '\(A;[^;]*;CCWP;;;(' + [regex]::Escape($Sid) + $(if ($alias) { "|$alias" }) + ')\)'
if ($before -match $pattern) { "$env:COMPUTERNAME already has the entry, nothing to do"; return }

# CC = Enable Account, WP = Remote Enable, CI = inherited by sub-namespaces. Insert into the DACL, never the SACL.
$ace   = "(A;CI;CCWP;;;$Sid)"
$index = $before.IndexOf('S:(')
$after = if ($index -ge 0) { $before.Insert($index, $ace) } else { $before + $ace }

$buffer[0] = $helper.SDDLToBinarySD($after).BinarySD
$rc = $security.PsBase.InvokeMethod('SetSD', $buffer)
if ($rc -ne 0) { throw "SetSD failed (rc=$rc)" }

# Read back what was actually stored
$buffer = @($null); $null = $security.PsBase.InvokeMethod('GetSD', $buffer)
"$env:COMPUTERNAME AFTER : $($helper.BinarySDToSDDL($buffer[0]).SDDL)"
