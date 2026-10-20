# Entra ID Lifecycle Lab — User Onboarding / Offboarding Automation


> **Note on sources:** This lab recreates a deployment I administered in a professional role. Company names, hostnames, IP addresses, keys, and tenant identifiers have been sanitized or replaced with placeholders for confidentiality.

A production-style identity-lifecycle build, mirroring a real Microsoft 365
tenant administration setup: Entra ID user lifecycle, department security
groups, group-based licensing, MFA enforcement reporting, and a scripted
joiner/mover/leaver process with PowerShell + Microsoft Graph.

**What this demonstrates:** Entra ID user lifecycle (create/disable/revoke/
delete), department + role security groups and dynamic membership rules,
group-based license assignment, least-privilege admin roles, MFA strategy
(Security Defaults vs Conditional Access), break-glass accounts, and a
safe, `-WhatIf`-first PowerShell automation pattern for onboarding and
offboarding.

```
                ┌──────────────────────────┐
                │    ADMIN WORKSTATION     │
                │  PowerShell + Microsoft  │
                │       Graph SDK          │
                └─────────────┬────────────┘
                              │ Connect-MgGraph
                              ▼
        ┌──────────────────────────────────────────┐
        │           ENTRA ID TENANT                │
        │  ┌──────────┐  ┌────────────────────┐    │
        │  │  Users   │  │ Department / role  │    │
        │  │ lifecycle│  │ security groups    │    │
        │  │ create → │  │ (incl. dynamic     │    │
        │  │ disable→ │  │  membership rules) │    │
        │  │ delete   │  └─────────┬──────────┘    │
        │  └──────────┘            │ group-based   │
        │                          ▼ licensing    │
        │                 ┌─────────────────┐      │
        │                 │ Licenses (M365) │      │
        │                 └─────────────────┘      │
        │  ┌──────────────────────────────────┐   │
        │  │ MFA: Security Defaults /         │   │
        │  │ Conditional Access policies      │   │
        │  └──────────────────────────────────┘   │
        │  ┌──────────────────────────────────┐   │
        │  │ Break-glass Global Admin x2      │   │
        │  │ (excluded from CA, monitored)    │   │
        │  └──────────────────────────────────┘   │
        └──────────────────────────────────────────┘
                              │ offboarding
                              ▼
                ┌──────────────────────────┐
                │     EXCHANGE ONLINE      │
                │  mailbox → shared type,  │
                │  auto-reply, OneDrive    │
                │  ownership transfer      │
                └──────────────────────────┘
```

## Repo layout

| Path | Purpose |
|---|---|
| `scripts/New-UserFromCsv.ps1` | Bulk user creation from CSV: New-MgUser, usage location, department group assignment |
| `scripts/Invoke-UserOffboarding.ps1` | Offboarding: disable sign-in, revoke sessions, remove groups/licenses, log everything |
| `scripts/Get-MfaStatusReport.ps1` | Per-user MFA registration report → CSV for audit |
| `templates/new-users.csv.example` | CSV template for bulk onboarding (placeholder data only) |
| `docs/architecture.md` | Tenant structure: groups model, licensing, admin roles, MFA strategy, break-glass |
| `docs/onboarding-offboarding-runbook.md` | Step-by-step SOP runbook with verification steps |
| `docs/interview-answers.md` | "How did you do this?" — talking points for interviews |
| `.gitignore` | Keeps real CSVs, logs, and local config out of the repo |

## Quick start

These scripts run on a **Windows admin host with the Microsoft.Graph
PowerShell SDK** against a real tenant. Connect first, then run:

```powershell
# One-time: install the Graph SDK modules
Install-Module Microsoft.Graph -Scope CurrentUser

# Connect (consent the scopes on first run)
Connect-MgGraph -Scopes "User.ReadWrite.All","GroupMember.ReadWrite.All" -NoWelcome

# 1. Bulk onboarding — dry run first, always
.\scripts\New-UserFromCsv.ps1 -CsvPath .\templates\new-users.csv.example -WhatIf

# 2. Offboarding — confirm prompt is built in (ConfirmImpact = High)
.\scripts\Invoke-UserOffboarding.ps1 -UserPrincipalName "jane.doe@contoso.example" -WhatIf

# 3. MFA registration audit
.\scripts\Get-MfaStatusReport.ps1 -OutputPath .\mfa-report.csv
```

Script comment headers list the exact scopes and prerequisites for each one.

## Security notes

- **No secrets in this repo**: placeholders only (`contoso.example`,
  `<tenant-id>`). Real CSVs and logs are git-ignored.
- Both lifecycle scripts support `-WhatIf` (dry run) and `-Confirm`;
  offboarding uses `ConfirmImpact = "High"` so it always asks first.
- Offboarding revokes refresh tokens (`Revoke-MgUserSignInSession`) **and**
  blocks sign-in — disabling alone leaves existing sessions alive.
- Break-glass accounts are excluded from Conditional Access on purpose,
  protected instead by long passphrases, FIDO2 keys, and alerting on use.

## Validation

- All three `.ps1` files: **parsed with the PowerShell 7.4.6 parser —
  zero syntax errors.** `pwsh` was installed in this sandbox (Linux) purely
  as a parser; it cannot reach any tenant from here.
- `PSScriptAnalyzer` run against all scripts: results noted in the validation
  log below (style warnings only, no errors).
- **Graph cmdlets were NOT executed** — they require a real Entra ID tenant,
  the Microsoft.Graph SDK, and consented permissions. Nothing here was tested
  against a live tenant.
- The runbook steps follow documented Microsoft Entra behavior
  (account disable, session revoke, license removal, mailbox conversion via
  Exchange Online); adapt SKU/group names to your tenant before running.

### PSScriptAnalyzer results (2026-10-19, PSScriptAnalyzer 1.25.0)

- `New-UserFromCsv.ps1`: 0 errors, 0 warnings.
- `Invoke-UserOffboarding.ps1`: 0 errors, 0 warnings.
- `Get-MfaStatusReport.ps1`: 0 errors, 0 warnings.
