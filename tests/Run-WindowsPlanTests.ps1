#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\WindowsPowerPlans.psm1') -Force -PassThru
$temp=Join-Path ([IO.Path]::GetTempPath()) ('lz-generic-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
 & $module {
    param($Root)
    function Assert($value,$message){if(-not $value){throw $message}}
    function Throws([scriptblock]$body){$caught=$false;try{& $body|Out-Null}catch{$caught=$true};Assert $caught 'Expected rejection'}
    function script:Get-MachineKey {'fixture-machine'}
    function script:Get-CurrentPlan {$script:Fake.Active}
    function script:Get-SystemCapabilities {[pscustomobject]@{ModernStandby=$script:Fake.Modern;Cpu=$script:Fake.Cpu}}
    function script:Get-PlanPersonality($Guid) {if($Guid -eq $script:Balanced){'Balanced'}else{$script:Fake.Personality}}
    function script:Get-PlanFingerprint($Guid) {$script:Fake.Fingerprint}
    function script:Get-SystemPlans {foreach($id in $script:Fake.Ids){[pscustomobject]@{Guid=$id;Name='Same name';IsActive=($id -eq $script:Fake.Active)}}}
    function script:Invoke-SystemPower([string[]]$Arguments){
      switch($Arguments[0]){
        '/export' {if($script:Fake.FailExport){throw 'Export failure'};[IO.File]::WriteAllText($Arguments[1],'plan-'+$Arguments[2])}
        '/import' {$script:Fake.Ids+=@($Arguments[2]);$script:Fake.Mutations++;if($script:Fake.FailImport){throw 'Import failed after creating GUID'}}
        '/delete' {if($script:Fake.FailDelete){throw 'Delete failure'};$script:Fake.Ids=@($script:Fake.Ids|Where-Object {$_ -ne $Arguments[1]});$script:Fake.Mutations++}
        '/setactive' {$script:Fake.Mutations++;if($script:Fake.IgnoreActivate -and $Arguments[1] -ne $script:Balanced){return};$script:Fake.Active=$Arguments[1]}
        default {throw 'Unmocked command'}
      }
    }
    function Fixture {
      $case=Join-Path $Root ([guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $case|Out-Null
      $source=Join-Path $case 'source.pow';[IO.File]::WriteAllText($source,'synthetic')
      $script:Fake=@{Ids=@($script:Balanced,'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');Active=$script:Balanced;Cpu='GenuineIntel';Modern=$false;Personality='Other';Fingerprint='content1';FailImport=$false;FailDelete=$false;FailExport=$false;IgnoreActivate=$false;Mutations=0}
      [pscustomobject]@{Action='Import';PlanGuid='';ResourceId='test';SourcePath=$source;SourceHash=(Get-FileHash $source).Hash;BackupDirectory=(Join-Path $case 'backups\one');ExportPath=''}
    }
    $r=Fixture;$before=@($script:Fake.Ids);$result=Invoke-WindowsPlanOperation $r
    Assert ($result.Success -and $script:Fake.Active -eq $script:Balanced -and $script:Fake.Ids.Count -eq 3) 'Import changed active or failed'
    $r.BackupDirectory=Join-Path (Split-Path $r.BackupDirectory -Parent) 'two';$repeat=Invoke-WindowsPlanOperation $r
    Assert ($repeat.PlanGuid -eq $result.PlanGuid -and $script:Fake.Ids.Count -eq 3) 'Resource identity did not prevent duplicate'
    $undo=Restore-WindowsOperation $result.BackupDirectory
    Assert ($undo.Success -and $script:Fake.Ids.Count -eq $before.Count) 'Import restore failed'
    'PASS: import without activation, identity deduplication, restore round trip'

    $r=Fixture;$script:Fake.FailImport=$true;$result=Invoke-WindowsPlanOperation $r
    Assert (-not $result.Success -and $script:Fake.Ids.Count -eq 2 -and $script:Fake.Active -eq $script:Balanced) 'Failed import left residue'
    'PASS: failed import that creates GUID is cleaned'

    $r=Fixture;$script:Fake.FailImport=$true;$script:Fake.FailDelete=$true;$result=Invoke-WindowsPlanOperation $r
    $m=Read-Operation $r.BackupDirectory
    Assert (-not $result.Success -and $m.Status -eq 'RollbackIncomplete' -and @($result.Errors).Count -gt 0) 'Rollback failure was hidden'
    'PASS: original error and incomplete rollback are recorded separately'

    $r=Fixture;$r.Action='Delete';$r.PlanGuid=$script:Fake.Ids[1];$script:Fake.Active=$r.PlanGuid
    $result=Invoke-WindowsPlanOperation $r;Assert ($result.Success -and $script:Fake.Active -eq $script:Balanced) 'Active delete fallback failed'
    $undo=Restore-WindowsOperation $r.BackupDirectory;Assert ($undo.Success -and $script:Fake.Active -eq $r.PlanGuid) 'Delete restore failed'
    'PASS: active plan deletion backs up, switches and restores'

    $r=Fixture;$r.Action='Delete';$r.PlanGuid=$script:Balanced
    Throws {Invoke-WindowsPlanOperation $r};Assert ($script:Fake.Mutations -eq 0) 'Balanced was mutated'
    $r.PlanGuid=$script:Fake.Ids[1];$script:Fake.Active=$r.PlanGuid;$script:Fake.Ids=@($r.PlanGuid)
    Throws {Invoke-WindowsPlanOperation $r};Assert ($script:Fake.Mutations -eq 0) 'Missing fallback caused mutations'
    'PASS: Balanced protection and missing fallback fail before mutation'

    $r=Fixture;$r.Action='Activate';$r.PlanGuid=$script:Fake.Ids[1];$script:Fake.IgnoreActivate=$true
    $result=Invoke-WindowsPlanOperation $r;Assert (-not $result.Success -and $script:Fake.Active -eq $script:Balanced) 'Activation readback ignored'
    'PASS: activation exit success with wrong active GUID is rejected'

    foreach($modern in @($true,$null)){
      $r=Fixture;$r.Action='Activate';$r.PlanGuid=$script:Fake.Ids[1];$script:Fake.Modern=$modern
      Throws {Invoke-WindowsPlanOperation $r};Assert ($script:Fake.Mutations -eq 0) 'Unknown/modern standby permitted incompatible plan'
    }
    $r=Fixture;$r.ResourceId='powerx-v2';$script:Fake.Cpu='AuthenticAMD';Throws {Invoke-WindowsPlanOperation $r}
    $r.Action='Activate';$r.PlanGuid=$script:Fake.Ids[1];Throws {Invoke-WindowsPlanOperation $r}
    'PASS: Modern Standby uncertainty and PowerX AMD restrictions'

    $r=Fixture;$r.SourceHash='bad';Throws {Invoke-WindowsPlanOperation $r};Assert ($script:Fake.Mutations -eq 0) 'Corrupt source mutated system'
    $r=Fixture;$r.Action='Delete';$r.PlanGuid=$script:Fake.Ids[1];$script:Fake.FailExport=$true
    Throws {Invoke-WindowsPlanOperation $r};Assert ($script:Fake.Mutations -eq 0) 'Backup failure mutated system'
    'PASS: hash mismatch and backup failure precede mutation'

    $r=Fixture;$result=Invoke-WindowsPlanOperation $r;$script:Fake.Fingerprint='changed'
    $before=$script:Fake.Mutations;Throws {Restore-WindowsOperation $r.BackupDirectory}
    Assert ($script:Fake.Mutations -eq $before) 'Changed imported plan was deleted'
    'PASS: later changes to imported plan prevent destructive restore'

    $r=Fixture;$r.Action='Delete';$r.PlanGuid=$script:Fake.Ids[1];$null=Invoke-WindowsPlanOperation $r
    $script:Fake.Ids+=@($r.PlanGuid);$before=$script:Fake.Mutations;Throws {Restore-WindowsOperation $r.BackupDirectory}
    Assert ($script:Fake.Mutations -eq $before) 'Same GUID overwrite was allowed'
    $script:Fake.Ids=@($script:Balanced);[IO.File]::WriteAllText((Join-Path $r.BackupDirectory 'plan.pow'),'bad');Throws {Restore-WindowsOperation $r.BackupDirectory}
    'PASS: restore rejects existing GUID and corrupt backup'
 } $temp
} finally {
 Remove-Module $module.Name -ErrorAction SilentlyContinue
 $full=[IO.Path]::GetFullPath($temp);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full).StartsWith('lz-generic-tests-')){Remove-Item -LiteralPath $full -Recurse -Force}
}
