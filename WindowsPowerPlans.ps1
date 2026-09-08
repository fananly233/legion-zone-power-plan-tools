#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param([ValidateSet('Status','Import','Activate','Export','Delete','Restore')][string]$Action='Status',
 [string]$PlanGuid,[string]$SourcePath,[string]$ExportPath,[string]$BackupDirectory)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'src\WindowsPowerPlans.psm1') -Force
if($Action -eq 'Status'){Get-WindowsPowerState;return}
if(-not $PSCmdlet.ShouldProcess('Windows power plans',$Action)){Get-WindowsPowerState;return}
if(-not([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))){throw 'Run PowerShell as Administrator.'}
if($Action -eq 'Restore' -and -not $BackupDirectory){throw 'Restore requires -BackupDirectory.'}
if(-not $BackupDirectory){$BackupDirectory=Join-Path $env:ProgramData ('LenovoPowerPlanTools\backups\'+[guid]::NewGuid().ToString('N'))}
$hash='';$resource=''
if($Action -eq 'Import'){
 $hash=(Get-FileHash -LiteralPath $SourcePath).Hash
 $catalog=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'resources\catalog.json') -Raw | ConvertFrom-Json
 foreach($asset in $catalog){if($asset.Sha256 -eq $hash){$resource=$asset.Id}}
}
Invoke-WindowsPlanOperation ([pscustomobject]@{Action=$Action;PlanGuid=$PlanGuid;SourcePath=$SourcePath;SourceHash=$hash;ResourceId=$resource;ExportPath=$ExportPath;BackupDirectory=$BackupDirectory})
