#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\CustomPlanPatch.psm1') -Force -PassThru
$temp=Join-Path ([IO.Path]::GetTempPath()) ('legion-patch-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    & $module {
        param($TempRoot)
        function Assert($Value,$Message) { if (-not $Value) { throw $Message } }
        function Expect-Error([scriptblock]$Body,$Message) {
            $errorFound=$null
            try { & $Body | Out-Null } catch { $errorFound=$_ }
            Assert ($errorFound -and $errorFound.ToString().Contains($Message)) "Expected: $Message; got: $errorFound"
        }
        # Synthetic PE-sized buffer, not vendor code. Hash overrides exist only in this test module instance.
        $original=New-Object byte[] ($script:PatchOffset+6)
        ([byte[]]@(0x0f,0x85,0x05,0x01,0x00,0x00)).CopyTo($original,$script:PatchOffset)
        $expected=[byte[]]$original.Clone()
        $expected[$script:PatchOffset]=0x90; $expected[$script:PatchOffset+1]=0xe9
        $script:OriginalHash=Get-BytesHash $original
        $script:PatchedHash=Get-BytesHash $expected
        $actual=ConvertTo-CustomPlanPatch $original
        Assert ((Get-BytesHash $actual) -eq $script:PatchedHash) 'Patch digest mismatch.'
        Assert ($original[$script:PatchOffset] -eq 0x0f) 'Input bytes were modified.'
        $difference=0
        for ($i=0;$i -lt $original.Length;$i++) { if ($original[$i] -ne $actual[$i]) { $difference++ } }
        Assert ($difference -eq 2) 'Patch changed more than two bytes.'
        Assert ([BitConverter]::ToInt32($actual,$script:PatchOffset+2) -eq 0x105) 'Branch target displacement changed.'
        'PASS: two-byte branch patch preserves input and displacement'
        $bad=[byte[]]$original.Clone(); $bad[0]=1
        Expect-Error { ConvertTo-CustomPlanPatch $bad } 'Unrecognized DLL hash'
        $script:OriginalHash=Get-BytesHash $bad
        $bad[$script:PatchOffset]=0
        $script:OriginalHash=Get-BytesHash $bad
        Expect-Error { ConvertTo-CustomPlanPatch $bad } 'Unexpected branch bytes'
        $script:OriginalHash=Get-BytesHash $original
        'PASS: unknown file and mismatched branch bytes rejected'

        function script:Get-CustomPlanPatchContext { $script:Fake.Context }
        function script:Get-ExactTrayProcesses($Context) {
            if ($script:Fake.Running) { [pscustomobject]@{ExecutablePath=$Context.Tray;CommandLine=('"'+$Context.Tray+'"');ProcessId=123} }
        }
        $script:Fake=@{Running=$true;Stopped=$false;Waited=$false;Disposed=$false;Timeout=$false}
        function script:Get-Process {
            param($Id,$ErrorAction)
            $p=[pscustomobject]@{Handle=123}
            $p | Add-Member ScriptMethod WaitForExit { param($Milliseconds)
                if (-not $script:Fake.Stopped -or $Milliseconds -ne 10000) { throw 'Wrong stop/wait order.' }
                $script:Fake.Waited=$true
                return (-not $script:Fake.Timeout)
            }
            $p | Add-Member ScriptMethod Dispose { $script:Fake.Disposed=$true }
            $p
        }
        function script:Stop-Process { param($InputObject,[switch]$Force) $script:Fake.Stopped=$true }
        $trayContext=[pscustomobject]@{Tray='fixture.exe'}
        Stop-VerifiedTray $trayContext
        Assert ($script:Fake.Waited -and $script:Fake.Disposed) 'Stop did not wait and release its handle.'
        $script:Fake.Timeout=$true; $script:Fake.Disposed=$false
        Expect-Error { Stop-VerifiedTray $trayContext } 'Tray did not exit within 10 seconds'
        Assert $script:Fake.Disposed 'Timeout leaked process handle.'
        'PASS: tray termination waits for exit and rejects timeout'
        $script:Fake.Running=$false
        $script:TrayStartHandler={param($Context,$Arguments) $script:Fake['CallbackArguments']=$Arguments}
        Start-VerifiedTray $trayContext '--fixture'
        Assert ($script:Fake.CallbackArguments -eq '--fixture') 'GUI tray restart callback lost arguments.'
        $script:TrayStartHandler=$null
        'PASS: GUI tray restart callback preserves arguments without spawning an elevated tray'
        function script:Stop-VerifiedTray($Context) { $script:Fake.Running=$false }
        function script:Start-VerifiedTray($Context,[string]$Arguments) { $script:Fake.Running=$true }
        function script:Assert-TrayLoaded($Context) { if ($script:Fake.LoadFailure) { throw 'Simulated DLL loading failure.' } }
        function script:Start-Sleep { param($Seconds,$Milliseconds) }
        function script:Invoke-CheckedPowerCfg([string[]]$Arguments) {
            switch ($Arguments[0]) {
                '/list' { $script:FallbackGuid; if ($script:Fake.Custom) { $script:CustomGuid } }
                '/getactivescheme' { $script:Fake.Active }
                '/setactive' { $script:Fake.Active=$Arguments[1] }
                '/export' { [IO.File]::WriteAllText($Arguments[1],'synthetic power plan') }
                '/delete' { $script:Fake.Custom=$false }
                '/import' { if($script:Fake.FailRestoreImport){throw 'Simulated recovery import failure.'}; $script:Fake.Custom=$true }
                default { throw 'Unmocked OS call.' }
            }
        }
        function New-Fixture {
            $case=Join-Path $TempRoot ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $case | Out-Null
            $dll=Join-Path $case 'fixture.dll'
            [IO.File]::WriteAllBytes($dll,$original)
            $script:Fake=@{Context=[pscustomobject]@{Dll=$dll;Tray=(Join-Path $case 'tray.exe');Version='2.0.28.8182'};Backup=(Join-Path $case 'backup');Custom=$true;Active=$script:FallbackGuid;Running=$true;LoadFailure=$false;FailRestoreImport=$false}
        }
        New-Fixture
        Install-CustomPlanPatch $script:Fake.Backup | Out-Null
        Assert (-not $script:Fake.Custom -and $script:Fake.Running) 'Apply failed.'
        Assert ((Get-FileHash $script:Fake.Context.Dll).Hash -eq $script:PatchedHash) 'Installed bytes mismatch.'
        Restore-CustomPlanPatch $script:Fake.Backup | Out-Null
        Assert ($script:Fake.Custom -and $script:Fake.Running -and (Get-FileHash $script:Fake.Context.Dll).Hash -eq $script:OriginalHash) 'Restore failed.'
        'PASS: isolated patch apply and restore round trip'

        New-Fixture
        $script:Fake.LoadFailure=$true
        Expect-Error { Install-CustomPlanPatch $script:Fake.Backup } 'Simulated DLL loading failure'
        Assert ($script:Fake.Custom -and $script:Fake.Running -and (Get-FileHash $script:Fake.Context.Dll).Hash -eq $script:OriginalHash) 'Loading failure did not roll back.'
        'PASS: DLL loading failure restores original bytes and plan'
        New-Fixture
        $script:Fake.LoadFailure=$true;$script:Fake.FailRestoreImport=$true
        Expect-Error {Install-CustomPlanPatch $script:Fake.Backup} 'rollback incomplete'
        $recovery=Get-Content -LiteralPath (Join-Path $script:Fake.Backup 'rollback.json') -Raw|ConvertFrom-Json
        Assert (-not $recovery.Complete -and $recovery.OriginalError -like '*loading failure*' -and $recovery.RollbackErrors.Count -gt 0 -and $script:Fake.Running) 'Recovery failure hid original error or skipped tray restart.'
        'PASS: recovery failure retains original error and attempts remaining steps'

        New-Fixture
        Install-CustomPlanPatch $script:Fake.Backup | Out-Null
        $newBackup=Join-Path (Split-Path $script:Fake.Backup -Parent) 'unused'
        Install-CustomPlanPatch $newBackup | Out-Null
        Assert (-not (Test-Path $newBackup)) 'Repeat patch created unnecessary backup.'
        [IO.File]::WriteAllText((Join-Path $script:Fake.Backup 'LZTrayPlugin.original.dll'),'corrupt')
        Expect-Error { Restore-CustomPlanPatch $script:Fake.Backup } 'Original DLL backup hash mismatch'
        Assert ((Get-FileHash $script:Fake.Context.Dll).Hash -eq $script:PatchedHash) 'Corrupt backup was written to install.'
        'PASS: repeat patch and corrupt-backup protection'
    } $temp
} finally {
    Remove-Module $module.Name -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($temp)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('legion-patch-tests-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
'Patch tests passed using synthetic bytes and mocked processes/power settings.'
