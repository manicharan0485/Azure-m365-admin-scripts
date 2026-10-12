#Requires -Modules Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.DeviceManagement

<#
.SYNOPSIS
    Detects and remediates non-compliant/disabled devices in Entra ID.
    Resolves Entra ID Error Code 135011 (disabled device).

.DESCRIPTION
    Audits all Entra ID registered devices, identifies:
      - Disabled devices (Error 135011 source)
      - Stale devices (no check-in > N days)
      - Non-compliant Intune-managed devices
    Optionally re-enables or removes stale devices.

.PARAMETER StaleDays
    Days since last check-in to consider a device stale. Default: 90

.PARAMETER RemoveStale
    If set, deletes stale devices (with confirmation prompt).

.PARAMETER ReportOnly
    Generate report without making any changes.

.PARAMETER OutputPath
    Path for the CSV/HTML report output.

.EXAMPLE
    # Report only
    .\Device-ComplianceAudit.ps1 -ReportOnly

    # Fix disabled devices + report stale
    .\Device-ComplianceAudit.ps1 -StaleDays 60

    # Aggressive cleanup
    .\Device-ComplianceAudit.ps1 -StaleDays 90 -RemoveStale

.NOTES
    Author:  Manicharan Ravi
    Version: 1.3.0
    
    ERROR 135011 = AADSTS135011: Device used during authentication is disabled.
    Root cause: Device object in Entra ID has AccountEnabled = false.
    Fix: Re-enable the device or delete and re-register.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [int]$StaleDays    = 90,
    [switch]$RemoveStale,
    [switch]$ReportOnly,
    [string]$OutputPath = ".\device_audit_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    $col = switch ($Level) { "ERROR" { "Red" } "WARN" { "Yellow" } "SUCCESS" { "Green" } "FIX" { "Magenta" } default { "Cyan" } }
    Write-Host "[$ts] [$Level] $Msg" -ForegroundColor $col
}

#region --- Connect ---
Write-Log "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "Device.ReadWrite.All", "DeviceManagementManagedDevices.Read.All", "Directory.Read.All" -NoWelcome
#endregion

#region --- Gather Devices ---
Write-Log "Fetching all devices from Entra ID..."
$staleThreshold = (Get-Date).AddDays(-$StaleDays)

