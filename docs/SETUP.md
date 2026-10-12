# Setup Guide

## Prerequisites

### PowerShell Modules

```powershell
# Run as Administrator
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser

Install-Module Microsoft.Graph           -Scope CurrentUser -Force
Install-Module ExchangeOnlineManagement  -Scope CurrentUser -Force
Install-Module PnP.PowerShell            -Scope CurrentUser -Force

# Verify
Get-Module Microsoft.Graph -ListAvailable | Select Name, Version
```

### Python (for reporting scripts)

```bash
cd python/
pip install -r requirements.txt
```

---

## Authentication

### PowerShell (Interactive - Delegated Permissions)

All PowerShell scripts use interactive login via `Connect-MgGraph`:

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All"
```

Use your **Global Admin** or role-specific admin account.

### Python (App Registration - Application Permissions)

1. Go to **Entra ID → App registrations → New registration**
2. Name: `M365-Reporting-App`
3. Add **API permissions** (Application, not Delegated):
   - `User.Read.All`
   - `AuditLog.Read.All`
   - `IdentityRiskyUser.Read.All`
   - `Policy.Read.All`
   - `DeviceManagementManagedDevices.Read.All`
   - `Reports.Read.All`
4. **Grant admin consent**
5. Create a **Client secret** under Certificates & secrets
6. Note: Tenant ID, Client ID, Client Secret

```bash
python python/reporting/m365_compliance_report.py \
  --tenant "your-tenant-id" \
  --client "your-client-id" \
  --secret "your-client-secret" \
  --output ./reports
```

---

## Quick Start

### 1. MFA Audit (5 min)

```powershell
cd powershell/entra-id
.\MFA-StatusReport.ps1
# Opens browser for login → generates mfa_report_YYYYMMDD.html
```

### 2. License Cost Report (5 min)

```powershell
cd powershell/m365-licensing
.\License-AuditReport.ps1
# Opens browser for login → generates license_audit_YYYYMMDD.html
```

### 3. Fix Error 135011 (Disabled Device)

```powershell
cd powershell/entra-id
.\Device-ComplianceAudit.ps1 -WhatIf          # Preview
.\Device-ComplianceAudit.ps1                   # Fix disabled devices
```

### 4. Bulk Provision Users

```powershell
cd powershell/entra-id
# Edit sample_users.csv with your users
.\Bulk-UserProvisioning.ps1 -CsvPath ".\sample_users.csv" -WhatIf
.\Bulk-UserProvisioning.ps1 -CsvPath ".\sample_users.csv"
```

### 5. Fix SharePoint Broken Inheritance

```powershell
cd powershell/sharepoint
.\BrokenInheritance-Fix.ps1 `
  -TenantUrl "https://yourtenant-admin.sharepoint.com" `
  -SiteUrl "https://yourtenant.sharepoint.com/sites/Finance" `
  -FixInheritance
```

### 6. Configure Dual Mail (M365 + Strato)

```powershell
cd powershell/exchange
.\MailFlow-Connector.ps1 `
  -SmartHost "smtpin.rzone.de" `
  -SenderDomain "yourdomain.de" `
  -WhatIf   # Preview first!
```

---

## Safety Checklist

- [ ] Always run with `-WhatIf` first
- [ ] Test in a **dev/sandbox tenant** before production
- [ ] Never commit credentials or secrets
- [ ] Back up before bulk operations
- [ ] Review log CSV after each run
