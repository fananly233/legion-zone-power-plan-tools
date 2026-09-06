#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:OriginalHash = '2683C4A52808468854D20631B16CEBD74B6DBCDDEF8D39D75C12EDCB97E7CDCB'
$script:PatchedHash = 'E27CB2AC82BE579A419B17FD490121CC63F301AB7A8CC95ED077F486D7E1817C'
$script:PatchOffset = 0xF675F
$script:CustomGuid = '587d380f-60e4-8729-8b42-b40f65eae0ff'
$script:FallbackGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
function Get-BytesHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','') } finally { $sha.Dispose() }
}
function ConvertTo-CustomPlanPatch([byte[]]$Bytes) {
    if ((Get-BytesHash $Bytes) -ne $script:OriginalHash) { throw 'Unrecognized DLL hash; no bytes changed.' }
    $expected = [byte[]]@(0x0f,0x85,0x05,0x01,0x00,0x00)
    for ($i=0; $i -lt $expected.Length; $i++) {
        if ($Bytes[$script:PatchOffset+$i] -ne $expected[$i]) { throw 'Unexpected branch bytes; no patch applied.' }
    }
    $result = [byte[]]$Bytes.Clone()
    # JNE rel32 -> NOP; JMP rel32. Both end at the same address and target RVA 0xF746A.
    $result[$script:PatchOffset] = 0x90
    $result[$script:PatchOffset+1] = 0xe9
    if ((Get-BytesHash $result) -ne $script:PatchedHash) { throw 'Patched DLL hash mismatch.' }
    return ,$result
}
function Get-CustomPlanPatchContext {
    $installed = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Lenovo\LegionZone'
    if ($installed.Version -ne '2.0.28.8182') { throw 'Only Legion Zone 2.0.28.8182 is supported.' }
    $directory = Join-Path $installed.InstallDir $installed.Version
    [pscustomobject]@{ Dll=(Join-Path $directory 'LZTrayPlugin.dll'); Tray=(Join-Path $directory 'LZTray.exe'); Version=$installed.Version }
}
function Get-CustomPlanPatchState {
    $context = Get-CustomPlanPatchContext
    $hash = (Get-FileHash -LiteralPath $context.Dll).Hash
    [pscustomobject]@{ Dll=$context.Dll; Version=$context.Version; SHA256=$hash; Patched=($hash -eq $script:PatchedHash); Supported=($hash -in @($script:OriginalHash,$script:PatchedHash)) }
}
function Invoke-CheckedPowerCfg([string[]]$Arguments) {
    $output = & "$env:SystemRoot\System32\powercfg.exe" @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "powercfg failed: $output" }
    $output
}
function Get-ExactTrayProcesses($Context) {
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='LZTray.exe'")
    foreach ($p in $processes) {
        if ($p.ExecutablePath -ine $Context.Tray) { throw 'Cannot verify running tray path; stopping before changes.' }
    }
    if ($processes.Count -gt 1) { throw 'Multiple tray processes found; close duplicates first.' }
    $processes
}
function Get-TrayArguments($Process, $Context) {
    $command = $Process.CommandLine
    if ($command.StartsWith('"'+$Context.Tray+'"',[StringComparison]::OrdinalIgnoreCase)) { return $command.Substring($Context.Tray.Length+2).Trim() }
    if ($command.StartsWith($Context.Tray,[StringComparison]::OrdinalIgnoreCase)) { return $command.Substring($Context.Tray.Length).Trim() }
    throw 'Unexpected tray command line.'
}
function Start-VerifiedTray($Context, [string]$Arguments) {
    $existing = @(Get-ExactTrayProcesses $Context)
    if (-not $existing.Count) {
        if ($Arguments) { Start-Process -FilePath $Context.Tray -ArgumentList $Arguments -WindowStyle Hidden }
        else { Start-Process -FilePath $Context.Tray -WindowStyle Hidden }
    }
}
function Assert-TrayLoaded($Context) {
    $deadline = (Get-Date).AddSeconds(15)
    do {
        foreach ($p in @(Get-ExactTrayProcesses $Context)) {
            $loaded = @((Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue).Modules | Where-Object { $_.FileName -ieq $Context.Dll })
            if ($loaded.Count) { return }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw 'Tray did not load the target DLL; restoring the original file.'
}
function Stop-VerifiedTray($Context) {
    foreach ($p in @(Get-ExactTrayProcesses $Context)) {
        $process = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        try {
            # Keep a process handle so exit and DLL unloading finish before writing/restarting.
            $null = $process.Handle
            Stop-Process -InputObject $process -Force
            if (-not $process.WaitForExit(10000)) { throw 'Tray did not exit within 10 seconds.' }
        } finally { $process.Dispose() }
    }
}
function Install-CustomPlanPatch([string]$BackupDirectory) {
    $context = Get-CustomPlanPatchContext
    $bytes = [IO.File]::ReadAllBytes($context.Dll)
    if ((Get-BytesHash $bytes) -eq $script:PatchedHash) { Write-Output 'Branch patch already installed; no files changed.'; return }
    $patched = ConvertTo-CustomPlanPatch $bytes
    $processes = @(Get-ExactTrayProcesses $context)
    $arguments = if ($processes.Count) { Get-TrayArguments $processes[0] $context } else { '' }
    $backup = [IO.Path]::GetFullPath($BackupDirectory)
    if (Test-Path -LiteralPath $backup) { throw 'Backup directory already exists; refusing overwrite.' }
    $plans = Invoke-CheckedPowerCfg @('/list') | Out-String
    $active = [regex]::Match((Invoke-CheckedPowerCfg @('/getactivescheme') | Out-String),'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
    if (-not $active) { throw 'Cannot determine active plan.' }
    $hadCustom = $plans -match $script:CustomGuid
    if ($active -eq $script:CustomGuid -and $plans -notmatch $script:FallbackGuid) { throw 'Windows Balanced plan is missing.' }
    New-Item -ItemType Directory -Path $backup | Out-Null
    $savedDll = Join-Path $backup 'LZTrayPlugin.original.dll'
    [IO.File]::WriteAllBytes($savedDll,$bytes)
    if ((Get-FileHash -LiteralPath $savedDll).Hash -ne $script:OriginalHash) { throw 'DLL backup verification failed.' }
    $planHash = $null
    if ($hadCustom) {
        Invoke-CheckedPowerCfg @('/export',(Join-Path $backup 'custom.pow'),$script:CustomGuid) | Out-Null
        $planHash=(Get-FileHash -LiteralPath (Join-Path $backup 'custom.pow')).Hash
    }
    [ordered]@{SchemaVersion=1;Kind='CustomPlanBranchPatch';Version=$context.Version;Dll=$context.Dll;OriginalHash=$script:OriginalHash;PatchedHash=$script:PatchedHash;ActiveGuid=$active;HadCustom=$hadCustom;PlanHash=$planHash;TrayWasRunning=($processes.Count -gt 0);Created=(Get-Date -Format o)} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding UTF8
    $changed=$false
    try {
        Stop-VerifiedTray $context
        # Re-check after stopping the loader, in case the vendor updated the file.
        if ((Get-FileHash -LiteralPath $context.Dll).Hash -ne $script:OriginalHash) { throw 'DLL changed during preparation.' }
        $changed=$true
        [IO.File]::WriteAllBytes($context.Dll,$patched)
        if ((Get-FileHash -LiteralPath $context.Dll).Hash -ne $script:PatchedHash) { throw 'On-disk patch verification failed.' }
        if ($active -eq $script:CustomGuid) { Invoke-CheckedPowerCfg @('/setactive',$script:FallbackGuid) | Out-Null }
        if ($hadCustom) { Invoke-CheckedPowerCfg @('/delete',$script:CustomGuid) | Out-Null }
        Start-VerifiedTray $context $arguments
        Assert-TrayLoaded $context
        Start-Sleep -Seconds 12
        if ((Invoke-CheckedPowerCfg @('/list') | Out-String) -match $script:CustomGuid) { throw 'Custom plan returned; patch did not cover this trigger.' }
        $expectedActive = if ($active -eq $script:CustomGuid) { $script:FallbackGuid } else { $active }
        if ((Invoke-CheckedPowerCfg @('/getactivescheme') | Out-String) -notmatch $expectedActive) { throw 'Unexpected active plan change.' }
        if (-not $processes.Count) { Stop-VerifiedTray $context }
        'Patched, target DLL loaded by tray, custom plan absent after initialization and 12 seconds.' | Set-Content -LiteralPath (Join-Path $backup 'result.txt')
        Write-Output "Applied. Backup: $backup"
    } catch {
        $failure=$_
        if ($changed) {
            Stop-VerifiedTray $context
            [IO.File]::WriteAllBytes($context.Dll,$bytes)
            if ($hadCustom -and (Invoke-CheckedPowerCfg @('/list') | Out-String) -notmatch $script:CustomGuid) { Invoke-CheckedPowerCfg @('/import',(Join-Path $backup 'custom.pow'),$script:CustomGuid) | Out-Null }
            Invoke-CheckedPowerCfg @('/setactive',$active) | Out-Null
        }
        if ($processes.Count) { Start-VerifiedTray $context $arguments }
        $failure | Out-String | Set-Content -LiteralPath (Join-Path $backup 'error.txt')
        throw $failure
    }
}
function Restore-CustomPlanPatch([string]$BackupDirectory) {
    $context=Get-CustomPlanPatchContext
    $backup=(Resolve-Path -LiteralPath $BackupDirectory).Path
    $m=Get-Content -LiteralPath (Join-Path $backup 'manifest.json') -Raw | ConvertFrom-Json
    if ($m.Kind -ne 'CustomPlanBranchPatch' -or $m.SchemaVersion -ne 1 -or $m.Version -ne $context.Version -or $m.Dll -ine $context.Dll -or $m.HadCustom -isnot [bool]) { throw 'Wrong patch backup.' }
    $saved=Join-Path $backup 'LZTrayPlugin.original.dll'
    if ((Get-FileHash -LiteralPath $saved).Hash -ne $script:OriginalHash) { throw 'Original DLL backup hash mismatch.' }
    if ((Get-FileHash -LiteralPath $context.Dll).Hash -notin @($script:OriginalHash,$script:PatchedHash)) { throw 'Current DLL changed; restore will not overwrite it.' }
    if ($m.ActiveGuid -notmatch '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw 'Invalid original active GUID.' }
    $listing=Invoke-CheckedPowerCfg @('/list') | Out-String
    if ($listing -notmatch $m.ActiveGuid -and -not ($m.HadCustom -and $m.ActiveGuid -eq $script:CustomGuid)) { throw 'Original active plan is unavailable.' }
    if ($m.HadCustom -and (Get-FileHash -LiteralPath (Join-Path $backup 'custom.pow')).Hash -ne $m.PlanHash) { throw 'Power plan backup hash mismatch.' }
    $processes=@(Get-ExactTrayProcesses $context)
    $arguments=if ($processes.Count) { Get-TrayArguments $processes[0] $context } else { '' }
    Stop-VerifiedTray $context
    try {
        [IO.File]::WriteAllBytes($context.Dll,[IO.File]::ReadAllBytes($saved))
        if ((Get-FileHash -LiteralPath $context.Dll).Hash -ne $script:OriginalHash) { throw 'Restored DLL hash mismatch.' }
        if ($m.HadCustom -and $listing -notmatch $script:CustomGuid) { Invoke-CheckedPowerCfg @('/import',(Join-Path $backup 'custom.pow'),$script:CustomGuid) | Out-Null }
        Invoke-CheckedPowerCfg @('/setactive',$m.ActiveGuid) | Out-Null
        'Original signed DLL and original active plan restored.' | Set-Content -LiteralPath (Join-Path $backup 'restore-result.txt')
    } finally { if ($processes.Count) { Start-VerifiedTray $context $arguments } }
}
Export-ModuleMember -Function Get-CustomPlanPatchState, Install-CustomPlanPatch, Restore-CustomPlanPatch
