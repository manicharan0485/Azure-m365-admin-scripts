#!/usr/bin/env python3
"""
m365_compliance_report.py
─────────────────────────────────────────────────────────────────────────────
Generates an HTML compliance report for Microsoft 365 via Graph API.

Covers:
  - MFA enrollment status (per user)
  - Conditional Access policy summary
  - Risky users (Identity Protection)
  - Devices with failed Intune compliance
  - Recent failed sign-ins (audit log)

Requirements:
    pip install msal requests pandas jinja2

Auth:
    Uses client credentials (app registration) — no user interaction needed.
    Register an app in Entra ID with:
      - User.Read.All
      - AuditLog.Read.All
      - IdentityRiskyUser.Read.All
      - Policy.Read.All
      - DeviceManagementManagedDevices.Read.All

Usage:
    python m365_compliance_report.py --tenant <TENANT_ID> --client <CLIENT_ID> --secret <CLIENT_SECRET>
    python m365_compliance_report.py --tenant <TENANT_ID> --client <CLIENT_ID> --secret <CLIENT_SECRET> --output ./reports

Author:  Manicharan Ravi
Version: 1.0.0
"""

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import msal
import requests
import pandas as pd


GRAPH_BASE = "https://graph.microsoft.com/v1.0"
GRAPH_BETA = "https://graph.microsoft.com/beta"


# ─────────────────────────────────────────────────────────────────
# Auth
# ─────────────────────────────────────────────────────────────────

def get_token(tenant_id: str, client_id: str, client_secret: str) -> str:
    app = msal.ConfidentialClientApplication(
        client_id,
        authority=f"https://login.microsoftonline.com/{tenant_id}",
        client_credential=client_secret,
    )
    result = app.acquire_token_for_client(scopes=["https://graph.microsoft.com/.default"])
    if "access_token" not in result:
        raise RuntimeError(f"Token error: {result.get('error_description', result)}")
    return result["access_token"]


def graph_get(url: str, token: str, beta: bool = False) -> list:
    """Paginated Graph API GET — returns all items."""
    headers = {"Authorization": f"Bearer {token}", "ConsistencyLevel": "eventual"}
    items = []
    while url:
        r = requests.get(url, headers=headers, timeout=30)
        r.raise_for_status()
        data = r.json()
        items.extend(data.get("value", [data]))
        url = data.get("@odata.nextLink")
    return items


# ─────────────────────────────────────────────────────────────────
# Data Collectors
# ─────────────────────────────────────────────────────────────────

def get_mfa_status(token: str) -> list:
    """Get MFA registration status for all users."""
    url = f"{GRAPH_BETA}/reports/credentialUserRegistrationDetails"
    rows = graph_get(url, token)
    return [
        {
            "User": r.get("userDisplayName"),
            "UPN": r.get("userPrincipalName"),
            "MFA Registered": r.get("isMfaRegistered"),
            "Passwordless": r.get("isPasswordlessCapable"),
            "Methods": ", ".join(r.get("authMethods", [])),
        }
        for r in rows
    ]


def get_risky_users(token: str) -> list:
    """Get users flagged by Identity Protection."""
    url = f"{GRAPH_BASE}/identityProtection/riskyUsers?$filter=riskLevel ne 'none'"
    rows = graph_get(url, token)
    return [
        {
            "User": r.get("userDisplayName"),
            "UPN": r.get("userPrincipalName"),
            "Risk Level": r.get("riskLevel"),
            "Risk State": r.get("riskState"),
            "Risk Detail": r.get("riskDetail"),
            "Risk Last Updated": r.get("riskLastUpdatedDateTime", "")[:10],
        }
        for r in rows
    ]


def get_non_compliant_devices(token: str) -> list:
    """Get Intune managed devices that are non-compliant."""
    url = f"{GRAPH_BASE}/deviceManagement/managedDevices?$filter=complianceState eq 'noncompliant'"
    rows = graph_get(url, token)
    return [
        {
            "Device": r.get("deviceName"),
            "Owner": r.get("userDisplayName"),
            "OS": f"{r.get('operatingSystem')} {r.get('osVersion')}",
            "Enrolled": r.get("enrolledDateTime", "")[:10],
            "Last Sync": r.get("lastSyncDateTime", "")[:10],
            "Compliance State": r.get("complianceState"),
        }
        for r in rows
    ]


