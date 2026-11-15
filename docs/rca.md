# Root cause analyses

Problems found while building and running the lab. Each entry starts with **what I was doing**, then **symptom → root cause → fix → lesson**. Disproved hypotheses are kept when they were part of the investigation.

---

### RCA-1 · Azure Arc agent could not reach any endpoint
- **Context:** connecting a Windows server (SQL01) to Azure Arc, a Microsoft management agent, through the lab's corporate proxy (Squid).
- **Symptom:** the agent's connectivity check failed for every endpoint; the proxy logged `TCP_TUNNEL/503` after ~30 s per request.
- **Root cause:** after a reboot, the proxy started before DHCP had written its DNS settings (`cache.log`: *Could not find any nameservers*). The network interface was `allow-hotplug`, so the boot did not wait for it.
- **Fix:** restart Squid; set the interface to `auto` and confirm with a reboot.
- **Lesson:** a 503 from a proxy is often the proxy's own DNS, not the destination.

### RCA-2 · Azure Arc SQL Server extension stuck in "Creating"
- **Context:** after the agent was connected, installing its SQL Server extension, which downloads a package from Azure.
- **Symptom:** the download failed with *certificate verify failed* from the first attempt, while the agent itself was healthy.
- **Ruled out:** clock, TLS inspection by the proxy, missing root CA (the "missing" root was cross-signed by one already trusted).
- **Root cause:** Windows had no **WinHTTP** proxy, so the agent's service could not reach OCSP/CRL to check certificate revocation.
- **Fix:** `netsh winhttp set proxy` with a bypass list, then reinstall the extension (it does not retry by itself).
- **Lesson:** a user session and a Windows service use different proxy settings. Also: confirm a "diagnostic" command is read-only before running it (one stopped the agent's extension service).

### RCA-3 · Docker could not download images, while the package manager could
- **Context:** installing Docker on the Linux server (LNX01), which reaches the internet only through the proxy.
- **Symptom:** `docker pull` failed with a DNS error (`lookup registry-1.docker.io ... server misbehaving`); `dnf` worked fine.
- **Root cause:** the Docker **daemon** runs as a systemd service without a proxy; the proxy in `dnf.conf` and in the shell only applies to `dnf` and the CLI.
- **Fix:** systemd drop-in with `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`, then `daemon-reload` and restart.
- **Lesson:** same pattern as RCA-2: user context vs. service context.

### RCA-4 · vCenter simulator container in a restart loop
- **Context:** giving the vCenter/ESXi simulator (vcsim, in Docker) a certificate from the lab CA, so the collector could connect with valid TLS.
- **Symptom:** `Restarting (1)` with growing back-off; logs: `open /certs/tls.key: permission denied`.
- **Ruled out:** SELinux (Enforcing, but no denials logged).
- **Root cause:** the image runs as a non-root user (UID 10001); the key file belonged to root with mode `600`.
- **Fix:** `chown 10001:10001` on the key, keeping mode `600`. Rejected: `chmod 644`, running as root, disabling SELinux.
- **Lesson:** fix the ownership, not the security model.

### RCA-5 · Certificates from the new lab CA were not trusted
- **Context:** creating a small certificate authority with OpenSSL to issue the simulator's certificates.
- **Symptom:** `openssl verify` error 20 / `s_client` code 21: the CA was not accepted as the issuer.
- **Ruled out:** wrong file served, regenerated CA, name hash, key pair (each checked with a hash).
- **Root cause:** the CA certificate had the `basicConstraints` extension **twice** (distribution default + my own flag), which RFC 5280 forbids.
- **Fix:** rebuild the CA from an explicit config file, re-sign the existing requests.
- **Lesson:** do not trust distribution defaults for a CA; inspect the certificate actually issued.

### RCA-6 · vCenter collector reported "OK" with empty columns
- **Context:** the first version of the PowerCLI script that lists VMs from vCenter (guest OS, VMware Tools) for the license estimate.
- **Symptom:** the log said `OK: 12 VMs`, but the guest OS and Tools columns were blank.
- **Root cause:** the API object came back `null` **without an error**, so the CSV was written with empty fields.
- **Fix:** query with `Get-View -Property` (only the needed fields), collect `GuestId`, log a warning when key fields are empty.
- **Lesson:** "no error" is not "correct data"; validate the output, not only the exit code.

### RCA-7 · Least-privilege test passed, but it ran as admin
- **Context:** proving that the Windows inventory works with a non-admin service account (no local admin, no domain admin).
- **Symptom:** WMI reads worked without the *Remote Enable* permission, contradicting the documentation.
- **Root cause:** a recreated session left the credential variable empty; `New-CimSession -Credential $null` **silently** used the current admin identity.
- **Fix:** mandatory non-null credential in every script; log the remote `whoami` per target. With the real account, WMI returned *access denied* as documented, and the permission was then granted.
- **Lesson:** prove the identity behind a test before trusting its result.

---

### Incident · Scheduled collection: one failure hiding the next
**Context:** running the collector every night as a Windows scheduled task, under the service account, with nobody logged on and credentials stored encrypted (DPAPI).

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | `0x41303` "has not yet run" | Battery setting suspected, **disproved** by the task history | Enabled Task Scheduler history (off by default) |
| 2 | Events 101/104, `0x80070569` | Account lacked the *Log on as a batch job* right | Granted by GPO, **keeping the Windows defaults** (a GPO user right replaces the whole list) |
| 3 | `0xFFFD0000` | Script file not at the task's path | Copied, then verified on the server |
| 4 | Exit 2, *Key not valid for use in specified state* | Encrypted credential files created by the admin, not the service account | Recreated as the service account; file owner checked |
| 5 | vCenter *Login failure* | Wrong stored password (length checked, value never shown) | Recreated and tested right after saving |
| 6 | *Win32_ServerFeature does not exist* | Script assumed Windows Server; the Hyper-V host runs Windows 11 | Query server roles only on server editions |

**Result:** exit code `0`, all three stages OK, nobody logged on.

### Incident · Database restart loop after an "update"
- **Context:** the server stack (PostgreSQL in Docker). Simulating what an auto-updater does with a floating image tag: `postgres:16` → `postgres:17` on the same data volume.
- **Symptom:** restart loop, `FATAL: database files are incompatible with server`. `docker inspect` showed `running` with 8 restarts.
- **Root cause:** a new major version cannot open the previous version's data directory (it refuses to start; the data stays intact).
- **Fix:** rollback by pinning `postgres:16`. Proper upgrade: new volume, restore the validated `pg_dump`, keep the old volume for rollback.
- **Lesson:** pin the database's major version or exclude it from auto-updates; alert on restart count, not on "is it running".

---

### Other findings (VMware Hands-on Lab, real vCenter 9.1)
- Login *Invalid credentials* with the right password: the domain had been typed into the username field.
- Read-only permission on a cluster **without propagation**: login works, inventory comes back empty.
- A *Must run on* VM-host rule blocks vMotion and power-on outside the host group, but not cold migration of a powered-off VM.
- *Should* rule + DRS partially automated: the violation waits as a recommendation, so the host stays in license scope for the month.
