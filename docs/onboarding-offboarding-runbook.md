# Runbook: Onboarding & Offboarding SOP

Standard operating procedure for the Entra ID user lifecycle. Adjust group
names, SKUs, and retention windows to match your tenant.

---

## A. Onboarding

**Trigger:** HR new-hire notice (start date, department, job title, manager).

1. **Verify the request.** Confirm identity, legal name spelling, start date,
   department, job title, and manager from the HR ticket. No ticket, no
   account.
2. **Prepare the CSV row** (see `templates/new-users.csv.example`): UPN
   `firstname.lastname@contoso.example`, usage location (required for
   licensing, e.g. `US`), department, job title, manager UPN.
3. **Dry-run the creation script.**
   `.\scripts\New-UserFromCsv.ps1 -CsvPath .\new-users.csv -WhatIf`
   Review every "What if" line: UPN, display name, group assignment.
4. **Create the account** (remove `-WhatIf`). The script sets
   `ForceChangePasswordNextSignIn` so the temp password is single-use.
5. **Confirm license assignment.** Check the user shows the expected SKU
   (inherited via the department group's group-based licensing).
   *Verify:* `Get-MgUserLicenseDetail -UserId <upn>` returns the SKU.
6. **Add role groups** per job title (e.g. `role-finance-approvers`): these
   are separate from the department group the script assigned.
   *Verify:* `Get-MgUserMemberOf -UserId <upn>` lists dept + role groups.
7. **Start the MFA registration window.** Issue a Temporary Access Pass for
   first sign-in; the CA policy requires MFA registration within 14 days.
8. **Device assignment.** Enroll the assigned device in Intune (Autopilot
   where available) and record asset tag → user in the asset tracker.
9. **Send the welcome email** to the manager (never the temp password by
   email: hand it off through the approved channel) with sign-in
   instructions and the MFA setup link.
10. **Close-out verification (before closing the ticket):**
    - User can sign in (sign-in log shows a successful interactive sign-in).
    - License assigned, groups correct.
    - MFA shows as registered in the registration report.

---

## B. Offboarding

**Trigger:** HR termination notice or manager request. Treat as
time-sensitive: start within the hour for involuntary departures.

1. **Disable sign-in immediately.**
   `Update-MgUser -UserId <upn> -AccountEnabled:$false`
   *Verify:* `Get-MgUser -UserId <upn>` shows `AccountEnabled = False`.
2. **Revoke all sessions and refresh tokens.**
   `Revoke-MgUserSignInSession -UserId <user-id>`
   *Verify:* subsequent sign-in attempts appear as blocked in the sign-in log.
   (This is the step people skip. A disabled account's existing sessions
   stay alive until tokens expire.)
3. **Remove group memberships.** Remove from all department, role, and M365
   groups. With group-based licensing, this also releases the license.
   *Verify:* `Get-MgUserMemberOf` returns empty (or only expected leftovers).
4. **Confirm license removal.**
   *Verify:* `Get-MgUserLicenseDetail -UserId <upn>` returns nothing.
5. **Convert the mailbox to shared** (Exchange Online module required:
   see the placeholder section in `Invoke-UserOffboarding.ps1`):
   set mailbox type to Shared, grant the manager FullAccess, set an
   auto-reply ("X is no longer with the company; contact Y").
6. **Transfer OneDrive / files.** Assign the manager as site collection admin
   of the user's OneDrive; move business-critical files per manager direction.
   Note the retention policy clock (default 30 days after deletion, 93 with
   retention policy: set yours and write it here).
7. **Handle the device.** Intune: retire or wipe per policy; remove Autopilot
   registration if the device is reassigned. Record return in the asset tracker.
8. **Log it.** Append to the offboarding log: date, admin, UPN, actions taken,
   mailbox/OneDrive disposition, retention deadline. The script writes this
   automatically: attach its log to the ticket.
9. **Retention, then delete.** After the retention window (default: 90
   days post-departure, then the 30-day Entra soft-delete), hard-delete the
   account. Do not hard-delete early: soft-delete is your undo button.
10. **Post-offboarding audit (next day):**
    - Sign-in log shows no successful sign-ins after the disable timestamp.
    - MFA report no longer lists the user as active.
    - Mailbox auto-reply is live (send a test message).

---

## Scripted path

For steps 1–4 and 8 of offboarding, use:

```powershell
# Always dry-run first
.\scripts\Invoke-UserOffboarding.ps1 -UserPrincipalName "jane.doe@contoso.example" -WhatIf

# Real run - ConfirmImpact=High prompts before each destructive action
.\scripts\Invoke-UserOffboarding.ps1 -UserPrincipalName "jane.doe@contoso.example"
```

Steps 5–7 (Exchange/OneDrive/Intune) need their respective modules and are
called out as commented placeholders in the script: run them from an
Exchange-connected session.
