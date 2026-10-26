<#
.SYNOPSIS
    Creates Entra ID users in bulk from a CSV and assigns each to their
    department security group.

.DESCRIPTION
    Reads a CSV (see templates/new-users.csv.example for the format) and for
    each row:

      1. Creates the user with New-MgUser (skip if the UPN already exists),
         with a cryptographically random 16-character temporary password
         (one of each character category guaranteed; Entra complexity-safe)
         and ForceChangePasswordNextSignIn.
      2. Sets the usage location (licenses will not assign without it).
      3. Adds the user to the department security group that maps to the
         CSV's Department column.

    Licenses come from group-based licensing: the department group carries
    the license assignment, so there is no per-user license step here.

    One-time passwords are written once to a timestamped CSV under
    .\credentials\ (git-ignored, never printed to the console) - distribute,
    then delete. See the TAP note at the bottom of this script for the
    passwordless alternative.

    Supports -WhatIf / -Confirm. Always dry-run a bulk import first.

.PREREQUISITES
    - Windows admin host with the Microsoft Graph PowerShell SDK.
    - Connect first:

        Install-Module Microsoft.Graph -Scope CurrentUser
        Connect-MgGraph -Scopes "User.ReadWrite.All","GroupMember.ReadWrite.All" -NoWelcome

    - Replace the group IDs in $DepartmentGroupMap below with your tenant's
      object IDs (Get-MgGroup -Filter "displayName eq 'sec-dept-sales'").

.EXAMPLE
    .\New-UserFromCsv.ps1 -CsvPath .\templates\new-users.csv.example -WhatIf

.EXAMPLE
    .\New-UserFromCsv.ps1 -CsvPath .\new-users.csv -Domain "contoso.example"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [string]$Domain = "contoso.example"
)

#Requires -Modules Microsoft.Graph.Users, Microsoft.Graph.Groups

# Department name (CSV column) -> Entra security group object ID.
# PLACEHOLDERS: replace with real group IDs in your tenant.
$DepartmentGroupMap = @{
    "Sales"      = "<group-id-sec-dept-sales>"
    "Operations" = "<group-id-sec-dept-ops>"
    "IT"         = "<group-id-sec-dept-it>"
}

function Get-TemporaryPassword {
    <#
    Generates a 16-character temporary password that always satisfies Entra ID
    complexity (at least 3 of 4 character categories). It guarantees at least
    one character from EACH of the four categories (lowercase, uppercase,
    digit, symbol), fills the rest from the combined pool, and shuffles - 
    all with a cryptographic RNG
    (System.Security.Cryptography.RandomNumberGenerator), never Get-Random.

    The account is created with ForceChangePasswordNextSignIn, so this value
    is single-use. Generated passwords are collected by the main loop and
    written ONCE to a timestamped CSV under .\credentials\ (see below) - 
    treat that file as sensitive: distribute, then delete it. The modern
    alternative is a Temporary Access Pass
    (New-MgUserAuthenticationTemporaryAccessPassMethod), which avoids
    handling passwords entirely - see the note at the bottom of this script.
    #>
    $lower   = "abcdefghijkmnpqrstuvwxyz".ToCharArray()
    $upper   = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".ToCharArray()
    $digits  = "23456789".ToCharArray()
    $symbols = "!@#$%^&*()-_=+[]{}".ToCharArray()
    $all     = $lower + $upper + $digits + $symbols

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $pick = {
            param($pool)
            $bytes = [byte[]]::new(4)
            $rng.GetBytes($bytes)
            return $pool[[BitConverter]::ToUInt32($bytes, 0) % $pool.Count]
        }

        # Guarantee one of each category, then fill to 16...
        $chars = @((& $pick $lower), (& $pick $upper), (& $pick $digits), (& $pick $symbols))
        1..12 | ForEach-Object { $chars += (& $pick $all) }

        # ...and Fisher-Yates shuffle so the category positions are random.
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $bytes = [byte[]]::new(4)
            $rng.GetBytes($bytes)
            $j = [BitConverter]::ToUInt32($bytes, 0) % ($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        return -join $chars
    }
    finally {
        $rng.Dispose()
    }
}

if (-not (Test-Path -Path $CsvPath)) {
    throw "CSV file not found: $CsvPath"
}

