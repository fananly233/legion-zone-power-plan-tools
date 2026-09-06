#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($file in Get-ChildItem $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') }) {
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors) | Out-Null
    if ($errors) { throw ($errors | Out-String) }
}
$module = Import-Module (Join-Path $root 'src\LegionPowerPlans.psm1') -Force -PassThru
$temp = Join-Path ([IO.Path]::GetTempPath()) ('legion-power-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    & $module {
        param($TempRoot)
        # Replace every OS-facing dependency inside this module only.
        function script:Get-LegionContext { $script:Fake.Context }
        function script:Get-PlanIds { @($script:Fake.Ids) }
        function script:Get-ActivePlan { $script:Fake.Active }
        function script:Get-PerformanceSwitch($Context) { $script:Fake.Switch }
        function script:Set-PerformanceSwitch($Context, [int]$Value) {
            if (-not (Test-Path -LiteralPath (Join-Path $script:Fake.Backup 'manifest.json'))) { throw 'Mutation before manifest.' }
            $script:Fake.Switch = $Value
            $script:Fake.Mutations++
        }
        function script:Invoke-PowerCfg([string[]]$Arguments) {
            switch ($Arguments[0]) {
                '/export' {
                    if ($script:Fake.FailExport) { throw 'Simulated export failure.' }
                    [IO.File]::WriteAllText($Arguments[1], 'fixture-plan-'+$Arguments[2])
                }
                '/setactive' { $script:Fake.Active=$Arguments[1]; $script:Fake.Mutations++ }
                '/delete' {
                    if ($script:Fake.FailDelete -and $script:Fake.Deletes -eq 1) { throw 'Simulated partial delete failure.' }
                    $script:Fake.Ids=@($script:Fake.Ids | Where-Object { $_ -ne $Arguments[1] })
                    $script:Fake.Deletes++
                    $script:Fake.Mutations++
                }
                '/import' { $script:Fake.Ids+=@($Arguments[2]); $script:Fake.Mutations++ }
                default { throw 'Unmocked powercfg operation.' }
            }
        }
        function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
        function Assert-Throws([scriptblock]$Body, [string]$Expected) {
            $caught = $null
            try { & $Body | Out-Null } catch { $caught = $_ }
            Assert ($null -ne $caught -and $caught.ToString() -like "*$Expected*") "Expected error: $Expected; got: $caught"
        }
        function New-Fixture {
            $caseRoot=Join-Path $TempRoot ([guid]::NewGuid().ToString('N'))
            $install=Join-Path $caseRoot 'install'
            New-Item -ItemType Directory -Path $install | Out-Null
            foreach ($relative in $script:TemplatePaths) {
                $file=Join-Path $install $relative
                New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force | Out-Null
                [IO.File]::WriteAllText($file, 'fixture-template-'+$relative)
            }
            $script:Fake=@{
                Context=[pscustomobject]@{ Root=$install; Version=$script:Version; RegistryPath='MOCK_ONLY' }
                Backup=(Join-Path $caseRoot 'backup'); Ids=@($script:PlanIds)+@($script:Balanced)
                Active=$script:PlanIds[2]; Switch=1; Mutations=0; Deletes=0; FailExport=$false; FailDelete=$false
            }
        }
        New-Fixture
        $originalActive=$script:Fake.Active
        Disable-LegionPlans $script:Fake.Backup | Out-Null
        Assert ($script:Fake.Ids.Count -eq 1 -and $script:Fake.Active -eq $script:Balanced) 'Disable did not retain Balanced.'
        $m=Read-ValidatedBackup $script:Fake.Backup $script:Fake.Context
        Assert (@($m.Plans).Count -eq 4) 'Missing plan backups.'
        Restore-LegionPlans $script:Fake.Backup | Out-Null
        Assert ($script:Fake.Ids.Count -eq 5 -and $script:Fake.Active -eq $originalActive -and $script:Fake.Switch -eq 1) 'Restore state mismatch.'
        foreach ($t in $script:TemplatePaths) { Assert (Test-Path (Join-Path $script:Fake.Context.Root $t)) 'Template not restored.' }
        'PASS: disable and restore round trip'

        New-Fixture
        $script:Fake.Active=$script:Balanced
        Disable-LegionPlans $script:Fake.Backup | Out-Null
        Assert ($script:Fake.Active -eq $script:Balanced) 'Non-Lenovo active plan changed.'
        $mutations=$script:Fake.Mutations
        $another=Join-Path (Split-Path $script:Fake.Backup -Parent) 'another'
        Disable-LegionPlans $another | Out-Null
        Assert ($script:Fake.Mutations -eq $mutations -and -not (Test-Path $another)) 'Repeated Disable is not a no-op.'
        'PASS: preserve active non-Lenovo plan and repeated Disable'

        New-Fixture
        $script:Fake.FailExport=$true
        Assert-Throws { Disable-LegionPlans $script:Fake.Backup } 'Simulated export failure'
        Assert ($script:Fake.Mutations -eq 0) 'Mutation occurred after backup export failure.'
        foreach ($t in $script:TemplatePaths) { Assert (Test-Path (Join-Path $script:Fake.Context.Root $t)) 'Template moved before complete backup.' }
        'PASS: backup failure prevents system mutations'

        New-Fixture
        $script:Fake.FailDelete=$true
        Assert-Throws { Disable-LegionPlans $script:Fake.Backup } 'Simulated partial delete failure'
        Assert ($script:Fake.Deletes -eq 1) 'Partial-failure fixture did not run.'
        $script:Fake.FailDelete=$false
        Restore-LegionPlans $script:Fake.Backup | Out-Null
        Assert ($script:Fake.Ids.Count -eq 5 -and $script:Fake.Switch -eq 1) 'Partial failure cannot be restored.'
        'PASS: recover after partial plan deletion'

        New-Fixture
        Disable-LegionPlans $script:Fake.Backup | Out-Null
        $mutations=$script:Fake.Mutations
        [IO.File]::WriteAllText((Join-Path $script:Fake.Backup ($script:PlanIds[0]+'.pow')), 'tampered')
        Assert-Throws { Restore-LegionPlans $script:Fake.Backup } 'Backup hash mismatch'
        Assert ($script:Fake.Mutations -eq $mutations) 'Corrupt backup caused mutation.'
        'PASS: corrupted backup rejected before restore'

        New-Fixture
        Disable-LegionPlans $script:Fake.Backup | Out-Null
        $manifestPath=Join-Path $script:Fake.Backup 'manifest.json'
        $m=Get-Content $manifestPath -Raw | ConvertFrom-Json
        $m.Templates[0].RelativePath='..\outside.pow'
        $m | ConvertTo-Json -Depth 6 | Set-Content $manifestPath -Encoding UTF8
        $mutations=$script:Fake.Mutations
        Assert-Throws { Restore-LegionPlans $script:Fake.Backup } 'Unexpected or duplicate template path'
        Assert ($script:Fake.Mutations -eq $mutations) 'Unexpected path caused mutation.'
        'PASS: unexpected manifest path rejected'

        New-Fixture
        Disable-LegionPlans $script:Fake.Backup | Out-Null
        $changed=(Join-Path $script:Fake.Context.Root $script:TemplatePaths[0])+'.disabled-by-user'
        [IO.File]::WriteAllText($changed, 'new-version-template')
        $mutations=$script:Fake.Mutations
        Assert-Throws { Restore-LegionPlans $script:Fake.Backup } 'Template changed since backup'
        Assert ($script:Fake.Mutations -eq $mutations) 'Template conflict caused mutation.'
        'PASS: changed installation template rejected'

        New-Fixture
        $script:Fake.Context.Version='0.0.0.0'
        Assert-Throws { Disable-LegionPlans $script:Fake.Backup } 'Unsupported Legion Zone version'
        Assert ($script:Fake.Mutations -eq 0 -and -not (Test-Path $script:Fake.Backup)) 'Unsupported version wrote files.'
        'PASS: unsupported version rejected before writes'

        New-Fixture
        $script:Fake.Ids=@($script:PlanIds[2],$script:Balanced)
        $script:Fake.Switch=0
        $alreadyDisabled=Join-Path $script:Fake.Context.Root $script:TemplatePaths[0]
        Rename-Item -LiteralPath $alreadyDisabled -NewName ([IO.Path]::GetFileName($alreadyDisabled)+'.disabled-by-user')
        Disable-LegionPlans $script:Fake.Backup | Out-Null
        Restore-LegionPlans $script:Fake.Backup | Out-Null
        Assert ($script:Fake.Ids.Count -eq 2 -and $script:Fake.Switch -eq 0) 'Partial initial state was not preserved.'
        Assert (-not (Test-Path $alreadyDisabled) -and (Test-Path ($alreadyDisabled+'.disabled-by-user'))) 'Originally disabled template became enabled.'
        'PASS: preserve initially missing plans and disabled templates'

        New-Fixture
        Disable-LegionPlans $script:Fake.Backup | Out-Null
        $moved=Join-Path (Split-Path $script:Fake.Backup -Parent) 'relocated-backup'
        Rename-Item -LiteralPath $script:Fake.Backup -NewName 'relocated-backup'
        $script:Fake.Backup=$moved
        Restore-LegionPlans $moved | Out-Null
        Assert ($script:Fake.Ids.Count -eq 5) 'Moved backup did not restore.'
        'PASS: restore from relocated backup directory'

        New-Fixture
        New-Item -ItemType Directory -Path $script:Fake.Backup | Out-Null
        Assert-Throws { Disable-LegionPlans $script:Fake.Backup } 'Backup directory already exists'
        Assert ($script:Fake.Mutations -eq 0) 'Existing backup was overwritten.'
        'PASS: existing backup directory protected'
    } $temp
} finally {
    Remove-Module $module.Name -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($temp)
    $tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('legion-power-tests-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
'All isolated tests passed; no real power plans or registry settings were changed.'
