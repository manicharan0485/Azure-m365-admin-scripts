#Requires -Modules Microsoft.Graph.Reports

<#
.SYNOPSIS
    Exports MFA enrollment status for all users in Entra ID.

.DESCRIPTION
    Generates a full MFA readiness report:
    - Per-user MFA registration status
    - Auth methods registered (Authenticator app, SMS, FIDO2, etc.)
    - Users with NO MFA (high risk)
    - Admin accounts without MFA (critical)

.PARAMETER OutputPath
    Report output path prefix.

.PARAMETER AdminsOnly
    Only report on users with admin roles.

.EXAMPLE
    .\MFA-StatusReport.ps1
    .\MFA-StatusReport.ps1 -AdminsOnly

.NOTES
    Author:  Manicharan Ravi
    Version: 1.0.0
    
    Requires: Reports.Read.All, Directory.Read.All permissions
#>

[CmdletBinding()]
param(
    [string]$OutputPath = ".\mfa_report_$(Get-Date -Format 'yyyyMMdd_HHmmss')",
    [switch]$AdminsOnly
)

Set-StrictMode -Version Latest

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $col = switch ($Level) { "ERROR" {"Red"} "WARN" {"Yellow"} "SUCCESS" {"Green"} default {"Cyan"} }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Msg" -ForegroundColor $col
}

Write-Log "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "Reports.Read.All", "Directory.Read.All", "UserAuthenticationMethod.Read.All" -NoWelcome

Write-Log "Fetching MFA registration details..."
$mfaData = Get-MgReportCredentialUserRegistrationDetail -All

if ($AdminsOnly) {
    Write-Log "Filtering admin users only..."
    $adminRoles = Get-MgDirectoryRole
    $adminUPNs  = @()
    foreach ($role in $adminRoles) {
        $members = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id
        $adminUPNs += $members | Where-Object { $_.AdditionalProperties["userPrincipalName"] } |
            ForEach-Object { $_.AdditionalProperties["userPrincipalName"] }
    }
    $mfaData = $mfaData | Where-Object { $_.UserPrincipalName -in $adminUPNs }
    Write-Log "Admin users found: $($mfaData.Count)"
}

$report = $mfaData | ForEach-Object {
    [PSCustomObject]@{
        DisplayName       = $_.UserDisplayName
        UserPrincipalName = $_.UserPrincipalName
        MFARegistered     = $_.IsMfaRegistered
        PasswordlessReady = $_.IsPasswordlessCapable
        SSPRRegistered    = $_.IsSsprRegistered
        AuthMethods       = $_.MethodsRegistered -join ", "
        Risk              = if (-not $_.IsMfaRegistered) { "⚠️ NO MFA" } else { "OK" }
    }
}

# Stats
$noMfa     = @($report | Where-Object { -not $_.MFARegistered }).Count
$withMfa   = @($report | Where-Object { $_.MFARegistered }).Count
$total     = $report.Count
$pct       = if ($total -gt 0) { [math]::Round(($withMfa / $total) * 100, 1) } else { 0 }

Write-Log "MFA coverage: $withMfa / $total ($pct%)" $(if ($pct -lt 80) { "WARN" } else { "SUCCESS" })
Write-Log "Users WITHOUT MFA: $noMfa" $(if ($noMfa -gt 0) { "WARN" } else { "SUCCESS" })

# Export CSV
$csvPath = "$OutputPath.csv"
$report | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Log "CSV: $csvPath"

# Export HTML
$rows = $report | Sort-Object MFARegistered | ForEach-Object {
    $bg = if (-not $_.MFARegistered) { "#FDDEDE" } else { "#ffffff" }
    "<tr style='background:$bg'>
      <td>$($_.DisplayName)</td><td>$($_.UserPrincipalName)</td>
      <td>$(if($_.MFARegistered){'✅'}else{'❌'})</td>
      <td>$(if($_.PasswordlessReady){'✅'}else{'—'})</td>
      <td style='font-size:.85em'>$($_.AuthMethods)</td>
      <td><b>$($_.Risk)</b></td>
    </tr>"
}

@"
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>MFA Status Report</title>
<style>body{font-family:Segoe UI,sans-serif;margin:30px}h1{color:#0078D4}
table{border-collapse:collapse;width:100%}th{background:#0078D4;color:white;padding:9px;text-align:left}
td{padding:7px 10px;border-bottom:1px solid #eee}
.stat{display:inline-block;background:#f0f4ff;padding:10px 20px;border-radius:6px;margin:5px;font-size:1.1em}</style></head><body>
<h1>🔐 MFA Status Report</h1>
<p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')</p>
<div>
  <span class='stat'>👥 Total: <b>$total</b></span>
  <span class='stat' style='background:#dff0d8'>✅ MFA Active: <b>$withMfa ($pct%)</b></span>
  <span class='stat' style='background:#fddede'>❌ No MFA: <b>$noMfa</b></span>
</div><br>
<table><tr><th>Name</th><th>UPN</th><th>MFA</th><th>Passwordless</th><th>Methods</th><th>Status</th></tr>
$($rows -join "`n")</table></body></html>
"@ | Out-File -FilePath "$OutputPath.html" -Encoding UTF8

Write-Log "HTML: $OutputPath.html" "SUCCESS"
Disconnect-MgGraph | Out-Null
Write-Log "Done." "SUCCESS"
