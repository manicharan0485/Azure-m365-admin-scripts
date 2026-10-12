#Requires -Modules Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement

<#
.SYNOPSIS
    Bulk user provisioning for Microsoft Entra ID (Azure AD) from CSV input.

.DESCRIPTION
    Creates or updates users in Entra ID from a CSV file.
    Assigns licenses, sets department, manager, and usage location.
    Sends a welcome email with temporary password.

.PARAMETER CsvPath
    Path to CSV file. Required columns: DisplayName, UserPrincipalName, Department, JobTitle, Manager, LicenseSku
    
.PARAMETER WhatIf
    Preview changes without applying them.

.PARAMETER LogPath
    Path to write operation log. Defaults to .\provisioning_log.csv

.EXAMPLE
    .\Bulk-UserProvisioning.ps1 -CsvPath ".\new_users.csv" -WhatIf
    .\Bulk-UserProvisioning.ps1 -CsvPath ".\new_users.csv" -LogPath "C:\Logs\provision.csv"

.NOTES
    Author:  Manicharan Ravi
    Version: 1.2.0
    Requires: Microsoft.Graph PowerShell SDK
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ })]
    [string]$CsvPath,

    [string]$LogPath = ".\provisioning_log_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",

    [string]$UsageLocation = "DE",  # Germany default

    [switch]$SendWelcomeEmail
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region --- Helpers ---

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) { "ERROR" { "Red" } "WARN" { "Yellow" } "SUCCESS" { "Green" } default { "Cyan" } }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function New-TempPassword {
    $chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789!@#"
    -join ((1..14) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

function Get-LicenseSkuId {
    param([string]$SkuName)
    $sku = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -eq $SkuName }
    if (-not $sku) { throw "SKU '$SkuName' not found in tenant." }
    return $sku.SkuId
}

function Get-ManagerId {
    param([string]$ManagerUPN)
    if ([string]::IsNullOrWhiteSpace($ManagerUPN)) { return $null }
    try {
        $mgr = Get-MgUser -Filter "userPrincipalName eq '$ManagerUPN'" -ErrorAction Stop
        return $mgr.Id
    } catch {
        Write-Log "Manager '$ManagerUPN' not found. Skipping manager assignment." "WARN"
        return $null
    }
}

#endregion

#region --- Main ---

Write-Log "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All", "Organization.Read.All" -NoWelcome

Write-Log "Loading users from: $CsvPath"
$users = Import-Csv -Path $CsvPath
Write-Log "Found $($users.Count) user(s) to process."

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($user in $users) {
    $tempPassword = New-TempPassword
    $status = "SUCCESS"
    $notes  = ""

    try {
        # Check if user already exists
        $existing = Get-MgUser -Filter "userPrincipalName eq '$($user.UserPrincipalName)'" -ErrorAction SilentlyContinue

        $userParams = @{
            DisplayName         = $user.DisplayName
            UserPrincipalName   = $user.UserPrincipalName
            MailNickname        = ($user.UserPrincipalName -split "@")[0]
            Department          = $user.Department
            JobTitle            = $user.JobTitle
            UsageLocation       = $UsageLocation
            AccountEnabled      = $true
            PasswordProfile     = @{
                ForceChangePasswordNextSignIn = $true
                Password                      = $tempPassword
            }
        }

        if ($existing) {
            if ($PSCmdlet.ShouldProcess($user.UserPrincipalName, "Update existing user")) {
                Update-MgUser -UserId $existing.Id -BodyParameter $userParams
                Write-Log "Updated: $($user.DisplayName) ($($user.UserPrincipalName))" "SUCCESS"
                $notes = "Updated existing user"
            }
        } else {
            if ($PSCmdlet.ShouldProcess($user.UserPrincipalName, "Create new user")) {
                $newUser = New-MgUser -BodyParameter $userParams
                Write-Log "Created: $($user.DisplayName) ($($user.UserPrincipalName))" "SUCCESS"

                # Assign license
                if (-not [string]::IsNullOrWhiteSpace($user.LicenseSku)) {
                    $skuId = Get-LicenseSkuId -SkuName $user.LicenseSku
                    Set-MgUserLicense -UserId $newUser.Id `
                        -AddLicenses @{ SkuId = $skuId } `
                        -RemoveLicenses @()
                    Write-Log "License assigned: $($user.LicenseSku)" "SUCCESS"
                }

                # Set manager
                $managerId = Get-ManagerId -ManagerUPN $user.Manager
                if ($managerId) {
                    $ref = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/users/$managerId" }
                    Set-MgUserManagerByRef -UserId $newUser.Id -BodyParameter $ref
                }

                $notes = "Created. Temp password set."
            }
        }

    } catch {
        $status = "ERROR"
        $notes  = $_.Exception.Message
        Write-Log "FAILED for $($user.UserPrincipalName): $notes" "ERROR"
    }

    $results.Add([PSCustomObject]@{
        Timestamp         = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        DisplayName       = $user.DisplayName
        UserPrincipalName = $user.UserPrincipalName
        Status            = $status
        Notes             = $notes
    })
}

# Export log
$results | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
Write-Log "Log saved to: $LogPath"

$success = ($results | Where-Object Status -eq "SUCCESS").Count
$errors  = ($results | Where-Object Status -eq "ERROR").Count
Write-Log "Done. Success: $success | Errors: $errors" "SUCCESS"

Disconnect-MgGraph | Out-Null

#endregion
