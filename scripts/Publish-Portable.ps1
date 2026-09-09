[CmdletBinding()]
param([string]$OutputDirectory=(Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\portable'))
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $OutputDirectory){throw 'Publish directory already exists; use a fresh directory.'}
New-Item -ItemType Directory -Path $OutputDirectory|Out-Null
dotnet publish (Join-Path $repo 'desktop\LegionPowerPlanTools.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false -o $OutputDirectory
if($LASTEXITCODE -ne 0){throw 'Publish failed.'}
$dotnetRoot=Split-Path (Get-Command dotnet).Source -Parent
$notices=Join-Path $OutputDirectory 'runtime-notices'
New-Item -ItemType Directory -Path $notices|Out-Null
foreach($name in @('LICENSE.txt','ThirdPartyNotices.txt')){
    $source=Join-Path $dotnetRoot $name
    if(-not(Test-Path -LiteralPath $source)){throw "Required .NET notice missing: $source"}
    Copy-Item -LiteralPath $source -Destination $notices
}
Copy-Item -LiteralPath (Join-Path $repo 'docs\gui-guide.md') -Destination (Join-Path $OutputDirectory '使用说明.md')
Copy-Item -LiteralPath (Join-Path $repo 'docs\compatibility.md') -Destination (Join-Path $OutputDirectory '适配与验证.md')
Copy-Item -LiteralPath (Join-Path $repo 'THIRD_PARTY_NOTICES.md') -Destination $OutputDirectory
Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination $OutputDirectory
Copy-Item -LiteralPath (Join-Path $repo 'resources\catalog.json') -Destination (Join-Path $OutputDirectory '资源来源.json')
$zip=Join-Path (Split-Path $OutputDirectory -Parent) 'LenovoPowerPlanTools-v0.3.0-win-x64.zip'
if(Test-Path -LiteralPath $zip){throw 'Release archive exists; refusing overwrite.'}
Compress-Archive -Path (Join-Path $OutputDirectory '*') -DestinationPath $zip
$hash=(Get-FileHash -LiteralPath $zip).Hash
"$hash  $([IO.Path]::GetFileName($zip))"|Set-Content -LiteralPath ($zip+'.sha256') -Encoding ASCII
[pscustomobject]@{Zip=$zip;SHA256=$hash}
