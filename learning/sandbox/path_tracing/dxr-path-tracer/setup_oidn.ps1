$ErrorActionPreference='Stop'
# 固定官方二进制和GitHub release公布的SHA256，解压到本课build，不写系统目录。
$deps=Join-Path $PSScriptRoot 'build/deps'
$archive=Join-Path $deps 'oidn-2.5.0.x64.windows.zip'
$root=Join-Path $deps 'oidn-2.5.0.x64.windows'
New-Item -ItemType Directory -Force $deps | Out-Null
if(!(Test-Path $archive)){
    Invoke-WebRequest -Uri 'https://github.com/RenderKit/oidn/releases/download/v2.5.0/oidn-2.5.0.x64.windows.zip' -OutFile $archive
}
$expected='6ae0474ef7606d68647c1e2c2842832d6af01128ee84a523d30368a91013b707'
if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected){throw 'OIDN archive hash mismatch'}
if(!(Test-Path "$root/include/OpenImageDenoise/oidn.h")){Expand-Archive -LiteralPath $archive -DestinationPath $deps}
Write-Output "OIDN_ROOT=$root"
