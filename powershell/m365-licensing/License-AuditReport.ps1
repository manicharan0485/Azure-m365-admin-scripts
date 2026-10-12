#Requires -Modules Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Users

<#
.SYNOPSIS
    Full Microsoft 365 license inventory with cost estimation and optimization recommendations.

.DESCRIPTION
    Audits all M365 licenses in the tenant:
    - Total purchased vs consumed vs available
    - Users with assigned but unused licenses (inactive 30+ days)
    - Estimated monthly cost (EUR) based on standard pricing
    - Recommendations to reclaim licenses and reduce spend

.PARAMETER InactiveDays
    Days of inactivity to flag a licensed user. Default: 30

.PARAMETER OutputPath
    Report output path (no extension). Generates both CSV and HTML.

.EXAMPLE
    .\License-AuditReport.ps1
    .\License-AuditReport.ps1 -InactiveDays 45 -OutputPath "C:\Reports\license_audit"

.NOTES
    Author:  Manicharan Ravi
    Version: 1.1.0
    
    Typical savings: 15-25% license cost reduction by reclaiming unused seats.
    
    SKU pricing reference (EUR/month, approximate):
      ENTERPRISEPACK        (E3)  = 28.10
      SPE_E5                (E5)  = 57.00
      BUSINESS_PREMIUM             = 22.00
      TEAMS_ESSENTIALS             =  4.00
#>

[CmdletBinding()]
param(
    [int]$InactiveDays  = 30,
    [string]$OutputPath = ".\license_audit_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
)

Set-StrictMode -Version Latest

# Approximate EUR monthly pricing per SKU
$skuPricing = @{
    "ENTERPRISEPACK"              = 28.10   # E3
    "SPE_E5"                      = 57.00   # E5
    "BUSINESS_PREMIUM"            = 22.00   # Microsoft 365 Business Premium
    "BUSINESS_BASIC"              =  6.00
    "BUSINESS_STANDARD"           = 12.50
    "TEAMS_ESSENTIALS"            =  4.00
    "POWER_BI_PRO"                = 10.00
    "PROJECTPREMIUM"              = 55.00
    "VISIOCLIENT"                 = 28.00
    "INTUNE_A"                    =  8.00
    "EMS"                         = 14.80   # Enterprise Mobility + Security E3
    "EMSPREMIUM"                  = 28.80   # EMS E5
}

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $col = switch ($Level) { "ERROR" {"Red"} "WARN" {"Yellow"} "SUCCESS" {"Green"} default {"Cyan"} }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Msg" -ForegroundColor $col
}

#region --- Connect ---
Write-Log "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "User.Read.All", "Directory.Read.All", "AuditLog.Read.All", "Organization.Read.All" -NoWelcome
#endregion

#region --- Get SKU inventory ---
Write-Log "Fetching license inventory..."
$skus = Get-MgSubscribedSku

$skuSummary = [System.Collections.Generic.List[PSCustomObject]]::new()
$totalMonthlyCost = 0
$totalUnused       = 0

foreach ($sku in $skus) {
    $purchased = $sku.PrepaidUnits.Enabled
    $consumed  = $sku.ConsumedUnits
    $available = $purchased - $consumed
    $unitPrice = if ($skuPricing.ContainsKey($sku.SkuPartNumber)) { $skuPricing[$sku.SkuPartNumber] } else { 0 }
    $monthlyCost = [math]::Round($unitPrice * $purchased, 2)
    $wastedCost  = [math]::Round($unitPrice * $available, 2)

    $totalMonthlyCost += $monthlyCost
    $totalUnused      += $available

    $skuSummary.Add([PSCustomObject]@{
        SkuName        = $sku.SkuPartNumber
        Purchased      = $purchased
        Consumed       = $consumed
        Available      = $available
        UnitPriceEUR   = $unitPrice
        MonthlyCostEUR = $monthlyCost
        WastedCostEUR  = $wastedCost
        Utilization    = if ($purchased -gt 0) { "$([math]::Round(($consumed / $purchased) * 100, 1))%" } else { "N/A" }
    })
}
#endregion

#region --- Find inactive licensed users ---
Write-Log "Checking user sign-in activity (last $InactiveDays days)..."
$inactiveThreshold = (Get-Date).AddDays(-$InactiveDays)

$allUsers = Get-MgUser -All -Property "Id,DisplayName,UserPrincipalName,AssignedLicenses,SignInActivity,AccountEnabled" |
    Where-Object { $_.AssignedLicenses.Count -gt 0 }

Write-Log "Licensed users found: $($allUsers.Count)"

