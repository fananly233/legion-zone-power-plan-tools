#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Status', 'Disable', 'Restore')]
    [string]$Action = 'Status',
    [string]$BackupDirectory
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\LegionPowerPlans.psm1') -Force
if ($Action -eq 'Status') {
    Get-LegionState
    return
}
if ($Action -eq 'Restore' -and -not $BackupDirectory) {
    throw 'Restore requires -BackupDirectory pointing to a backup created by this project.'
}
if (-not $PSCmdlet.ShouldProcess('Local Legion Zone power plans and import templates', $Action)) {
    Get-LegionState
    return
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open PowerShell as Administrator to Disable or Restore. Status and -WhatIf are read-only.'
}
if ($Action -eq 'Disable') {
    if (-not $BackupDirectory) {
        $BackupDirectory = Join-Path $PSScriptRoot ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    }
    Disable-LegionPlans -BackupDirectory $BackupDirectory
} else {
    Restore-LegionPlans -BackupDirectory $BackupDirectory
}
