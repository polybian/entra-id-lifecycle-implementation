<#
.SYNOPSIS
    Creates Entra ID users in bulk from a CSV and assigns each to their
    department security group.

.DESCRIPTION
    Reads a CSV (see templates/new-users.csv.example for the format) and for
    each row:

      1. Creates the user with New-MgUser (skip if the UPN already exists).
      2. Sets the usage location (licenses will not assign without it).
      3. Adds the user to the department security group that maps to the
         CSV's Department column.

    Licenses come from group-based licensing: the department group carries
    the license assignment, so there is no per-user license step here.

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
    # Random one-time password; the account is created with
    # ForceChangePasswordNextSignIn so this value is never permanent.
    $chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    $password = -join (1..16 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
    return $password
}

if (-not (Test-Path -Path $CsvPath)) {
    throw "CSV file not found: $CsvPath"
}

$rows = Import-Csv -Path $CsvPath
$results = @()

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
        $passwordProfile = @{
            Password                      = Get-TemporaryPassword
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