$inactiveUsers = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($u in $allUsers) {
    $lastSignIn = $u.SignInActivity?.LastSignInDateTime
    $inactive   = (-not $lastSignIn) -or ($lastSignIn -lt $inactiveThreshold)

    if ($inactive) {
        $licenseNames = $u.AssignedLicenses | ForEach-Object {
            $skuMatch = $skus | Where-Object { $_.SkuId -eq $_.SkuId }
            $_.SkuId
        }

        $inactiveUsers.Add([PSCustomObject]@{
            DisplayName       = $u.DisplayName
            UserPrincipalName = $u.UserPrincipalName
            AccountEnabled    = $u.AccountEnabled
            LastSignIn        = if ($lastSignIn) { $lastSignIn.ToString("yyyy-MM-dd") } else { "Never" }
            LicenseCount      = $u.AssignedLicenses.Count
            Recommendation    = if (-not $u.AccountEnabled) { "Remove license (disabled account)" } else { "Review - inactive user" }
        })
    }
}
#endregion

#region --- Export ---
$csvPath  = "$OutputPath.csv"
$htmlPath = "$OutputPath.html"

# CSV exports
$skuSummary    | Export-Csv -Path "${OutputPath}_inventory.csv" -NoTypeInformation -Encoding UTF8
$inactiveUsers | Export-Csv -Path "${OutputPath}_inactive.csv"  -NoTypeInformation -Encoding UTF8

# HTML Report
$skuRows = $skuSummary | ForEach-Object {
    $bg = if ([int]($_.Available) -gt 5) { "#FFF3CD" } else { "#ffffff" }
    "<tr style='background:$bg'>
      <td>$($_.SkuName)</td><td>$($_.Purchased)</td><td>$($_.Consumed)</td>
      <td>$($_.Available)</td><td>$($_.Utilization)</td>
      <td>€$($_.MonthlyCostEUR)</td><td style='color:$(if($_.WastedCostEUR -gt 0){"#c00"}else{"#080"})'>€$($_.WastedCostEUR)</td>
    </tr>"
}

$inactiveRows = $inactiveUsers | ForEach-Object {
    "<tr><td>$($_.DisplayName)</td><td>$($_.UserPrincipalName)</td>
     <td>$($_.LastSignIn)</td><td>$($_.LicenseCount)</td>
     <td style='color:#c00'><b>$($_.Recommendation)</b></td></tr>"
}

$annualCost  = [math]::Round($totalMonthlyCost * 12, 0)
$wastedTotal = ($skuSummary | Measure-Object -Property WastedCostEUR -Sum).Sum

$html = @"
<!DOCTYPE html><html><head><meta charset='UTF-8'>
<title>M365 License Audit</title>
<style>
  body{font-family:Segoe UI,sans-serif;margin:30px;color:#333}
  h1,h2{color:#D83B01} table{border-collapse:collapse;width:100%;margin-bottom:30px}
  th{background:#D83B01;color:white;padding:10px;text-align:left}
  td{padding:8px 10px;border-bottom:1px solid #eee}
  .kpi{display:flex;gap:20px;margin:20px 0}
  .kpi-card{background:#f5f5f5;border-left:4px solid #D83B01;padding:15px 20px;border-radius:4px;flex:1}
  .kpi-val{font-size:2em;font-weight:bold;color:#D83B01}
</style></head><body>
<h1>📊 Microsoft 365 License Audit Report</h1>
<p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Inactive threshold: $InactiveDays days</p>

<div class='kpi'>
  <div class='kpi-card'><div class='kpi-val'>€$([math]::Round($totalMonthlyCost,0))/mo</div>Total License Cost</div>
  <div class='kpi-card'><div class='kpi-val'>€$annualCost/yr</div>Annual Spend</div>
  <div class='kpi-card'><div class='kpi-val' style='color:#c00'>€$([math]::Round($wastedTotal,0))/mo</div>Potential Savings</div>
  <div class='kpi-card'><div class='kpi-val'>$($inactiveUsers.Count)</div>Inactive Licensed Users</div>
</div>

<h2>License Inventory</h2>
<table><tr><th>SKU</th><th>Purchased</th><th>Consumed</th><th>Available</th><th>Utilization</th><th>Monthly Cost</th><th>Wasted Cost</th></tr>
$($skuRows -join "`n")
</table>

<h2>Inactive Licensed Users (Action Required)</h2>
<table><tr><th>Name</th><th>UPN</th><th>Last Sign-In</th><th>Licenses</th><th>Recommendation</th></tr>
$($inactiveRows -join "`n")
</table>
</body></html>
"@

$html | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Log "HTML report: $htmlPath" "SUCCESS"

Write-Log "=== COST SUMMARY ===" "SUCCESS"
Write-Log "  Monthly spend  : €$([math]::Round($totalMonthlyCost,2))"
Write-Log "  Annual spend   : €$annualCost"
Write-Log "  Potential save : €$([math]::Round($wastedTotal,2))/month" "WARN"
Write-Log "  Inactive users : $($inactiveUsers.Count)" "WARN"
#endregion

Disconnect-MgGraph | Out-Null
Write-Log "Audit complete." "SUCCESS"
