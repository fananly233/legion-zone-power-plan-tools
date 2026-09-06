#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Version = '2.0.28.8182'
$script:Balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
$script:PlanIds = @(
    '16edbccd-dee9-4ec4-ace5-2f0b5f2a8975',
    '85d583c5-cf2e-4197-80fd-3789a227a72c',
    '52521609-efc9-4268-b9ba-67dea73f18b2',
    '587d380f-60e4-8729-8b42-b40f65eae0ff'
)
$script:TemplatePaths = @(
    "$script:Version\config\X80_PowerPlan\Balance_Mode.pow",
    "$script:Version\config\X80_PowerPlan\Performance_Mode.pow",
    "$script:Version\config\X80_PowerPlan\Quiet_Mode.pow",
    'config\SYS_SCHEME_BALANCE.pow'
)
function Get-LegionContext {
    $key = 'HKLM:\SOFTWARE\WOW6432Node\Lenovo\LegionZone'
    $installed = Get-ItemProperty -LiteralPath $key
    [pscustomobject]@{
        Root = [IO.Path]::GetFullPath($installed.InstallDir).TrimEnd('\')
        Version = $installed.Version
        RegistryPath = "$key\config"
    }
}
function Assert-Compatible($Context) {
    if ($Context.Version -ne $script:Version) { throw "Unsupported Legion Zone version: $($Context.Version). Tested profile: $script:Version" }
    if (-not (Test-Path -LiteralPath $Context.Root -PathType Container)) { throw 'Legion Zone installation not found.' }
}
function Invoke-PowerCfg([string[]]$Arguments) {
    $result = & "$env:SystemRoot\System32\powercfg.exe" @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "powercfg $Arguments failed: $result" }
    $result
}
function Get-PlanIds {
    @([regex]::Matches((Invoke-PowerCfg @('/list') | Out-String), '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value.ToLowerInvariant() })
}
function Get-ActivePlan {
    $id = [regex]::Match((Invoke-PowerCfg @('/getactivescheme') | Out-String), '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
    if (-not $id) { throw 'Cannot read active power plan.' }
    $id.ToLowerInvariant()
}
function Get-PerformanceSwitch($Context) {
    # Fail before changes if this installation does not expose the expected DWORD.
    $key = Get-Item -LiteralPath $Context.RegistryPath
    if ($key.GetValueKind('PerformanceSwitch') -ne 'DWord') { throw 'Unexpected PerformanceSwitch type.' }
    [int]$key.GetValue('PerformanceSwitch')
}
function Set-PerformanceSwitch($Context, [int]$Value) {
    Set-ItemProperty -LiteralPath $Context.RegistryPath -Name PerformanceSwitch -Value $Value
}
function Get-LegionState {
    $context = Get-LegionContext
    $ids = @(Get-PlanIds)
    [pscustomobject]@{
        InstalledVersion = $context.Version
        SupportedVersion = $script:Version
        ActivePlan = Get-ActivePlan
        PerformanceSwitch = Get-PerformanceSwitch $context
        LenovoPlansPresent = @($script:PlanIds | Where-Object { $_ -in $ids })
        Templates = @($script:TemplatePaths | ForEach-Object {
            $path = Join-Path $context.Root $_
            [pscustomobject]@{ RelativePath=$_; OriginalExists=(Test-Path -LiteralPath $path); DisabledExists=(Test-Path -LiteralPath ($path+'.disabled-by-user')) }
        })
    }
}
function Disable-LegionPlans {
    param([Parameter(Mandatory)][string]$BackupDirectory)
    $context = Get-LegionContext
    Assert-Compatible $context
    $ids = @(Get-PlanIds)
    $present = @($script:PlanIds | Where-Object { $_ -in $ids })
    $active = Get-ActivePlan
    $switch = Get-PerformanceSwitch $context
    if ($switch -notin @(0,1)) { throw 'Unexpected PerformanceSwitch value; expected 0 or 1.' }
    if ($active -in $present -and $script:Balanced -notin $ids) { throw 'Windows Balanced plan is required before removing the active Lenovo plan.' }
    $templates = @($script:TemplatePaths | ForEach-Object {
        $source = Join-Path $context.Root $_
        $disabled = $source+'.disabled-by-user'
        $exists = Test-Path -LiteralPath $source -PathType Leaf
        if ($exists -and (Test-Path -LiteralPath $disabled)) { throw "Conflicting template and disabled file: $source" }
        if (-not $exists -and -not (Test-Path -LiteralPath $disabled -PathType Leaf)) { throw "Missing template and disabled copy: $source" }
        $readPath = if ($exists) { $source } else { $disabled }
        [pscustomobject]@{ RelativePath=$_; OriginallyEnabled=$exists; File=('template-'+[IO.Path]::GetFileName($source)); SHA256=(Get-FileHash -LiteralPath $readPath).Hash }
    })
    if ($present.Count -eq 0 -and $switch -eq 0 -and @($templates | Where-Object OriginallyEnabled).Count -eq 0) {
        Write-Output 'Already disabled; no changes or new backup required.'
        return
    }
    $backup = [IO.Path]::GetFullPath($BackupDirectory)
    if (Test-Path -LiteralPath $backup) { throw 'Backup directory already exists; refusing to overwrite.' }
    New-Item -ItemType Directory -Path $backup | Out-Null
    try {
        $plans = @($present | ForEach-Object {
            $file = "$_.pow"
            Invoke-PowerCfg @('/export', (Join-Path $backup $file), $_) | Out-Null
            [pscustomobject]@{ Guid=$_; File=$file; SHA256=(Get-FileHash -LiteralPath (Join-Path $backup $file)).Hash }
        })
        foreach ($t in $templates) {
            $source = Join-Path $context.Root $t.RelativePath
            if (-not $t.OriginallyEnabled) { $source += '.disabled-by-user' }
            $target = Join-Path $backup $t.File
            Copy-Item -LiteralPath $source -Destination $target
            if ((Get-FileHash -LiteralPath $target).Hash -ne $t.SHA256) { throw 'Template backup mismatch.' }
        }
        $manifest = [ordered]@{ SchemaVersion=1; Created=(Get-Date -Format o); InstallRoot=$context.Root; Version=$context.Version; ActiveGuid=$active; PerformanceSwitch=$switch; Plans=$plans; Templates=$templates }
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding UTF8
        # The complete backup and manifest must exist before the first system mutation.
        Set-PerformanceSwitch $context 0
        foreach ($t in $templates) {
            if ($t.OriginallyEnabled) {
                $source = Join-Path $context.Root $t.RelativePath
                Rename-Item -LiteralPath $source -NewName ([IO.Path]::GetFileName($source)+'.disabled-by-user')
            }
        }
        if ($active -in $present) { Invoke-PowerCfg @('/setactive', $script:Balanced) | Out-Null }
        foreach ($id in $present) { Invoke-PowerCfg @('/delete', $id) | Out-Null }
        if (@(Get-PlanIds | Where-Object { $_ -in $script:PlanIds }).Count) { throw 'A Lenovo plan remains or was recreated.' }
        if ((Get-PerformanceSwitch $context) -ne 0) { throw 'PerformanceSwitch verification failed.' }
        foreach ($t in $templates) {
            $source = Join-Path $context.Root $t.RelativePath
            if ((Test-Path -LiteralPath $source) -or (Get-FileHash -LiteralPath ($source+'.disabled-by-user')).Hash -ne $t.SHA256) { throw 'Template verification failed.' }
        }
        'Disable completed.' | Set-Content -LiteralPath (Join-Path $backup 'result.txt')
        Write-Output "Disabled. Backup: $backup"
    } catch {
        $_ | Out-String | Set-Content -LiteralPath (Join-Path $backup 'error.txt')
        throw "Operation stopped. Inspect the backup directory; if manifest.json exists, Restore can reverse completed changes. Details: $_"
    }
}
function Read-ValidatedBackup($BackupDirectory, $Context) {
    $backup = (Resolve-Path -LiteralPath $BackupDirectory).Path
    $m = Get-Content -LiteralPath (Join-Path $backup 'manifest.json') -Raw | ConvertFrom-Json
    if ($m.SchemaVersion -ne 1 -or $m.Version -ne $Context.Version -or $m.InstallRoot -ne $Context.Root) { throw 'Backup schema, installation path or version mismatch.' }
    if ($m.ActiveGuid -notmatch '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -or $m.PerformanceSwitch -notin @(0,1)) { throw 'Invalid backup settings.' }
    $seen = @{}
    foreach ($p in $m.Plans) {
        if ($p.Guid -notin $script:PlanIds -or $p.File -cne ($p.Guid+'.pow') -or $seen.ContainsKey($p.Guid)) { throw 'Unexpected or duplicate power plan in backup.' }
        $seen[$p.Guid] = $true
    }
    if (@($m.Templates).Count -ne $script:TemplatePaths.Count) { throw 'Incomplete template manifest.' }
    $seen = @{}
    foreach ($t in $m.Templates) {
        if ($t.RelativePath -notin $script:TemplatePaths -or $seen.ContainsKey($t.RelativePath) -or $t.OriginallyEnabled -isnot [bool]) { throw 'Unexpected or duplicate template path.' }
        if ($t.File -cne ('template-'+[IO.Path]::GetFileName($t.RelativePath))) { throw 'Invalid template backup filename.' }
        $seen[$t.RelativePath] = $true
    }
    foreach ($entry in @($m.Plans)+@($m.Templates)) {
        if ((Get-FileHash -LiteralPath (Join-Path $backup $entry.File)).Hash -ne $entry.SHA256) { throw "Backup hash mismatch: $($entry.File)" }
    }
    $m
}
function Restore-LegionPlans {
    param([Parameter(Mandatory)][string]$BackupDirectory)
    $context = Get-LegionContext
    Assert-Compatible $context
    $backup = (Resolve-Path -LiteralPath $BackupDirectory).Path
    $m = Read-ValidatedBackup $backup $context
    $ids = @(Get-PlanIds)
    if ($m.ActiveGuid -notin $ids -and $m.ActiveGuid -notin @($m.Plans | ForEach-Object Guid)) { throw 'Original active plan is unavailable.' }
    # Reject changed template contents before any restore writes.
    foreach ($t in $m.Templates) {
        $source = Join-Path $context.Root $t.RelativePath
        if ((Test-Path -LiteralPath $source) -and (Test-Path -LiteralPath ($source+'.disabled-by-user'))) { throw 'Both original and disabled templates exist; resolve the conflict first.' }
        foreach ($path in @($source, ($source+'.disabled-by-user'))) {
            if ((Test-Path -LiteralPath $path) -and (Get-FileHash -LiteralPath $path).Hash -ne $t.SHA256) { throw "Template changed since backup: $path" }
        }
        if (-not $t.OriginallyEnabled -and (Test-Path -LiteralPath $source)) { throw 'Originally disabled template has since been enabled; resolve this conflict first.' }
    }
    foreach ($t in $m.Templates) {
        $source = Join-Path $context.Root $t.RelativePath
        $disabled = $source+'.disabled-by-user'
        if ($t.OriginallyEnabled) {
            if (-not (Test-Path -LiteralPath $source)) {
                if (Test-Path -LiteralPath $disabled) { Rename-Item -LiteralPath $disabled -NewName ([IO.Path]::GetFileName($source)) }
                else { Copy-Item -LiteralPath (Join-Path $backup $t.File) -Destination $source }
            }
        } elseif (-not (Test-Path -LiteralPath $disabled)) { Copy-Item -LiteralPath (Join-Path $backup $t.File) -Destination $disabled }
    }
    foreach ($p in $m.Plans) {
        if ($p.Guid -notin $ids) { Invoke-PowerCfg @('/import', (Join-Path $backup $p.File), $p.Guid) | Out-Null }
    }
    Set-PerformanceSwitch $context ([int]$m.PerformanceSwitch)
    Invoke-PowerCfg @('/setactive', $m.ActiveGuid) | Out-Null
    $restoredIds = @(Get-PlanIds)
    if (@($m.Plans | Where-Object { $_.Guid -notin $restoredIds }).Count -or (Get-ActivePlan) -ne $m.ActiveGuid -or (Get-PerformanceSwitch $context) -ne $m.PerformanceSwitch) { throw 'Restore verification failed.' }
    foreach ($t in $m.Templates) {
        $path = Join-Path $context.Root $t.RelativePath
        if (-not $t.OriginallyEnabled) { $path += '.disabled-by-user' }
        if ((Get-FileHash -LiteralPath $path).Hash -ne $t.SHA256) { throw 'Restored template verification failed.' }
    }
    'Restore completed; existing same-GUID plans were preserved.' | Set-Content -LiteralPath (Join-Path $backup 'restore-result.txt')
    Write-Output 'Restored. Existing same-GUID plans were not overwritten.'
}
Export-ModuleMember -Function Get-LegionState, Disable-LegionPlans, Restore-LegionPlans
