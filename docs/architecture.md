# Architecture

Two diagrams: **(1)** how a typical SPLA license-inventory product works, as I understood it from the vendor's public documentation (simplified, not an official diagram), and **(2)** the lab I built to reproduce it.

## 1. Reference architecture (based on public product documentation)

```mermaid
flowchart LR
  subgraph CUST["Hosting provider network"]
    subgraph SRC["Data sources"]
      VC["vCenter / ESXi"]
      HV["Hyper-V hosts"]
      AD["Active Directory"]
      WIN["Windows servers"]
    end
    COL["Collector<br/>Windows service<br/>local config + inventory cache"]
    subgraph SRV["Server (Docker host)"]
      MQ["Message queue<br/>RabbitMQ"]
      WEB["Web UI / API"]
      DB[("PostgreSQL")]
      UPD["Auto-updater<br/>Watchtower"]
    end
    PRX["Corporate proxy"]
  end
  VEN["Vendor cloud<br/>images · licensing"]
  MS["Microsoft SPLA<br/>monthly self-report"]

  VC -- "discovery (API)" --> COL
  HV -- "discovery (API)" --> COL
  AD -- "discovery (directory)" --> COL
  WIN -- "inventory (WinRM or agent)" --> COL
  COL -- "results" --> MQ
  MQ --> WEB
  WEB --> DB
  WEB -. "license check" .-> PRX
  UPD -. "image pulls" ...-> PRX
  PRX -.-> VEN
  WEB -- "report" ---> MS
```

## 2. Lab (what I built)

```mermaid
flowchart LR
  subgraph LAP["Laptop: Windows 11 + Hyper-V, outside the domain"]
    subgraph NET["LabNet 10.10.10.0/24"]
      DC01["DC01<br/>AD DS · DNS · GPO"]
      SQL01["SQL01: Collector<br/>scheduled task as svc-collector<br/>DPAPI credentials"]
      subgraph LNX["LNX01: Rocky Linux + Docker"]
        VCS["vcsim<br/>vCenter + ESXi simulator"]
        PG[("PostgreSQL 17")]
        NGX["nginx dashboard :8080"]
      end
      GW01["GW01: Squid proxy"]
    end
    HVH["Hyper-V host<br/>the laptop itself"]
  end
  HOL["VMware Hands-on Lab<br/>real vCenter 9.1, tested separately"]
  INET["Internet<br/>Azure Arc · Docker Hub · PSGallery"]

  SQL01 -- "PowerCLI :443" --> VCS
  SQL01 -- "WinRM, Kerberos" --> DC01
  SQL01 -- "WinRM, NTLM + TrustedHosts" --> HVH
  SQL01 -. "data.json" .-> NGX
  DC01 -. "GPO rights" .-> SQL01
  SQL01 -. "proxy" .-> GW01
  LNX -. "proxy" .-> GW01
  GW01 --> INET
```

## Mapping

| Reference | Lab |
|---|---|
| Collector | SQL01: PowerShell scripts run by a scheduled task |
| Server (Docker) | LNX01: Docker Compose with PostgreSQL + nginx |
| vCenter / ESXi | vcsim (simulator) + VMware Hands-on Lab (real) |
| Hyper-V hosts | The laptop, outside the domain |
| Active Directory | DC01 |
| Corporate proxy | GW01 (Squid), the only way out |
| Monthly report | Dashboard: licensed cores per host |

**Not reproduced:** message queue, agent-based mode, auto-updater (its main risk, a database major-version change, was tested by hand).
