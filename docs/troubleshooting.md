# Troubleshooting

Errors I actually hit in the lab, grouped by layer. Read the **Check** column first: it proves the cause before changing anything.

## WinRM / WMI (Windows inventory)

| Error / symptom | Likely cause | Check | Fix |
|---|---|---|---|
| `New-CimSession: Access is denied` (`0x80070005`) | Account not allowed to connect to WinRM on the target | `whoami /groups` from a remote session; `Get-LocalGroupMember -SID S-1-5-32-580` | Add the group to *Remote Management Users* (DC: builtin domain group; member servers: GPO) |
| `The WMI service returned an 'access denied' error` | Connected, but no *Remote Enable* on `root\cimv2` | Read the namespace security descriptor (SDDL) | Add `(A;CI;CCWP;;;RM)` with a guarded, idempotent script |
| `Default authentication may be used with an IP address ... TrustedHosts` | Target given by IP, or outside the domain: no Kerberos, NTLM refused | Does it work with the FQDN? | Use the FQDN. Outside the domain: add only that host to TrustedHosts **on the client**, or use an HTTPS listener |
| `Cannot find the computer` (reported as a Kerberos error) | DNS: the name does not resolve | `Resolve-DnsName <name>` | Fix the name or the DNS record |
| `Enable-PSRemoting`: *a network connection type is set to Public* | Client Windows refuses a firewall rule while any network is Public | `Get-NetConnectionProfile` | `-SkipNetworkProfileCheck`, then restrict the WinRM rules' remote address; leave Wi-Fi Public |
| `The class Win32_ServerFeature does not exist` | Target is a client OS (Windows 10/11) | `(Get-CimInstance Win32_OperatingSystem).ProductType` (1 = workstation) | Query server-only classes only on server editions |
| Least-privilege test succeeds unexpectedly | `New-CimSession -Credential $null` silently uses the current identity | `whoami` **inside** the remote session | `[ValidateNotNull()]` on credential parameters; log the remote identity |
| `Get-VM: You are not currently connected to any servers` | PowerCLI and Hyper-V both export `Get-VM` | `Get-Command Get-VM -All` | Use module-qualified names (`Hyper-V\Get-VM`) |

## Task Scheduler (unattended collection)

| Error / symptom | Likely cause | Check | Fix |
|---|---|---|---|
| `LastTaskResult 267011` (`0x41303`), last run in 1999 | Task never started; the reason is only in the history | `wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true`, run again, read events | Depends on the event (next rows) |
| Events 101/104 with `0x80070569` | Account lacks *Log on as a batch job* | `secedit /export /areas USER_RIGHTS` → `SeBatchLogonRight` | Grant by GPO **including the Windows defaults** (the GPO list replaces the local one) |
| `LastTaskResult 4294770688` (`0xFFFD0000`) | `powershell.exe -File` could not find the script | `Test-Path` as the task's account | Fix the path; verify after copying |
| `Key not valid for use in specified state` | DPAPI file created by another user or machine | Owner of the credential file | Recreate the file **as the service account**, on the same machine |
| Task does not start on a laptop or a VM on a laptop | Default "do not start on battery" (Hyper-V exposes a virtual battery) | `(Get-ScheduledTask <name>).Settings.DisallowStartIfOnBatteries` | `-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries` |

## Proxy and TLS

| Error / symptom | Likely cause | Check | Fix |
|---|---|---|---|
| Squid `TCP_TUNNEL/503`, `HIER_NONE`, ~30 s per request | Proxy cannot resolve DNS | `cache.log`: *Could not find any nameservers* | Restart the proxy; make the boot wait for the network |
| `certificate verify failed` in a Windows service, browser fine | No WinHTTP proxy for OCSP/CRL revocation checks | `netsh winhttp show proxy` → *Direct access* | `netsh winhttp set proxy <proxy> "<bypass list>"` |
| `docker pull` DNS error while `dnf` works | Docker daemon has no proxy | `systemctl show docker --property=Environment` | systemd drop-in with `HTTP(S)_PROXY` / `NO_PROXY` |
| `Register-PSRepository` / PSGallery fails behind a proxy | PowerShellGet's internal web calls ignore the session proxy | `Find-Module <name>` returns nothing | Set `[Net.WebRequest]::DefaultWebProxy` and TLS 1.2, then register |
| `openssl verify` error 20 / `s_client` code 21 with the right files | CA certificate is malformed (duplicate extension) | `openssl x509 -in ca.crt -noout -text` | Rebuild the CA from an explicit config file |

## Docker and Linux

| Error / symptom | Likely cause | Check | Fix |
|---|---|---|---|
| `Restarting (1)` + `permission denied` on a mounted file | Container runs as a non-root UID | Image user (`docker inspect`), file owner (`ls -ln`) | `chown <uid>` on the file; keep restrictive mode |
| nginx `403` on a bind-mounted folder (SELinux) | Folder not labelled, or file moved in with `mv` | `ls -Z`, `ausearch -m avc -ts recent` | Mount with `:Z`; copy files with `cp` (or `restorecon`) |
| PostgreSQL restart loop: *database files are incompatible with server* | Major version changed on the same data volume | `docker compose logs db` | Roll back the image; upgrade via `pg_dump` / restore to a new volume |
| Container shows `running` but keeps failing | Caught between restarts | `docker inspect --format '{{.RestartCount}}'` | Alert on restart count or health status |

## vSphere

| Error / symptom | Likely cause | Check | Fix |
|---|---|---|---|
| *Invalid credentials* with the right password | Domain typed into the username field | User list: username vs domain columns | Recreate the user with the name only |
| Login works, inventory is empty | Permission set without *Propagate to children* | *Permissions* tab, column *Defined in* | Global (or root) Read-only permission, propagated |
| Collector "OK" but guest OS / Tools columns empty | API objects returned `null` without an error | Same query with `Get-View -Property` | Query only the needed properties; warn on empty fields |
