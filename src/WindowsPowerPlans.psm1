#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:Balanced='381b4222-f694-41f0-9685-ff5bb260df2e'
function Invoke-SystemPower([string[]]$Arguments) {
    $output=& "$env:SystemRoot\System32\powercfg.exe" @Arguments 2>&1
    if($LASTEXITCODE -ne 0){throw "powercfg 执行失败：$output"}
    $output
}
function Assert-PlanGuid([string]$Guid) {
    if($Guid -notmatch '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'){throw '无效的计划 GUID。'}
}
function Get-CurrentPlan {
    $id=[regex]::Match((Invoke-SystemPower @('/getactivescheme') | Out-String),'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
    Assert-PlanGuid $id
    $id.ToLowerInvariant()
}
function Get-PlanPersonality([string]$Guid) {
    try {
        $setting='245d8541-3943-4422-b025-13a784f679b7'
        $p=Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$Guid\$setting"
        $values=@($p.ACSettingIndex,$p.DCSettingIndex)
        $types=@(foreach($value in $values){
            $v=(Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\$setting\$value").SettingValue
            ([guid]::new([byte[]]$v)).ToString()
        })
        if($types[0] -eq $script:Balanced -and $types[1] -eq $script:Balanced){return 'Balanced'}
        return 'Other'
    } catch { return 'Unknown' }
}
function Get-SystemPlans {
    $active=Get-CurrentPlan
    foreach($line in @(Invoke-SystemPower @('/list'))){
        if("$line" -match '([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})\s+\((.*)\)'){
            $id=$Matches[1].ToLowerInvariant();$name=$Matches[2]
            [pscustomobject]@{Guid=$id;Name=$name;IsActive=($id -eq $active);Personality=(Get-PlanPersonality $id)}
        }
    }
}
function Get-SystemCapabilities {
    $modern=$null;$cpu='Unknown';$model='未知';$manufacturer='未知'
    try {
        if(-not ('LzPowerCapabilities' -as [type])){Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LzPowerCapabilities {
 [DllImport("powrprof.dll")] private static extern uint CallNtPowerInformation(int level, IntPtr input, uint inputSize, byte[] output, uint size);
 public static bool ModernStandby() { byte[] b=new byte[76]; if(CallNtPowerInformation(4,IntPtr.Zero,0,b,76)!=0) throw new InvalidOperationException("Cannot read power capabilities"); return b[20]!=0; }
}
'@}
        $modern=[LzPowerCapabilities]::ModernStandby()
    } catch {}
    try {$processor=Get-CimInstance Win32_Processor | Select-Object -First 1;$cpu=$processor.Manufacturer+' / '+$processor.Name} catch {}
    try {$system=Get-CimInstance Win32_ComputerSystem;$model=$system.Model;$manufacturer=$system.Manufacturer} catch {}
    [pscustomobject]@{ModernStandby=$modern;Cpu=$cpu;Model=$model;Manufacturer=$manufacturer}
}
function Get-MachineKey {
    $s=(Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
    $sha=[Security.Cryptography.SHA256]::Create()
    try {([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)))).Replace('-','')}finally{$sha.Dispose()}
}
function Get-PlanFingerprint([string]$Guid) {
    $root="HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$Guid"
    $base=Get-Item -LiteralPath $root
    $entries=@(foreach($key in @($base)+@(Get-ChildItem -LiteralPath $root -Recurse | Sort-Object Name)){
        foreach($name in @($key.GetValueNames() | Sort-Object)){
            $value=$key.GetValue($name)
            if($value -is [byte[]]){$value=[Convert]::ToBase64String($value)}
            [ordered]@{Key=$key.Name.Substring($base.Name.Length);Name=$name;Kind="$($key.GetValueKind($name))";Value=$value}
        }
    })
    $sha=[Security.Cryptography.SHA256]::Create()
    try {([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($entries|ConvertTo-Json -Depth 6 -Compress))))).Replace('-','')}finally{$sha.Dispose()}
}
function Get-WindowsPowerState {
    [pscustomobject]@{Plans=@(Get-SystemPlans);ActiveGuid=(Get-CurrentPlan);Capabilities=(Get-SystemCapabilities)}
}
function Assert-CanActivate([string]$Guid,[string]$ResourceId='') {
    Assert-PlanGuid $Guid
    if($Guid -notin @((Get-SystemPlans).Guid)){throw '目标计划不存在。'}
    $cap=Get-SystemCapabilities
    # The known PowerX plan GUID and managed-resource identity both remain blocked on AMD/unknown CPUs.
    if(($ResourceId -eq 'powerx-v2' -or $Guid -eq 'e5b7579e-1e55-46b5-9f43-6ecb7c63330f') -and $cap.Cpu -notmatch 'GenuineIntel|Intel'){throw 'PowerX-v2 在 AMD 或无法识别的 CPU 上不可使用。'}
    if($cap.ModernStandby -ne $false -and (Get-PlanPersonality $Guid) -ne 'Balanced'){throw '现代待机已启用或无法确认；只有已确认在交流电及电池下均为平衡类型的计划可以激活。'}
}
function Set-VerifiedActive([string]$Guid) {
    Invoke-SystemPower @('/setactive',$Guid) | Out-Null
    if((Get-CurrentPlan) -ne $Guid){throw '激活后实际活动计划与目标不一致。'}
}
function Write-Operation($Directory,$Manifest) {
    $json=$Manifest | ConvertTo-Json -Depth 12
    $tmp=Join-Path $Directory 'manifest.json.tmp'
    [IO.File]::WriteAllText($tmp,$json,[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination (Join-Path $Directory 'manifest.json') -Force
}
function Read-Operation([string]$Directory) {
    $m=Get-Content -LiteralPath (Join-Path $Directory 'manifest.json') -Raw | ConvertFrom-Json
    if($m.SchemaVersion -ne 2 -or $m.Kind -ne 'WindowsPowerPlanOperation' -or $m.MachineKey -ne (Get-MachineKey)){throw '备份类型或本机标识不匹配。'}
    if($m.Action -notin @('Import','Activate','Delete')){throw '不支持的备份操作。'}
    Assert-PlanGuid $m.ActiveGuid;Assert-PlanGuid $m.PlanGuid
    if($m.Action -in @('Import','Delete') -and $m.PlanGuid -eq $script:Balanced){throw '备份不能要求删除或覆盖 Windows 平衡计划。'}
    if($m.Action -eq 'Import' -and $m.PlanGuid -eq $m.ActiveGuid){throw '导入备份的目标与原活动计划不能相同。'}
    if($m.Action -eq 'Delete' -and $m.PlanHash -notmatch '^[0-9a-fA-F]{64}$'){throw '删除备份缺少有效的计划哈希。'}
    if($m.PlanHash){
        if((Get-FileHash -LiteralPath (Join-Path $Directory 'plan.pow')).Hash -ne $m.PlanHash){throw '计划备份哈希不匹配。'}
    }
    $m
}
function Restore-WindowsOperation([string]$Directory) {
    $m=Read-Operation $Directory
    $errors=New-Object 'System.Collections.Generic.List[string]'
    $ids=@((Get-SystemPlans).Guid)
    if($m.Action -eq 'Delete' -and $m.PlanGuid -in $ids){throw '相同 GUID 的计划已存在；为保护后来修改的参数，停止恢复。'}
    if($m.ActiveGuid -notin $ids -and -not($m.Action -eq 'Delete' -and $m.ActiveGuid -eq $m.PlanGuid)){throw '原活动计划已不存在，停止恢复。'}
    if($m.Action -eq 'Import' -and $m.PlanGuid -in $ids){
        if(-not $m.ContentFingerprint -or (Get-PlanFingerprint $m.PlanGuid) -ne $m.ContentFingerprint){throw '已导入计划后来发生变化，停止自动删除。'}
    }
    if($m.Action -eq 'Delete'){
        try {Invoke-SystemPower @('/import',(Join-Path $Directory 'plan.pow'),$m.PlanGuid)|Out-Null
            if($m.PlanGuid -notin @((Get-SystemPlans).Guid)){throw '恢复导入后计划不存在。'}
        }catch{$errors.Add("恢复计划：$_")}
    }
    try {Set-VerifiedActive $m.ActiveGuid}catch{$errors.Add("恢复活动计划：$_")}
    if($m.Action -eq 'Import' -and $m.PlanGuid -in @((Get-SystemPlans).Guid)){
        try {
            if((Get-CurrentPlan) -eq $m.PlanGuid){throw '该计划仍在使用，保留以避免误删。'}
            Invoke-SystemPower @('/delete',$m.PlanGuid)|Out-Null
            if($m.PlanGuid -in @((Get-SystemPlans).Guid)){throw '删除导入计划后仍存在。'}
        }catch{$errors.Add("移除导入计划：$_")}
    }
    $m.Status=if($errors.Count){'RestoreIncomplete'}else{'Restored'}
    $m.RollbackErrors=@($errors.ToArray());Write-Operation $Directory $m
    [pscustomobject]@{Success=($errors.Count -eq 0);Message=($m.Status);BackupDirectory=$Directory;Errors=@($errors.ToArray())}
}
function Invoke-WindowsPlanOperation($Request) {
    $action=[string]$Request.Action
    if($action -eq 'Restore'){return Restore-WindowsOperation $Request.BackupDirectory}
    if($action -notin @('Import','Activate','Delete','Export')){throw '不支持的操作。'}
    $id=[string]$Request.PlanGuid;$resource=[string]$Request.ResourceId
    $active=Get-CurrentPlan;$ids=@((Get-SystemPlans).Guid)
    if($action -eq 'Import'){
        if($resource -eq 'powerx-v2' -and (Get-SystemCapabilities).Cpu -notmatch 'GenuineIntel|Intel'){throw 'PowerX-v2 在 AMD 或无法识别的 CPU 上不可导入。'}
        if((Get-FileHash -LiteralPath $Request.SourcePath).Hash -ne $Request.SourceHash){throw '下载计划的 SHA256 不匹配。'}
        # Records are keyed by resource and hash, never by a user-visible plan name.
        $parent=Split-Path $Request.BackupDirectory -Parent
        foreach($file in @(Get-ChildItem -LiteralPath $parent -Filter manifest.json -Recurse -ErrorAction SilentlyContinue)){
            try{$old=Read-Operation $file.DirectoryName}catch{continue}
            if($old.Action -eq 'Import' -and $old.Status -eq 'Completed' -and $old.ResourceId -eq $resource -and $old.SourceHash -eq $Request.SourceHash -and $old.PlanGuid -in $ids){return [pscustomobject]@{Success=$true;Message='该资源已导入；未重复创建或激活。';PlanGuid=$old.PlanGuid;BackupDirectory=$file.DirectoryName}}
        }
        $id=[guid]::NewGuid().ToString()
    }else{
        Assert-PlanGuid $id
        if($id -notin $ids){throw '目标计划不存在。'}
    }
    if($action -eq 'Export'){
        if(Test-Path -LiteralPath $Request.ExportPath){throw '导出目标已存在，不覆盖原文件。'}
        Invoke-SystemPower @('/export',$Request.ExportPath,$id)|Out-Null
        if(-not(Test-Path -LiteralPath $Request.ExportPath -PathType Leaf)){throw '导出文件未生成。'}
        return [pscustomobject]@{Success=$true;Message='导出完成。';SHA256=(Get-FileHash -LiteralPath $Request.ExportPath).Hash}
    }
    if($action -eq 'Activate'){
        foreach($file in @(Get-ChildItem -LiteralPath (Split-Path $Request.BackupDirectory -Parent) -Filter manifest.json -Recurse -ErrorAction SilentlyContinue)){
            try{$record=Read-Operation $file.DirectoryName}catch{continue}
            if($record.Action -eq 'Import' -and $record.PlanGuid -eq $id -and $record.ResourceId -eq 'powerx-v2'){$resource='powerx-v2';break}
        }
        Assert-CanActivate $id $resource
    }
    if($action -eq 'Delete'){
        if($id -eq $script:Balanced){throw 'Windows 平衡计划受到保护。'}
        if($id -eq $active){Assert-CanActivate $script:Balanced}
    }
    $dir=[IO.Path]::GetFullPath($Request.BackupDirectory)
    if(Test-Path -LiteralPath $dir){throw '备份目录已存在，不覆盖。'}
    New-Item -ItemType Directory -Path $dir | Out-Null
    $m=[ordered]@{SchemaVersion=2;Kind='WindowsPowerPlanOperation';MachineKey=(Get-MachineKey);Created=(Get-Date -Format o);Action=$action;ActiveGuid=$active;PlanGuid=$id;ResourceId=$resource;SourceHash=[string]$Request.SourceHash;PlanHash='';InstalledHash='';ContentFingerprint='';Status='Prepared';Error='';RollbackErrors=@()}
    if($action -eq 'Delete'){
        Invoke-SystemPower @('/export',(Join-Path $dir 'plan.pow'),$id)|Out-Null
        $m.PlanHash=(Get-FileHash -LiteralPath (Join-Path $dir 'plan.pow')).Hash
    }
    Write-Operation $dir $m
    try {
        switch($action){
            Import {
                Invoke-SystemPower @('/import',$Request.SourcePath,$id)|Out-Null
                if($id -notin @((Get-SystemPlans).Guid)){throw '导入后目标计划不存在。'}
                Invoke-SystemPower @('/export',(Join-Path $dir 'installed.pow'),$id)|Out-Null
                $m.InstalledHash=(Get-FileHash -LiteralPath (Join-Path $dir 'installed.pow')).Hash
                $m.ContentFingerprint=Get-PlanFingerprint $id
                if((Get-CurrentPlan) -ne $active){throw '仅导入不应改变活动计划。'}
            }
            Activate {Set-VerifiedActive $id}
            Delete {
                if($id -eq $active){Set-VerifiedActive $script:Balanced}
                Invoke-SystemPower @('/delete',$id)|Out-Null
                if($id -in @((Get-SystemPlans).Guid)){throw '计划仍存在或被重新创建。'}
            }
        }
        $m.Status='Completed';Write-Operation $dir $m
        [pscustomobject]@{Success=$true;Message='操作完成并通过回读核验。';PlanGuid=$id;BackupDirectory=$dir}
    }catch{
        $m.Error="$_";$errors=New-Object 'System.Collections.Generic.List[string]'
        if($action -eq 'Delete'){
            try {if($id -notin @((Get-SystemPlans).Guid)){Invoke-SystemPower @('/import',(Join-Path $dir 'plan.pow'),$id)|Out-Null}}catch{$errors.Add("恢复删除的计划：$_")}
        }
        try {Set-VerifiedActive $active}catch{$errors.Add("恢复活动计划：$_")}
        if($action -eq 'Import'){
            try {if($id -in @((Get-SystemPlans).Guid)){if((Get-CurrentPlan) -eq $id){throw '目标仍为活动计划。'};Invoke-SystemPower @('/delete',$id)|Out-Null}
                if($id -in @((Get-SystemPlans).Guid)){throw '导入残留仍存在。'}
            }catch{$errors.Add("清理导入残留：$_")}
        }
        $m.Status=if($errors.Count){'RollbackIncomplete'}else{'RolledBack'};$m.RollbackErrors=@($errors.ToArray());Write-Operation $dir $m
        [pscustomobject]@{Success=$false;Message=$m.Error;BackupDirectory=$dir;Errors=@($errors.ToArray())}
    }
}
Export-ModuleMember -Function Get-WindowsPowerState,Invoke-WindowsPlanOperation,Get-SystemPlans,Get-SystemCapabilities
