# SPLA License Inventory Lab

A one-laptop lab that reproduces how a license-inventory product runs at a hosting provider: a **collector** discovers hypervisors and inventories Windows servers, a **server stack** stores and shows the results, and everything works **unattended, with least privilege, behind a corporate proxy**.

Built to practice the real job: deploying a collector at a customer site and finding out why it does not collect.

**Architecture:** reference product vs. lab, side by side → [docs/architecture.md](docs/architecture.md)

## Components

| Machine | Role | Stack |
|---|---|---|
| SQL01 | Collector (scheduled task) | Windows Server 2022, PowerShell, PowerCLI |
| LNX01 | Server side + dashboard | Rocky Linux, Docker Compose, PostgreSQL 17, nginx |
| DC01 | Customer Active Directory | AD DS, DNS, GPO |
| Laptop | Hyper-V host outside the domain | Windows 11 Pro, Hyper-V |
| GW01 | Corporate proxy, only way out | Debian, Squid |
| vcsim / VMware HOL | vCenter and ESXi | vcsim (simulator), vSphere 9.1 Hands-on Lab |
| Azure Arc | First exercise: onboarding a real agent through the proxy | Azure Arc agent + SQL Server extension |

## What it collects

- **vSphere**: hosts, clusters, VMs, guest OS, VMware Tools (PowerCLI, read-only account)
- **Windows servers**: OS, sockets/cores, SQL Server edition, RDS role, installed software (WinRM/CIM)
- **Hyper-V**: VMs per host, linked to the Windows inventory
- **SPLA estimate**: licensed cores per host = max(physical cores, 8 × sockets, 16)

## Key design points

- **No admin rights**: WinRM via *Remote Management Users*, WMI via *Remote Enable* on `root\cimv2`, rights granted by GPO using SIDs. Never *Administrators* on a domain controller.
- **Unattended**: scheduled task as a service account, credentials protected with DPAPI, exit codes `0` OK / `1` partial / `2` no credentials.
- **Outside the domain**: NTLM with TrustedHosts limited to one IP; WinRM firewall rule limited to the lab subnet.
- **Safe changes**: database backup validated before an upgrade; rollback tested.
- **Data quality first**: the dashboard flags unknown guest OS, failed targets and SQL Express (not reportable).

## Incidents

Every problem was investigated with evidence and written up as a short RCA → [docs/rca.md](docs/rca.md)

| # | Symptom | Root cause |
|---|---|---|
| 1 | Azure Arc agent: all endpoints unreachable | Proxy started before the network had DNS |
| 2 | Azure Arc SQL extension: *certificate verify failed* | Service had no WinHTTP proxy for OCSP/CRL checks |
| 3 | `docker pull` DNS error, `dnf` worked | Docker daemon had no proxy (user vs service context) |
| 4 | vCenter simulator container in a restart loop | Key file not readable by the container's UID |
| 5 | Lab CA certificates not trusted | CA had a duplicated extension (RFC 5280) |
| 6 | vCenter collector "OK" but empty columns | API object returned `null` without an error |
| 7 | Least-privilege test passed as admin | Empty credential silently fell back to the current user |
| — | Scheduled task never ran, then failed 4 more ways | Batch logon right, missing file, DPAPI owner, wrong password, client OS |
| — | Database in a restart loop after an "update" | Major-version change on the same data volume |

Error codes and fixes in one table → [docs/troubleshooting.md](docs/troubleshooting.md)

## Repository

```
docs/
  architecture.md       reference product vs. lab (Mermaid)
  rca.md                root cause analyses
  troubleshooting.md    error → cause → check → fix
scripts/
  collector/            vSphere + Windows inventory, scheduled run, license estimate, dashboard export
  hardening/            AD account + GPO, WMI permission, standalone Hyper-V host, scheduled task
  server/               Docker Compose (PostgreSQL + nginx), dashboard, safe upgrade script
```

> Lab estimate only, not licensing advice. Passwords and personal identifiers removed.