def get_failed_signins(token: str, hours: int = 24) -> list:
    """Get failed sign-ins in the last N hours."""
    since = (datetime.now(timezone.utc) - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    url = (
        f"{GRAPH_BETA}/auditLogs/signIns"
        f"?$filter=status/errorCode ne 0 and createdDateTime ge {since}"
        f"&$top=50&$orderby=createdDateTime desc"
    )
    rows = graph_get(url, token)
    return [
        {
            "User": r.get("userDisplayName"),
            "UPN": r.get("userPrincipalName"),
            "App": r.get("appDisplayName"),
            "Error Code": r.get("status", {}).get("errorCode"),
            "Failure Reason": r.get("status", {}).get("failureReason"),
            "IP Address": r.get("ipAddress"),
            "Location": f"{r.get('location', {}).get('city', '')}, {r.get('location', {}).get('countryOrRegion', '')}",
            "Timestamp": r.get("createdDateTime", "")[:16].replace("T", " "),
        }
        for r in rows
    ]


def get_ca_policies(token: str) -> list:
    """List Conditional Access policies and their state."""
    url = f"{GRAPH_BASE}/identity/conditionalAccess/policies"
    rows = graph_get(url, token)
    return [
        {
            "Policy Name": r.get("displayName"),
            "State": r.get("state"),
            "Created": r.get("createdDateTime", "")[:10],
            "Modified": r.get("modifiedDateTime", "")[:10],
        }
        for r in rows
    ]


# ─────────────────────────────────────────────────────────────────
# HTML Report Generator
# ─────────────────────────────────────────────────────────────────

def df_to_html(df: pd.DataFrame, highlight_col: str = None, bad_val=None) -> str:
    if df.empty:
        return "<p style='color:green'>✅ No issues found.</p>"

    def highlight_row(row):
        if highlight_col and highlight_col in row.index:
            if row[highlight_col] == bad_val or (bad_val is None and not row[highlight_col]):
                return ["background-color: #fddede"] * len(row)
        return [""] * len(row)

    styled = df.style.apply(highlight_row, axis=1)
    return styled.to_html(index=False, border=0, classes="report-table")


def build_report(data: dict, output_path: Path) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M")

    sections = ""
    for title, (df, col, bad) in data.items():
        icon = "🔴" if (not df.empty and col) else "✅"
        count = len(df)
        sections += f"""
        <section>
          <h2>{icon} {title} <span class='badge'>{count}</span></h2>
          {df_to_html(df, col, bad)}
        </section>"""

    html = f"""<!DOCTYPE html>
<html lang='en'><head><meta charset='UTF-8'>
<title>M365 Compliance Report</title>
<style>
  body{{font-family:Segoe UI,sans-serif;margin:0;padding:0;background:#f0f2f5;color:#333}}
  header{{background:#0078D4;color:white;padding:24px 40px}}
  header h1{{margin:0;font-size:1.8em}}
  header p{{margin:4px 0 0;opacity:.85}}
  main{{padding:30px 40px}}
  section{{background:white;border-radius:8px;padding:24px;margin-bottom:24px;box-shadow:0 1px 4px rgba(0,0,0,.1)}}
  h2{{color:#0078D4;margin-top:0;font-size:1.2em}}
  .badge{{background:#0078D4;color:white;border-radius:12px;padding:2px 10px;font-size:.8em;margin-left:8px}}
  .report-table{{border-collapse:collapse;width:100%;font-size:.9em}}
  .report-table th{{background:#0078D4;color:white;padding:9px 12px;text-align:left}}
  .report-table td{{padding:7px 12px;border-bottom:1px solid #eee}}
  .report-table tr:hover td{{background:#f5f9ff}}
</style>
</head><body>
<header>
  <h1>🔐 Microsoft 365 Compliance Report</h1>
  <p>Generated: {ts}</p>
</header>
<main>{sections}</main>
</body></html>"""

    out_file = output_path / f"m365_compliance_{datetime.now().strftime('%Y%m%d_%H%M%S')}.html"
    out_file.write_text(html, encoding="utf-8")
    print(f"✅ Report saved: {out_file}")


# ─────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="M365 Compliance Report Generator")
    parser.add_argument("--tenant", required=True, help="Entra ID Tenant ID")
    parser.add_argument("--client", required=True, help="App Registration Client ID")
    parser.add_argument("--secret", required=True, help="Client Secret")
    parser.add_argument("--output", default=".", help="Output directory")
    parser.add_argument("--hours", type=int, default=24, help="Hours back for sign-in failures")
    args = parser.parse_args()

    output_path = Path(args.output)
    output_path.mkdir(parents=True, exist_ok=True)

    print("🔑 Authenticating...")
    token = get_token(args.tenant, args.client, args.secret)
    print("✅ Token acquired.")

    print("📊 Collecting data...")

    data_sections = {
        "MFA Registration Status":          (pd.DataFrame(get_mfa_status(token)),           "MFA Registered", False),
        "Risky Users (Identity Protection)": (pd.DataFrame(get_risky_users(token)),          None,             None),
        "Non-Compliant Intune Devices":      (pd.DataFrame(get_non_compliant_devices(token)), None,            None),
        f"Failed Sign-Ins (last {args.hours}h)": (pd.DataFrame(get_failed_signins(token, args.hours)), None,  None),
        "Conditional Access Policies":       (pd.DataFrame(get_ca_policies(token)),           "State",         "disabled"),
    }

    build_report(data_sections, output_path)


if __name__ == "__main__":
    main()
