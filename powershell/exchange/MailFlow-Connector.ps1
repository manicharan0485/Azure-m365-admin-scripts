#Requires -Modules ExchangeOnlineManagement

<#
.SYNOPSIS
    Configure Exchange Online mail flow connectors for hybrid/dual mail routing.

.DESCRIPTION
    Sets up outbound connectors to route email through an on-premises or 
    third-party SMTP relay (e.g., Strato, Ionos, OVH) while retaining M365 for 
    inbound and internal mail.

    Use case: Organisations with both an external SMTP provider (e.g., Strato on 
    rzone.de/smtpin.rzone.de) and Microsoft 365 on the same domain need a 
    connector to avoid delivery failures caused by conflicting MX/SPF records.

    Solution: Route outbound via smart host (SMTP relay) using a Send Connector,
    while M365 handles inbound normally.

.PARAMETER SmartHost
    SMTP relay hostname, e.g. smtpin.rzone.de or mail.yourdomain.com

.PARAMETER SmartHostPort
    SMTP relay port. Default: 25

.PARAMETER ConnectorName
    Name for the new Send Connector. Default: "Outbound-SmartHost"

.PARAMETER SenderDomain
    The sender domain to route via smart host. E.g., "rpsonline.de"

.PARAMETER TestMode
    Runs connector validation without creating it.

.EXAMPLE
    # Strato dual-mail scenario (rpsonline.de):
    .\MailFlow-Connector.ps1 -SmartHost "smtpin.rzone.de" -SenderDomain "rpsonline.de"

    # Custom relay:
    .\MailFlow-Connector.ps1 -SmartHost "mail.company.de" -SmartHostPort 587 -SenderDomain "company.de"

.NOTES
    Author:  Manicharan Ravi
    Version: 1.0.0
    
    Troubleshooting dual-mail systems:
    - Symptom: Emails from M365 not delivered, or bounce with "550 5.7.1 SPF"
    - Root cause: SPF record authorises Strato, not M365 IPs
    - Fix Option A: Add M365 to SPF: include:spf.protection.outlook.com
    - Fix Option B: Route outbound via Strato smart host (this script)
    
    References:
    - https://docs.microsoft.com/exchange/mail-flow-best-practices/use-connectors-to-configure-mail-flow
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SmartHost,

    [int]$SmartHostPort     = 25,

    [string]$ConnectorName  = "Outbound-SmartHost",

    [Parameter(Mandatory)]
    [string]$SenderDomain,

    [switch]$TestMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $col = switch ($Level) { "ERROR" {"Red"} "WARN" {"Yellow"} "SUCCESS" {"Green"} default {"Cyan"} }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Msg" -ForegroundColor $col
}

#region --- Connect ---
Write-Log "Connecting to Exchange Online..."
Connect-ExchangeOnline -ShowBanner:$false
#endregion

#region --- Pre-checks ---
Write-Log "Running pre-checks..."

# Check accepted domain
$domain = Get-AcceptedDomain | Where-Object { $_.DomainName -eq $SenderDomain }
if (-not $domain) {
    Write-Log "Domain '$SenderDomain' is NOT an accepted domain in this tenant." "ERROR"
    Write-Log "Add it first: New-AcceptedDomain -Name '$SenderDomain' -DomainName '$SenderDomain'" "WARN"
    exit 1
}
Write-Log "Domain '$SenderDomain' is accepted. Type: $($domain.DomainType)" "SUCCESS"

# Check for existing connector
$existing = Get-OutboundConnector -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $ConnectorName }
if ($existing) {
    Write-Log "Connector '$ConnectorName' already exists. Updating..." "WARN"
}

# Test smart host connectivity
Write-Log "Testing TCP connectivity to $SmartHost`:$SmartHostPort..."
$tcpTest = Test-NetConnection -ComputerName $SmartHost -Port $SmartHostPort -WarningAction SilentlyContinue
if ($tcpTest.TcpTestSucceeded) {
    Write-Log "TCP connection to $SmartHost`:$SmartHostPort — OK" "SUCCESS"
} else {
    Write-Log "Cannot reach $SmartHost`:$SmartHostPort — connector may not work!" "WARN"
}
#endregion

#region --- Create/Update Connector ---
if ($TestMode) {
    Write-Log "TEST MODE: Would create connector with:" "WARN"
    Write-Log "  Name        : $ConnectorName"
    Write-Log "  SmartHost   : $SmartHost`:$SmartHostPort"
    Write-Log "  SenderDomain: $SenderDomain"
    Write-Log "  TLS         : Required (opportunistic)"
} else {
    $connectorParams = @{
        Name                     = $ConnectorName
        ConnectorType            = "OnPremises"
        ConnectorSource          = "Default"
        SmartHosts               = @($SmartHost)
        TlsSettings              = "OpportunisticTls"
        RequireTls               = $false
        UseMXRecord              = $false
        IsTransportRuleScoped    = $true
        Enabled                  = $true
        Comment                  = "Routes outbound mail via $SmartHost for domain $SenderDomain. Created by script on $(Get-Date -Format 'yyyy-MM-dd')."
    }

    if ($PSCmdlet.ShouldProcess($ConnectorName, "Create/Update Send Connector")) {
        if ($existing) {
            Set-OutboundConnector -Identity $ConnectorName @connectorParams
            Write-Log "Connector '$ConnectorName' updated." "SUCCESS"
        } else {
            New-OutboundConnector @connectorParams
            Write-Log "Connector '$ConnectorName' created." "SUCCESS"
        }
    }

    # Create Transport Rule to scope connector to sender domain
    $ruleName = "Route-$SenderDomain-via-SmartHost"
    $existingRule = Get-TransportRule -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $ruleName }

    $ruleParams = @{
        Name                 = $ruleName
        FromScope            = "InOrganization"
        SenderDomainIs       = @($SenderDomain)
        RouteMessageOutboundConnector = $ConnectorName
        Priority             = 0
        Enabled              = $true
        Comments             = "Routes outbound from $SenderDomain through $ConnectorName"
    }

    if ($PSCmdlet.ShouldProcess($ruleName, "Create/Update Transport Rule")) {
        if ($existingRule) {
            Set-TransportRule -Identity $ruleName @ruleParams
            Write-Log "Transport rule '$ruleName' updated." "SUCCESS"
        } else {
            New-TransportRule @ruleParams
            Write-Log "Transport rule '$ruleName' created." "SUCCESS"
        }
    }
}
#endregion

#region --- Verify ---
Write-Log "Verifying configuration..."

$connector = Get-OutboundConnector | Where-Object { $_.Name -eq $ConnectorName }
if ($connector) {
    Write-Log "Connector status: $($connector.Enabled)" "SUCCESS"
    Write-Log "Smart hosts    : $($connector.SmartHosts -join ', ')"
    Write-Log "TLS setting    : $($connector.TlsSettings)"
}

Write-Log ""
Write-Log "=== NEXT STEPS ===" "SUCCESS"
Write-Log "1. Verify SPF record for $SenderDomain includes M365 OR rely on connector routing"
Write-Log "   SPF fix: v=spf1 include:spf.protection.outlook.com include:spf.rzone.de ~all"
Write-Log "2. Test mail flow: Send-MailMessage or use M365 Mail Flow trace"
Write-Log "3. Monitor: Exchange Admin Center > Mail flow > Message trace"
Write-Log "4. Run: Test-OutboundConnector -Identity '$ConnectorName' -To 'test@$SenderDomain'" "WARN"
#endregion

Disconnect-ExchangeOnline -Confirm:$false
Write-Log "Done." "SUCCESS"
