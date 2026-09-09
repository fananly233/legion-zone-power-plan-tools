#requires -Version 5.1
param([Parameter(Mandatory)][string]$RequestPath,[Parameter(Mandatory)][string]$ResponsePath)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$builtinModules=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'
foreach($name in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management')){
    Import-Module (Join-Path $builtinModules "$name\$name.psd1") -Global
}
Import-Module (Join-Path $PSScriptRoot 'WindowsPowerPlans.psm1') -Force
try {
    $r=Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
    if($r.Action -notin @('Status','Details','Import','Activate','Export','Delete','Restore','VendorDisable','PatchApply','LegacyRestore')){throw '不支持的操作。'}
    if($r.Action -notin @('Status','Details')){
        if(-not([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))){throw '修改需要管理员权限。'}
    }
    switch($r.Action) {
        Status {
            $state=Get-WindowsPowerState
            $vendor=[ordered]@{Version='未安装 / 无法读取';BasicSupported=$false;BasicReason='未检测到已适配的 Legion Zone';PatchSupported=$false;Patched=$null;PatchReason='未检测到已适配的插件';PerformanceSwitch=$null;Templates=@()}
            try {
                Import-Module (Join-Path $PSScriptRoot 'LegionPowerPlans.psm1') -Force
                $v=Get-LegionState
                $vendor.Version=$v.InstalledVersion;$vendor.PerformanceSwitch=$v.PerformanceSwitch;$vendor.Templates=$v.Templates
                $vendor.BasicSupported=($v.InstalledVersion -eq '2.0.28.8182' -and $v.PerformanceSwitch -in @(0,1) -and @($v.Templates | Where-Object {(-not $_.OriginalExists -and -not $_.DisabledExists) -or ($_.OriginalExists -and $_.DisabledExists)}).Count -eq 0)
                $vendor.BasicReason=if($vendor.BasicSupported){'版本、开关与模板路径符合已适配规则'}else{'版本、模板或开关不符合已验证规则'}
            } catch {$vendor.BasicReason="$($_.Exception.Message)"}
            try {
                Import-Module (Join-Path $PSScriptRoot 'CustomPlanPatch.psm1') -Force
                $p=Get-CustomPlanPatchState
                $vendor.PatchSupported=$p.Supported;$vendor.Patched=$p.Patched;$vendor.PatchReason=if($p.Supported){'插件 SHA256 符合已验证规则'}else{'插件 SHA256 不在适配清单'}
            } catch {$vendor.PatchReason="$($_.Exception.Message)"}
            $state | Add-Member NoteProperty Vendor ([pscustomobject]$vendor)
            $result=@{Success=$true;State=$state}
        }
        Details {
            if($r.PlanGuid -notmatch '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'){throw '无效 GUID'}
            $details=& "$env:SystemRoot\System32\powercfg.exe" /qh $r.PlanGuid 2>&1 | Out-String
            if($LASTEXITCODE -ne 0){throw $details}
            $result=@{Success=$true;Details=$details}
        }
        {$_ -in @('Import','Activate','Export','Delete','Restore')} { $result=Invoke-WindowsPlanOperation $r }
        default {
            Import-Module (Join-Path $PSScriptRoot 'LegionPowerPlans.psm1') -Force
            $patch=Import-Module (Join-Path $PSScriptRoot 'CustomPlanPatch.psm1') -Force -PassThru
            # Only the non-elevated UI restarts the interactive tray. CLI retains its original behaviour.
            & $patch {
                param($Root)
                $script:GuiTrayDirectory=$Root
                $script:TrayStartHandler={
                    param($Context,$Arguments)
                    $id=[guid]::NewGuid().ToString('N')
                    $request=Join-Path $script:GuiTrayDirectory ('tray-'+$id+'.json')
                    $reply=Join-Path $script:GuiTrayDirectory ('tray-'+$id+'.reply')
                    @{Tray=$Context.Tray;Arguments=$Arguments} | ConvertTo-Json | Set-Content -LiteralPath ($request+'.tmp') -Encoding UTF8
                    Move-Item -LiteralPath ($request+'.tmp') -Destination $request
                    $end=(Get-Date).AddSeconds(40)
                    while(-not(Test-Path -LiteralPath $reply)){
                        if((Get-Date) -gt $end){throw '普通权限界面未响应托盘重启请求。'}
                        Start-Sleep -Milliseconds 200
                    }
                    $answer=Get-Content -LiteralPath $reply -Raw | ConvertFrom-Json
                    if(-not $answer.Success){throw "托盘重启失败：$($answer.Message)"}
                }
            } (Split-Path $ResponsePath -Parent)
            if($r.Action -eq 'VendorDisable'){ $message=Disable-LegionPlans -BackupDirectory $r.BackupDirectory | Out-String }
            elseif($r.Action -eq 'PatchApply'){ $message=Install-CustomPlanPatch -BackupDirectory $r.BackupDirectory | Out-String }
            else {
                $m=Get-Content -LiteralPath (Join-Path $r.BackupDirectory 'manifest.json') -Raw | ConvertFrom-Json
                if($m.SchemaVersion -ne 1){throw '该备份不是项目支持的旧格式，请使用原配套恢复脚本。'}
                if($m.PSObject.Properties.Name -contains 'Kind' -and $m.Kind -eq 'CustomPlanBranchPatch'){$message=Restore-CustomPlanPatch -BackupDirectory $r.BackupDirectory | Out-String}
                elseif($m.PSObject.Properties.Name -contains 'InstallRoot'){$message=Restore-LegionPlans -BackupDirectory $r.BackupDirectory | Out-String}
                else {throw '桌面早期备份请使用它自带的 restore.ps1。'}
            }
            $result=@{Success=$true;Message=$message;BackupDirectory=$r.BackupDirectory}
        }
    }
} catch { $result=@{Success=$false;Message=$_.Exception.Message;BackupDirectory=if($r){$r.BackupDirectory}else{''}} }
[IO.File]::WriteAllText($ResponsePath,($result | ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
