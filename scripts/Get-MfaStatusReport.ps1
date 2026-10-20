<#
.SYNOPSIS
    Reports per-user MFA registration status for the tenant and exports CSV.

.DESCRIPTION
    Reads the Microsoft Graph authentication-methods user registration
    details report and exports one row per user: UPN, display name,
    whether MFA is registered/capable, whether SSPR is registered, and
    the methods on file.

    Use it to chase the "never registered" list during an MFA enforcement
    rollout instead of discovering the gap during an incident.

.PREREQUISITES
    - Windows admin host with the Microsoft Graph PowerShell SDK.
    - Connect first (read-only scopes -- this script changes nothing):

        Install-Module Microsoft.Graph -Scope CurrentUser
        Connect-MgGraph -Scopes "AuditLog.Read.All","UserAuthenticationMethod.Read.All","User.Read.All" -NoWelcome

    Alternative data source: per-user detail via
    Get-MgUserAuthenticationMethod -UserId <upn> (slower, one call per user;
    the report cmdlet below returns the whole tenant in one call).

.EXAMPLE
    .\Get-MfaStatusReport.ps1

.EXAMPLE
    .\Get-MfaStatusReport.ps1 -OutputPath "C:\Reports\mfa-2026-10.csv" -OnlyUnregistered
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ".\mfa-status-report.csv",

    [switch]$OnlyUnregistered
)

#Requires -Modules Microsoft.Graph.Reports

$report = Get-MgReportAuthenticationMethodUserRegistrationDetail -All

$rows = foreach ($entry in $report) {
    [PSCustomObject]@{
        UserPrincipalName  = $entry.UserPrincipalName
        DisplayName        = $entry.UserDisplayName
        IsMfaRegistered    = $entry.IsMfaRegistered
        IsMfaCapable       = $entry.IsMfaCapable
        IsSsprRegistered   = $entry.IsSsprRegistered
        DefaultMfaMethod   = $entry.DefaultMfaMethod
        MethodsRegistered  = ($entry.MethodsRegistered -join "; ")
    }
}

if ($OnlyUnregistered) {
    $rows = $rows | Where-Object { $_.IsMfaRegistered -eq $false }
}

$rows | Sort-Object -Property UserPrincipalName |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8

Write-Output "Report written to $OutputPath"
Write-Output ("Users in report:        {0}" -f @($rows).Count)
Write-Output ("MFA registered:         {0}" -f @($rows | Where-Object { $_.IsMfaRegistered }).Count)
Write-Output ("NOT MFA registered:     {0}" -f @($rows | Where-Object { $_.IsMfaRegistered -eq $false }).Count)
