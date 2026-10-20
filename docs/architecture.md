# Architecture & Design Decisions — Entra ID Lifecycle Lab

## Tenant structure

### Identity model: Joiner / Mover / Leaver

Every account follows the same lifecycle: **create → provision access →
review periodically → disable → retain → delete**. The scripts and runbook in
this repo implement that loop. One naming convention everywhere:
`firstname.lastname@contoso.example` (UPN and primary SMTP match).

### Groups model

- **Department security groups** (`sec-dept-sales`, `sec-dept-ops`,
  `sec-dept-it`): assigned access to department resources (SharePoint sites,
  file shares, SaaS SSO apps). Static membership, managed by IT at
  onboarding/offboarding.
- **Role groups** (`role-finance-approvers`, `role-helpdesk-agents`):
  function-based access that crosses departments. Users get role groups from
  their job title, independent of department.
- **Dynamic groups** (`dyn-all-employees`): rule-based membership on the
  `department` attribute, e.g.
  `(user.department -eq "Sales")`. No human touches membership — it follows
  the attribute, so movers are re-scoped automatically when HR data updates
  the attribute. Requires Entra ID P1 or P2.
- **M365 groups (Teams)** for collaboration are joined separately and are
  **not** used for access control — access rides on security groups only, so
  removing someone from a team never silently leaves resource access behind.

## Group-based licensing

Licenses (M365 Business Premium SKU in the lab) are assigned **to groups,
not to users**. `sec-dept-*` groups carry the license assignment, so a new
user gets a license the moment the onboarding script drops them into their
department group — and loses it the moment offboarding removes them.

Why: assigning licenses per-user means every disable/delete has to remember
license cleanup. Group-based licensing makes license state a pure function of
group membership — one removal, everything downstream follows. Note the known
edge: a user with services already provisioned (mailbox created) keeps the
mailbox after the license is removed; the runbook converts it to shared so
data is retained without a license.

## Least-privilege admin roles

- **Global Administrator**: reserved for the two break-glass accounts. Never
  used day-to-day.
- **User Administrator**: creates/deletes users, resets passwords, manages
  group memberships. The onboarding/offboarding operator role.
- **Helpdesk Administrator**: password resets + license assignment for
  day-to-day support tickets. Narrower than User Admin.
- **Authentication Administrator**: can require re-registration of MFA —
  the role you hand the helpdesk for "user lost their phone" tickets without
  giving them user-delete power.
- **Privileged Identity Management (PIM)** (Entra ID P2): any elevated role
  is eligible, not permanent — time-boxed activation with approval and audit.

Why: the joiner/leaver scripts only need User Admin + Group scopes consented.
Running them as Global Admin works but violates least privilege and turns a
script bug into a tenant-wide incident.

## MFA strategy

### Security Defaults vs Conditional Access

| | Security Defaults | Conditional Access |
|---|---|---|
| Granularity | Tenant-wide on/off | Per-user, per-group, per-app, per-risk |
| Exclusions | None (break-glass too) | Break-glass + service accounts excluded |
| Requirements | Free, any SKU | Entra ID P1+ |
| Control | Microsoft-managed baseline | Full policy design (location, device, risk) |

**Lab decision: Conditional Access.** The lab assumes Entra ID P1 (via the
M365 Business Premium license), which unlocks CA. One policy requires MFA for
all users, all cloud apps, with the two break-glass accounts excluded; a
second policy blocks legacy authentication outright.

Why CA over Security Defaults: Security Defaults is the right call for a
<300-seat org without P1 — free, no thinking required. But it can't exclude
break-glass accounts (a lockout risk), can't scope per app, and can't do
risk-based policies. Since the lab tenant carries P1, CA gives the control
needed for exclusions and for an MFA registration campaign that targets
"registered but not enforced" users separately from "never registered".

### Registration enforcement

Users must register MFA within **14 days of first sign-in** (temporary access
pass for the bootstrap, per-user). The `Get-MfaStatusReport.ps1` script reads
the authentication-methods registration report so IT can chase the
"never registered" list before the deadline instead of discovering it during
an incident.

## Break-glass accounts

- Two cloud-only Global Admins (`breakglass01`, `breakglass02`), names that
  don't match any naming pattern an attacker would guess.
- Excluded from all Conditional Access policies (otherwise a CA misconfig can
  lock out every admin — the exact scenario they exist to survive).
- Authentication: long generated passphrase + FIDO2 security key. No phone
  number, no authenticator app that can be SIM-swapped.
- Credentials stored sealed, split knowledge; **any sign-in by either account
  triggers an alert** (sign-in log → alert rule), because legitimate use is
  near-zero.

## Hardening notes

- Account disable (`accountEnabled=false`) is **not** session termination —
  the offboarding script always pairs it with `Revoke-MgUserSignInSession`
  (kills refresh tokens) because an active session survives a disable for up
  to an hour otherwise.
- Deleted users sit in soft-delete for 30 days (recoverable); hard delete
  only after the retention window in the runbook.
- All scripts write timestamped logs; offboarding is the destructive path, so
  it logs the UPN, the admin who ran it, and every action taken — the audit
  trail you show when someone asks "who removed their access and when".
- `-WhatIf` is not optional culture: the runbook requires a dry run before
  any bulk operation, and the offboarding script's `ConfirmImpact=High`
  forces an explicit yes even without `-WhatIf`.