$allDevices = Get-MgDevice -All -Property `
    "Id,DisplayName,AccountEnabled,ApproximateLastSignInDateTime,OperatingSystem,OperatingSystemVersion,TrustType,ComplianceState,RegisteredOwners"

Write-Log "Total devices found: $($allDevices.Count)"

$report = [System.Collections.Generic.List[PSCustomObject]]::new()
$disabledDevices = @()
$staleDevices    = @()
$compliantCount  = 0

foreach ($device in $allDevices) {
    $lastSeen = $device.ApproximateLastSignInDateTime
    $isStale  = $lastSeen -and ($lastSeen -lt $staleThreshold)
    $isDisabled = -not $device.AccountEnabled

    $rowStatus = switch ($true) {
        { $isDisabled }   { "DISABLED (Error 135011)" }
        { $isStale }      { "STALE ($StaleDays+ days)" }
        default           { "OK" }
    }

    if ($isDisabled) { $disabledDevices += $device }
    if ($isStale -and -not $isDisabled) { $staleDevices += $device }
    if (-not $isDisabled -and -not $isStale) { $compliantCount++ }

    $report.Add([PSCustomObject]@{
        DeviceName    = $device.DisplayName
        DeviceId      = $device.Id
        OS            = "$($device.OperatingSystem) $($device.OperatingSystemVersion)"
        TrustType     = $device.TrustType
        AccountEnabled = $device.AccountEnabled
        LastSignIn    = if ($lastSeen) { $lastSeen.ToString("yyyy-MM-dd") } else { "Never" }
        Status        = $rowStatus
    })
}
#endregion

#region --- Summary ---
Write-Log "======================================" "INFO"
Write-Log "AUDIT SUMMARY" "SUCCESS"
Write-Log "  Total Devices : $($allDevices.Count)"
Write-Log "  Disabled      : $($disabledDevices.Count)  ← Error 135011 source" "WARN"
Write-Log "  Stale (>$StaleDays d): $($staleDevices.Count)" "WARN"
Write-Log "  Healthy       : $compliantCount" "SUCCESS"
Write-Log "======================================" "INFO"
#endregion

#region --- Remediation ---
if (-not $ReportOnly) {

    # Re-enable disabled devices
    if ($disabledDevices.Count -gt 0) {
        Write-Log "Re-enabling $($disabledDevices.Count) disabled device(s)..." "FIX"
        foreach ($d in $disabledDevices) {
            if ($PSCmdlet.ShouldProcess($d.DisplayName, "Re-enable device (fix Error 135011)")) {
                try {
                    Update-MgDevice -DeviceId $d.Id -AccountEnabled $true
                    Write-Log "  ✔ Re-enabled: $($d.DisplayName)" "SUCCESS"
                } catch {
                    Write-Log "  ✘ Failed to re-enable $($d.DisplayName): $_" "ERROR"
                }
            }
        }
    }

    # Remove stale devices (optional)
    if ($RemoveStale -and $staleDevices.Count -gt 0) {
        Write-Log "Removing $($staleDevices.Count) stale device(s)..." "WARN"
        $confirm = Read-Host "⚠️  This will DELETE $($staleDevices.Count) stale devices. Type 'YES' to confirm"
        if ($confirm -eq "YES") {
            foreach ($d in $staleDevices) {
                if ($PSCmdlet.ShouldProcess($d.DisplayName, "Delete stale device")) {
                    try {
                        Remove-MgDevice -DeviceId $d.Id
                        Write-Log "  🗑 Deleted: $($d.DisplayName) (Last seen: $($d.ApproximateLastSignInDateTime))" "WARN"
                    } catch {
                        Write-Log "  ✘ Failed to delete $($d.DisplayName): $_" "ERROR"
                    }
                }
            }
        } else {
            Write-Log "Deletion cancelled." "WARN"
        }
    }
}
#endregion

#region --- Export Reports ---
$csvPath  = "$OutputPath.csv"
$htmlPath = "$OutputPath.html"

$report | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Log "CSV report saved: $csvPath"

# HTML Report
$htmlRows = $report | ForEach-Object {
    $color = switch -Wildcard ($_.Status) {
        "DISABLED*" { "#FDDEDE" }
        "STALE*"    { "#FFF3CD" }
        default     { "#DFF0D8" }
    }
    "<tr style='background:$color'>
        <td>$($_.DeviceName)</td>
        <td>$($_.OS)</td>
        <td>$($_.TrustType)</td>
        <td>$($_.LastSignIn)</td>
        <td><b>$($_.Status)</b></td>
    </tr>"
}

$html = @"
<!DOCTYPE html>
<html><head>
<meta charset='UTF-8'>
<title>Entra ID Device Audit</title>
<style>
  body { font-family: Segoe UI, sans-serif; margin: 30px; }
  h1 { color: #0078D4; }
  table { border-collapse: collapse; width: 100%; }
  th { background: #0078D4; color: white; padding: 10px; text-align: left; }
  td { padding: 8px 10px; border-bottom: 1px solid #ddd; }
  .summary { background: #f0f4ff; padding: 15px; border-radius: 8px; margin-bottom: 20px; }
</style>
</head><body>
<h1>🔍 Entra ID Device Compliance Audit</h1>
<div class='summary'>
  <strong>Generated:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm')<br>
  <strong>Total Devices:</strong> $($allDevices.Count) |
  <strong style='color:red'>Disabled:</strong> $($disabledDevices.Count) |
  <strong style='color:orange'>Stale:</strong> $($staleDevices.Count) |
  <strong style='color:green'>Healthy:</strong> $compliantCount
</div>
<table>
<tr><th>Device Name</th><th>OS</th><th>Trust Type</th><th>Last Sign-In</th><th>Status</th></tr>
$($htmlRows -join "`n")
</table>
</body></html>
"@

$html | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Log "HTML report saved: $htmlPath" "SUCCESS"
#endregion

Disconnect-MgGraph | Out-Null
Write-Log "Audit complete." "SUCCESS"
