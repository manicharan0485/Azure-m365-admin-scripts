#Requires -Modules Microsoft.Online.SharePoint.PowerShell, PnP.PowerShell

<#
.SYNOPSIS
    Detects and fixes broken permission inheritance in SharePoint Online.

.DESCRIPTION
    Scans SharePoint site libraries and folders for broken inheritance.
    Generates a full audit report and optionally restores inheritance.
    
    Common cause: Users manually changing folder permissions via "Stop Inheriting 
    Permissions" creates isolated permission sets that are hard to audit.

.PARAMETER TenantUrl
    SharePoint admin URL, e.g. https://contoso-admin.sharepoint.com

.PARAMETER SiteUrl
    Target site URL. If omitted, scans all sites.

.PARAMETER FixInheritance
    If set, resets broken inheritance back to parent (with confirmation).

.PARAMETER OutputPath
    Report output folder.

.EXAMPLE
    # Audit only
    .\BrokenInheritance-Fix.ps1 -TenantUrl "https://contoso-admin.sharepoint.com" -SiteUrl "https://contoso.sharepoint.com/sites/Finance"

    # Audit + fix
    .\BrokenInheritance-Fix.ps1 -TenantUrl "https://contoso-admin.sharepoint.com" -SiteUrl "https://contoso.sharepoint.com/sites/Finance" -FixInheritance

.NOTES
    Author:  Manicharan Ravi
    Version: 1.0.0
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$TenantUrl,

    [string]$SiteUrl,

    [switch]$FixInheritance,

    [string]$OutputPath = ".\sp_inheritance_audit_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $col = switch ($Level) { "ERROR" {"Red"} "WARN" {"Yellow"} "SUCCESS" {"Green"} "FIX" {"Magenta"} default {"Cyan"} }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Msg" -ForegroundColor $col
}

function Get-BrokenInheritanceItems {
    param([string]$SiteUrl)
    
    Connect-PnPOnline -Url $SiteUrl -Interactive
    
    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $lists    = Get-PnPList | Where-Object { $_.BaseType -eq "DocumentLibrary" -and -not $_.Hidden }

    foreach ($list in $lists) {
        Write-Log "  Scanning: $($list.Title)" 
        
        $items = Get-PnPListItem -List $list -Fields "FileLeafRef,FileRef,HasUniqueRoleAssignments" -PageSize 500

        foreach ($item in $items) {
            if ($item["HasUniqueRoleAssignments"] -eq $true) {
                $perms = Get-PnPProperty -ClientObject $item -Property RoleAssignments
                
                $permSummary = $perms | ForEach-Object {
                    $member    = Get-PnPProperty -ClientObject $_ -Property Member
                    $roleDefs  = Get-PnPProperty -ClientObject $_ -Property RoleDefinitionBindings
                    "$($member.LoginName): $($roleDefs.Name -join ',')"
                }

                $findings.Add([PSCustomObject]@{
                    SiteUrl      = $SiteUrl
                    Library      = $list.Title
                    ItemPath     = $item["FileRef"]
                    ItemName     = $item["FileLeafRef"]
                    ItemId       = $item.Id
                    Permissions  = $permSummary -join " | "
                    InheritanceBroken = $true
                })
            }
        }
    }

    Disconnect-PnPOnline
    return $findings
}

#region --- Connect SPO Admin ---
Write-Log "Connecting to SharePoint Online..."
Connect-SPOService -Url $TenantUrl
#endregion

#region --- Get Sites ---
if ($SiteUrl) {
    $sites = @([PSCustomObject]@{ Url = $SiteUrl })
} else {
    Write-Log "Fetching all site collections..."
    $sites = Get-SPOSite -Limit All | Select-Object Url, Title
    Write-Log "Found $($sites.Count) sites."
}
#endregion

#region --- Scan ---
$allFindings = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($site in $sites) {
    Write-Log "Scanning: $($site.Url)"
    try {
        $siteFindings = Get-BrokenInheritanceItems -SiteUrl $site.Url
        $siteFindings | ForEach-Object { $allFindings.Add($_) }
        Write-Log "  Found $($siteFindings.Count) item(s) with broken inheritance" $(if ($siteFindings.Count -gt 0) { "WARN" } else { "SUCCESS" })
    } catch {
        Write-Log "  Error scanning $($site.Url): $_" "ERROR"
    }
}

Write-Log "Total broken inheritance items: $($allFindings.Count)" $(if ($allFindings.Count -gt 0) { "WARN" } else { "SUCCESS" })
#endregion

#region --- Fix ---
if ($FixInheritance -and $allFindings.Count -gt 0) {
    $confirm = Read-Host "⚠️  Reset inheritance on $($allFindings.Count) item(s)? This removes custom permissions. Type 'YES'"
    if ($confirm -eq "YES") {
        foreach ($finding in $allFindings) {
            if ($PSCmdlet.ShouldProcess($finding.ItemPath, "Reset permission inheritance")) {
                try {
                    Connect-PnPOnline -Url $finding.SiteUrl -Interactive
                    $item = Get-PnPListItem -List $finding.Library -Id $finding.ItemId
                    Set-PnPListItemPermission -List $finding.Library -Identity $finding.ItemId -ResetRoleInheritance
                    Write-Log "  ✔ Fixed: $($finding.ItemPath)" "FIX"
                    Disconnect-PnPOnline
                } catch {
                    Write-Log "  ✘ Failed: $($finding.ItemPath) — $_" "ERROR"
                }
            }
        }
    }
}
#endregion

#region --- Export ---
$csvPath  = "$OutputPath.csv"
$htmlPath = "$OutputPath.html"

$allFindings | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Log "CSV: $csvPath"

$rows = $allFindings | ForEach-Object {
    "<tr>
      <td>$($_.Library)</td>
      <td style='font-size:0.85em'>$($_.ItemPath)</td>
      <td style='font-size:0.8em;color:#666'>$($_.Permissions)</td>
    </tr>"
}

@"
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>SP Inheritance Audit</title>
<style>body{font-family:Segoe UI,sans-serif;margin:30px}h1{color:#0078D4}
table{border-collapse:collapse;width:100%}th{background:#0078D4;color:white;padding:9px;text-align:left}
td{padding:7px 10px;border-bottom:1px solid #eee}tr:nth-child(even){background:#f9f9f9}</style></head><body>
<h1>🔒 SharePoint Broken Inheritance Audit</h1>
<p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Items found: <b>$($allFindings.Count)</b></p>
<table><tr><th>Library</th><th>Item Path</th><th>Custom Permissions</th></tr>
$($rows -join "`n")</table></body></html>
"@ | Out-File -FilePath $htmlPath -Encoding UTF8

Write-Log "HTML: $htmlPath" "SUCCESS"
Write-Log "Done." "SUCCESS"
#endregion
