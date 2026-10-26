<#
.SYNOPSIS
    Offboards a single Entra ID user: disable sign-in, revoke sessions,
    remove groups and licenses, and log every action.

.DESCRIPTION
    Given a user principal name, performs the Entra ID portion of the
    offboarding SOP (see docs/onboarding-offboarding-runbook.md):

      1. Blocks sign-in        -> Update-MgUser -AccountEnabled:$false
      2. Revokes sessions      -> Revoke-MgUserSignInSession (kills refresh
                                  tokens -- a disable alone leaves live
                                  sessions running until they expire)
      3. Removes group memberships (group-based licensing releases the
         user's licenses when membership is removed)
      4. Removes any directly-assigned licenses
      5. Writes a timestamped log with every action taken

    ConfirmImpact is High: even without -WhatIf, the script prompts before
    acting. Supports -WhatIf for a dry run.

    NOT COVERED here (need their own modules/sessions -- see the commented
    placeholder block at the bottom):
      - Exchange Online: convert mailbox to shared + set auto-reply.
      - OneDrive: transfer ownership to the manager.
      - Intune: retire/wipe the assigned device.

.PREREQUISITES
    - Windows admin host with the Microsoft Graph PowerShell SDK.
    - Connect first:

        Install-Module Microsoft.Graph -Scope CurrentUser
        Connect-MgGraph -Scopes "User.ReadWrite.All","GroupMember.ReadWrite.All","LicenseAssignment.ReadWrite.All" -NoWelcome

.EXAMPLE
    .\Invoke-UserOffboarding.ps1 -UserPrincipalName "jane.doe@contoso.example" -WhatIf

.EXAMPLE
    .\Invoke-UserOffboarding.ps1 -UserPrincipalName "jane.doe@contoso.example"
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $true)]
    [string]$UserPrincipalName,

    [string]$LogDirectory = "$PSScriptRoot\..\logs"
)

#Requires -Modules Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement

function Write-OffboardLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    $line | Out-File -FilePath $Path -Append -Encoding utf8
    Write-Output $line
}

$user = Get-MgUser -UserId $UserPrincipalName -ErrorAction SilentlyContinue
if ($null -eq $user) {
    throw "User not found: $UserPrincipalName"
}

if (-not (Test-Path -Path $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
}
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path -Path $LogDirectory -ChildPath "offboarding-$UserPrincipalName-$stamp.log"

Write-OffboardLog -Path $logFile -Message "Offboarding started for $($user.DisplayName) ($UserPrincipalName) by $env:USERNAME"

# 1. Block sign-in.
if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Block sign-in (accountEnabled=false)")) {
    Update-MgUser -UserId $user.Id -AccountEnabled:$false
    Write-OffboardLog -Path $logFile -Message "Sign-in blocked."
}
else {
    Write-OffboardLog -Path $logFile -Message "WhatIf: would block sign-in."
}

# 2. Revoke existing sessions / refresh tokens.
if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Revoke all sign-in sessions")) {
    Revoke-MgUserSignInSession -UserId $user.Id
    Write-OffboardLog -Path $logFile -Message "Sign-in sessions revoked."
}
else {
    Write-OffboardLog -Path $logFile -Message "WhatIf: would revoke sign-in sessions."
}

# 3. Remove group memberships.
#    Dynamic groups and mail-enabled groups / distribution lists CANNOT be
#    edited here: dynamic membership is rule-driven, and DLs are managed
#    through Exchange. Remove-MgGroupMemberByRef fails on both - catch it,
#    log the group's display name (not just its Id), and keep going.
$groups = Get-MgUserMemberOf -UserId $user.Id -All |
    Where-Object { $_.AdditionalProperties."@odata.type" -eq "#microsoft.graph.group" }
foreach ($group in $groups) {
    $groupName = $group.Id
    try {
        $groupName = (Get-MgGroup -GroupId $group.Id -ErrorAction Stop).DisplayName
    }
    catch {
        # Fall back to the Id in the log lines below.
    }

    if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Remove from group '$groupName'")) {
        try {
            Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $user.Id -ErrorAction Stop
            Write-OffboardLog -Path $logFile -Message "Removed from group '$groupName'."
        }
        catch {
            Write-OffboardLog -Path $logFile -Message "SKIPPED group '$groupName' ($($group.Id)): $($_.Exception.Message) -- dynamic or mail-enabled groups must be handled outside Entra ID (see runbook)."
        }
    }
    else {
        Write-OffboardLog -Path $logFile -Message "WhatIf: would remove from group '$groupName'."
    }
}

# 4. Remove directly-assigned licenses ONLY.
#    Get-MgUserLicenseDetail returns EVERY license the user holds, including
#    ones inherited through group membership - and Set-MgUserLicense
#    -RemoveLicenses FAILS on inherited ones (only the group's own assignment
#    can release them; step 3 already triggered that by removing the
#    memberships). So read LicenseAssignmentStates and keep only the
#    assignments with no AssignedByGroup (i.e. assigned directly to the user).
$assignmentStates = (Get-MgUser -UserId $user.Id -Property LicenseAssignmentStates).LicenseAssignmentStates
$skuIds = @($assignmentStates | Where-Object { [string]::IsNullOrEmpty($_.AssignedByGroup) } | ForEach-Object { $_.SkuId })
if ($skuIds.Count -gt 0) {
    if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Remove $($skuIds.Count) direct license assignment(s)")) {
        Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses $skuIds
        Write-OffboardLog -Path $logFile -Message "Direct licenses removed: $($skuIds -join ', ')."
    }
    else {
        Write-OffboardLog -Path $logFile -Message "WhatIf: would remove direct licenses: $($skuIds -join ', ')."
    }
}
else {
    Write-OffboardLog -Path $logFile -Message "No directly-assigned licenses to remove (any group-inherited ones release via the step-3 membership removals)."
}

<#
    ---------------------------------------------------------------------
    PLACEHOLDER STEPS -- run from an Exchange-connected session.

    Requires the ExchangeOnlineManagement module:

        Install-Module ExchangeOnlineManagement -Scope CurrentUser
        Connect-ExchangeOnline

    Convert mailbox to shared (keeps the data, frees the license):

        Set-Mailbox -Identity $UserPrincipalName -Type Shared
        Add-MailboxPermission -Identity $UserPrincipalName `
            -User "<manager-upn>" -AccessRights FullAccess

    Set the departure auto-reply:

        Set-MailboxAutoReplyConfiguration -Identity $UserPrincipalName `
            -AutoReplyState Enabled `
            -ExternalMessage "This person is no longer with the company. Please contact <team-upn>."

    OneDrive ownership transfer is done via the SharePoint admin center
    (or PnP PowerShell: Set-PnPTenantSite / Add-SPOUser) -- see the runbook.
    Intune device retire/wipe is done from the Intune admin center.
    ---------------------------------------------------------------------
#>

Write-OffboardLog -Path $logFile -Message "Offboarding (Entra ID portion) complete. Log: $logFile"
Write-Output "Done. Next manual steps: mailbox conversion, OneDrive transfer, device retire -- see docs/onboarding-offboarding-runbook.md."