$rows = Import-Csv -Path $CsvPath
$results = @()
$credentials = @()

foreach ($row in $rows) {
    $upn = $row.UserPrincipalName
    $displayName = $row.DisplayName
    $status = "Created"

    # Sanity check: UPNs must live in the tenant's primary domain.
    if ($upn -notlike "*@$Domain") {
        Write-Warning "Skipping $upn -- UPN is not in domain '$Domain'."
        $results += [PSCustomObject]@{ UserPrincipalName = $upn; Status = "Skipped (wrong domain)" }
        continue
    }

    # Skip users that already exist -- idempotent re-runs are safe.
    $existing = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Write-Warning "Skipping $upn -- account already exists."
        $results += [PSCustomObject]@{ UserPrincipalName = $upn; Status = "Skipped (exists)" }
        continue
    }

    if ($PSCmdlet.ShouldProcess($upn, "Create user and assign to '$($row.Department)' group")) {
        $tempPassword = Get-TemporaryPassword
        $passwordProfile = @{
            Password                      = $tempPassword
            ForceChangePasswordNextSignIn = $true
        }

        $newUser = New-MgUser -DisplayName $displayName `
            -UserPrincipalName $upn `
            -MailNickname ($upn.Split("@")[0]) `
            -Department $row.Department `
            -JobTitle $row.JobTitle `
            -UsageLocation $row.UsageLocation `
            -AccountEnabled:$true `
            -PasswordProfile $passwordProfile

        # Keep the one-time password paired with its UPN for handoff.
        $credentials += [PSCustomObject]@{
            UserPrincipalName = $upn
            TemporaryPassword = $tempPassword
        }

        # Department group membership. License assignment rides on the
        # group (group-based licensing), so membership = provisioning done.
        $groupId = $DepartmentGroupMap[$row.Department]
        if ($null -ne $groupId) {
            New-MgGroupMember -GroupId $groupId -DirectoryObjectId $newUser.Id
        }
        else {
            Write-Warning "No group mapping for department '$($row.Department)' -- user created ungrouped."
            $status = "Created (no group mapping)"
        }
    }
    else {
        $status = "WhatIf"
    }

    $results += [PSCustomObject]@{ UserPrincipalName = $upn; Status = $status }
}

Write-Output ""
Write-Output "=== New-UserFromCsv summary ==="
$results | Format-Table -AutoSize | Out-String | Write-Output
Write-Output ("Total rows processed: {0}" -f $results.Count)

# One-time passwords: written ONCE to a timestamped CSV so they can be
# handed to users/managers. This file is SENSITIVE - it is git-ignored
# (see .gitignore), must never be emailed or committed, and should be
# securely deleted after distribution. Passwords are NOT printed above.
if ($credentials.Count -gt 0) {
    $credDir = Join-Path -Path $PSScriptRoot -ChildPath "..\credentials"
    if (-not (Test-Path -Path $credDir)) {
        New-Item -Path $credDir -ItemType Directory -Force | Out-Null
    }
    $credFile = Join-Path -Path $credDir -ChildPath ("temp-passwords-{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $credentials | Export-Csv -Path $credFile -NoTypeInformation -Encoding utf8
    Write-Warning ("Temporary passwords for {0} new user(s) written to: {1}" -f $credentials.Count, $credFile)
    Write-Warning "SENSITIVE FILE - distribute the passwords, then DELETE it. Consider Temporary Access Pass (TAP) instead of passwords for future onboardings."
}
else {
    Write-Output "No new users created - no passwords generated."
}

<#
    NOTE: Temporary Access Pass (TAP) alternative.
    Instead of generating and distributing one-time passwords, Entra ID
    supports time-limited Temporary Access Passes, which avoid password
    handling entirely:

        New-MgUserAuthenticationTemporaryAccessPassMethod -UserId $newUser.Id `
            -LifetimeInMinutes 480 -IsUsableOnce:$true

    (Requires the Microsoft.Graph.Identity.SignIns module and the
    UserAuthenticationMethod.ReadWrite.All permission.) The TAP is shown
    once at creation, the user signs in passwordless, then enrolls MFA.
    Prefer TAP for any onboarding where the helpdesk flow supports it.
#>
