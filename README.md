# 🔐 Azure & M365 Admin Scripts

> **Production-grade PowerShell & Python automation for Microsoft 365, Entra ID, Intune, and SharePoint.**  
> Built from real-world IT administration experience managing enterprise environments.

![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?style=flat&logo=powershell&logoColor=white)
![Azure](https://img.shields.io/badge/Azure-0078D4?style=flat&logo=microsoftazure&logoColor=white)
![M365](https://img.shields.io/badge/Microsoft_365-D83B01?style=flat&logo=microsoft&logoColor=white)
![Python](https://img.shields.io/badge/Python-3776AB?style=flat&logo=python&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green)

---

## 📂 Repository Structure

```
azure-m365-admin-scripts/
│
├── powershell/
│   ├── entra-id/           # Entra ID (Azure AD) user & device management
│   ├── intune/             # Intune device compliance & reporting
│   ├── m365-licensing/     # License audit & assignment automation
│   ├── sharepoint/         # SharePoint permission management
│   └── exchange/           # Exchange Online mail flow & connectors
│
├── python/
│   ├── reporting/          # Automated HTML/CSV reports via Graph API
│   └── automation/         # Bulk operations & scheduled tasks
│
└── docs/                   # Architecture diagrams & setup guides
```

---

## 🚀 Scripts Overview

### Entra ID (Azure AD)
| Script | Description |
|--------|-------------|
| `Bulk-UserProvisioning.ps1` | Create/update users from CSV with license assignment |
| `Device-ComplianceAudit.ps1` | Detect & remediate disabled/non-compliant devices (Error 135011 fix) |
| `StaleAccount-Cleanup.ps1` | Find and disable accounts inactive for 90+ days |
| `MFA-StatusReport.ps1` | Export MFA enrollment status for all users |

### Intune
| Script | Description |
|--------|-------------|
| `DeviceCompliance-Report.ps1` | Full compliance report across all managed devices |
| `AppDeployment-Status.ps1` | Check app installation status across device fleet |
| `Autopilot-Enrollment.ps1` | Register devices to Windows Autopilot via CSV |

### M365 Licensing
| Script | Description |
|--------|-------------|
| `License-AuditReport.ps1` | Full license inventory with cost estimation |
| `UnusedLicense-Reclaim.ps1` | Identify and reclaim licenses from inactive users |
| `License-BulkAssign.ps1` | Bulk assign/remove licenses from CSV |

### SharePoint
| Script | Description |
|--------|-------------|
| `Permission-Audit.ps1` | Full permissions report for all sites/libraries |
| `BrokenInheritance-Fix.ps1` | Detect and fix broken permission inheritance |
| `ExternalSharing-Report.ps1` | Report on externally shared files and sites |

### Exchange Online
| Script | Description |
|--------|-------------|
| `MailFlow-Connector.ps1` | Configure hybrid mail connectors (e.g., Strato + M365 dual routing) |
| `Mailbox-Audit.ps1` | Export mailbox permissions and delegates |
| `AntiSpam-PolicyReport.ps1` | Export spam filter and safe sender configurations |

---

## ⚙️ Prerequisites

```powershell
# Install required modules
Install-Module Microsoft.Graph -Scope CurrentUser
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser
Install-Module AzureAD -Scope CurrentUser

# Connect
Connect-MgGraph -Scopes "User.ReadWrite.All", "Device.ReadWrite.All", "Directory.ReadWrite.All"
Connect-ExchangeOnline
Connect-SPOService -Url "https://yourtenant-admin.sharepoint.com"
```

---

## 🔐 Permissions Required

| Area | Required Role |
|------|--------------|
| Entra ID | Global Admin / User Administrator |
| Intune | Intune Administrator |
| M365 Licensing | License Administrator |
| SharePoint | SharePoint Administrator |
| Exchange | Exchange Administrator |

> ⚠️ Always run in a **test tenant** first. Use `-WhatIf` parameter where available.

---

## 📊 Key Use Cases

- **Onboarding automation** — Provision users, assign licenses, configure MFA in one run
- **Compliance reporting** — Generate audit-ready reports for ISO 27001 / SOC 2
- **Cost optimization** — Reclaim unused M365 licenses (typical savings: 15–25%)
- **Security hardening** — Detect stale accounts, non-compliant devices, MFA gaps
- **Incident response** — Quickly disable compromised accounts and audit access

---

## 🧪 Testing

All scripts support `-WhatIf` and `-Verbose` flags:

```powershell
.\Bulk-UserProvisioning.ps1 -CsvPath ".\users.csv" -WhatIf -Verbose
```

---

## 📄 License

MIT — Free to use and adapt. Attribution appreciated.

---

## 👤 Author

**Manicharan Ravi** — IT Specialist | Cloud Security Engineer  
📍 Mainz, Germany  
🔗 [LinkedIn](https://linkedin.com/in/manicharan-ravi)  
☁️ Azure · AWS · GCP · M365 · Intune · Entra ID
