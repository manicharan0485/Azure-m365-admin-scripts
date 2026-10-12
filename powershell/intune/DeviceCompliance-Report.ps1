#Requires -Modules Microsoft.Graph.DeviceManagement

<#
.SYNOPSIS
    Full Intune device compliance report across all managed endpoints.

.DESCRIPTION
    Exports compliance state, OS version, last sync, and policy details
    for all Intune-managed devices. Highlights non-compliant and 
    unsupported OS versions.

.PARAMETER OutputPath
    Report output path prefix.

.PARAMETER NonCompliantOnly
    Only include non-compliant devices in output.

.EXAMPLE
    .\DeviceCompliance-Report.ps1
    .\DeviceCompliance-Report.ps1 -NonCompliantOnly -OutputPath "C:\Reports\intune"

.NOTES
    Author:  Manicharan Ravi
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    [string]$OutputPath     = ".\intune_compliance_$(Get-Date -Format 'yyyyMMdd_HHmmss')",
    [switch]$NonCompliantOnly
)

Set-StrictMode -Version Latest

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $col = switch ($Level) { "ERROR" {"Red"} "WARN" {"Yellow"} "SUCCESS" {"Green"} default {"Cyan"} }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Msg" -ForegroundColor $col
}

Write-Log "Connecting..."
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All", "DeviceManagementConfiguration.Read.All" -NoWelcome

Write-Log "Fetching managed devices..."
$devices = Get-MgDeviceManagementManagedDevice -All -Property `
    "DeviceName,UserDisplayName,UserPrincipalName,OperatingSystem,OsVersion,ComplianceState,
     LastSyncDateTime,EnrolledDateTime,ManagementAgent,DeviceEnrollmentType,JailBroken,IsEncrypted"

if ($NonCompliantOnly) {
    $devices = $devices | Where-Object { $_.ComplianceState -ne "compliant" }
}

Write-Log "Devices to report: $($devices.Count)"

$report = $devices | ForEach-Object {
    [PSCustomObject]@{
        DeviceName     = $_.DeviceName
        Owner          = $_.UserDisplayName
        UPN            = $_.UserPrincipalName
        OS             = $_.OperatingSystem
        OSVersion      = $_.OsVersion
        ComplianceState = $_.ComplianceState
        LastSync       = if ($_.LastSyncDateTime) { $_.LastSyncDateTime.ToString("yyyy-MM-dd HH:mm") } else { "Never" }
        Enrolled       = if ($_.EnrolledDateTime) { $_.EnrolledDateTime.ToString("yyyy-MM-dd") } else { "" }
        Encrypted      = $_.IsEncrypted
        Jailbroken     = $_.JailBroken
        EnrollType     = $_.DeviceEnrollmentType
    }
}

# Summary
$compliant    = @($report | Where-Object { $_.ComplianceState -eq "compliant" }).Count
$nonCompliant = @($report | Where-Object { $_.ComplianceState -ne "compliant" }).Count

Write-Log "Compliant: $compliant | Non-compliant: $nonCompliant" $(if ($nonCompliant -gt 0) { "WARN" } else { "SUCCESS" })

$report | Export-Csv -Path "$OutputPath.csv" -NoTypeInformation -Encoding UTF8

$rows = $report | ForEach-Object {
    $bg = switch ($_.ComplianceState) {
        "compliant"    { "#dff0d8" }
        "noncompliant" { "#fddede" }
        default        { "#fff3cd" }
    }
    "<tr style='background:$bg'>
      <td>$($_.DeviceName)</td><td>$($_.Owner)</td><td>$($_.OS) $($_.OSVersion)</td>
      <td><b>$($_.ComplianceState)</b></td><td>$($_.LastSync)</td>
      <td>$(if($_.Encrypted){'✅'}else{'❌'})</td>
    </tr>"
}

@"
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>Intune Compliance</title>
<style>body{font-family:Segoe UI,sans-serif;margin:30px}h1{color:#0078D4}
table{border-collapse:collapse;width:100%}th{background:#0078D4;color:white;padding:9px;text-align:left}
td{padding:7px 10px;border-bottom:1px solid #eee}
.stat{display:inline-block;padding:10px 20px;border-radius:6px;margin:5px}</style></head><body>
<h1>📱 Intune Device Compliance Report</h1>
<p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Total devices: $($report.Count)</p>
<div>
  <span class='stat' style='background:#dff0d8'>✅ Compliant: <b>$compliant</b></span>
  <span class='stat' style='background:#fddede'>❌ Non-compliant: <b>$nonCompliant</b></span>
</div><br>
<table><tr><th>Device</th><th>Owner</th><th>OS</th><th>Compliance</th><th>Last Sync</th><th>Encrypted</th></tr>
$($rows -join "`n")</table></body></html>
"@ | Out-File -FilePath "$OutputPath.html" -Encoding UTF8

Write-Log "Reports saved: $OutputPath.csv / .html" "SUCCESS"
Disconnect-MgGraph | Out-Null
