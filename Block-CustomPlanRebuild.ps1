#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Status','Apply','Restore')][string]$Action='Status',
    [string]$BackupDirectory
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'src\CustomPlanPatch.psm1') -Force
if ($Action -eq 'Status') { Get-CustomPlanPatchState; return }
if ($Action -eq 'Restore' -and -not $BackupDirectory) { throw 'Restore requires -BackupDirectory.' }
if (-not $PSCmdlet.ShouldProcess('LZTrayPlugin.dll: skip custom-plan creation (invalidates vendor signature)', $Action)) { Get-CustomPlanPatchState; return }
if (-not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) { throw 'Run PowerShell as Administrator.' }
if ($Action -eq 'Apply') {
    if (-not $BackupDirectory) { $BackupDirectory=Join-Path $PSScriptRoot ('backups\patch-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')) }
    Install-CustomPlanPatch $BackupDirectory
} else { Restore-CustomPlanPatch $BackupDirectory }
