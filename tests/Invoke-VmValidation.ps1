#requires -Version 5.1
[CmdletBinding()]
param([switch]$AllowVirtualMachineChanges,[string]$OutputDirectory=(Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\vm-validation'))
$ErrorActionPreference='Stop'
Import-Module Microsoft.PowerShell.Utility,Microsoft.PowerShell.Management -Global
$model=(Get-CimInstance Win32_ComputerSystem).Model
if(-not $AllowVirtualMachineChanges -or $model -notmatch 'Virtual Machine|VMware|VirtualBox|KVM'){throw 'Run only in a disposable VM with -AllowVirtualMachineChanges.'}
if(-not([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))){throw 'VM validation requires administrator privileges.'}
$repo=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $repo 'src\WindowsPowerPlans.psm1') -Force -PassThru
New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null
$original=& $module {Get-CurrentPlan}
$created=New-Object 'System.Collections.Generic.List[string]'
$reports=New-Object 'System.Collections.Generic.List[object]'
function Power([string[]]$Arguments){& $module {param($a) Invoke-SystemPower $a} $Arguments}
function Ensure($value,$message){if(-not $value){throw $message}}
function Req($Action,$Guid='',$Directory=''){
 [pscustomobject]@{Action=$Action;PlanGuid=$Guid;ResourceId='vm-fixture';SourcePath='';SourceHash='';BackupDirectory=$Directory;ExportPath=''}
}
try {
 foreach($asset in (Get-Content -LiteralPath (Join-Path $repo 'resources\catalog.json') -Raw|ConvertFrom-Json)){
    $file=Join-Path $OutputDirectory ($asset.Id+'.pow')
    Invoke-WebRequest -UseBasicParsing -Uri $asset.DownloadUrl -OutFile $file
    Ensure ((Get-FileHash -LiteralPath $file).Hash -eq $asset.Sha256) ('Source hash mismatch: '+$asset.Id)
    $id=[guid]::NewGuid().ToString();$created.Add($id)
    try {
        Power @('/import',$file,$id)|Out-Null
        $details=Power @('/qh',$id)|Out-String
        $details|Set-Content -LiteralPath (Join-Path $OutputDirectory ($asset.Id+'-parameters.txt')) -Encoding UTF8
        $setting=Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$id\245d8541-3943-4422-b025-13a784f679b7"
        $reports.Add([ordered]@{Id=$asset.Id;Sha256=$asset.Sha256;Imported=$true;Activated=$false;AcPersonalityIndex=$setting.ACSettingIndex;DcPersonalityIndex=$setting.DCSettingIndex;Personality=(& $module {param($g) Get-PlanPersonality $g} $id)})
    } finally {
        if($id -in @((Get-SystemPlans).Guid)){Power @('/delete',$id)|Out-Null}
        Ensure ($id -notin @((Get-SystemPlans).Guid)) ('Audit residue: '+$id)
    }
    Ensure ((& $module {Get-CurrentPlan}) -eq $original) 'Catalog audit changed the active plan'
 }
 # Exercise full transactions with an exported Balanced plan, never activate third-party plans.
 $balanced='381b4222-f694-41f0-9685-ff5bb260df2e'
 $source=Join-Path $OutputDirectory 'balanced-fixture.pow';Power @('/export',$source,$balanced)|Out-Null
 $import=Req 'Import' '' (Join-Path $OutputDirectory 'transactions\import')
 $import.SourcePath=$source;$import.SourceHash=(Get-FileHash -LiteralPath $source).Hash
 $result=Invoke-WindowsPlanOperation $import
 Ensure $result.Success ('Native import failed: '+$result.Message)
 $id=$result.PlanGuid;$created.Add($id)
 $activate=Req 'Activate' $id (Join-Path $OutputDirectory 'transactions\activate')
 $result=Invoke-WindowsPlanOperation $activate;Ensure $result.Success ('Native activation failed: '+$result.Message)
 $restore=Req 'Restore' '' $activate.BackupDirectory
 $result=Invoke-WindowsPlanOperation $restore;Ensure $result.Success 'Native activation restore failed'
 $delete=Req 'Delete' $id (Join-Path $OutputDirectory 'transactions\delete')
 $result=Invoke-WindowsPlanOperation $delete;Ensure $result.Success 'Native delete failed'
 $restore.BackupDirectory=$delete.BackupDirectory;$result=Invoke-WindowsPlanOperation $restore;Ensure $result.Success 'Native delete restore failed'
 $restore.BackupDirectory=$import.BackupDirectory;$result=Invoke-WindowsPlanOperation $restore;Ensure $result.Success 'Native import restore failed'
 Ensure ((& $module {Get-CurrentPlan}) -eq $original) 'Final active plan mismatch'
 [ordered]@{SchemaVersion=1;Environment='Disposable Windows VM';OS=(Get-CimInstance Win32_OperatingSystem).Caption;Build=[Environment]::OSVersion.Version.ToString();Catalog=@($reports.ToArray());NativeRoundTrip='Passed';ThirdPartyActivation='Not tested';VendorPatch='Not tested'} |
    ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding UTF8
 'PASS: seven pinned assets imported, parameters read, all removed; Balanced fixture import/activate/delete/restore round trip.'
} finally {
 Power @('/setactive',$original)|Out-Null
 foreach($id in $created){if($id -in @((Get-SystemPlans).Guid)){Power @('/delete',$id)|Out-Null}}
 Remove-Module $module.Name -ErrorAction SilentlyContinue
}
