param()
$ErrorActionPreference = 'Stop'
# 第三方二进制留在忽略的build/deps。URL/版本/大小/hash来自本课固定清单，
# 避免“latest”变化悄悄改变验收结果；升级必须同时更新API契约和实测证据。
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'sdk_manifest.json') -Raw | ConvertFrom-Json
$deps = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'build/deps'))
New-Item -ItemType Directory -Force $deps | Out-Null
foreach ($package in $manifest.packages) {
    $archive = Join-Path $deps ($package.name + '.zip')
    $destination = Join-Path $deps $package.name
    if (!(Test-Path -LiteralPath $archive)) {
        $partial = $archive + '.partial'
        & curl.exe --fail --location --retry 2 --max-time 600 --output $partial $package.url
        if ($LASTEXITCODE -ne 0) { throw "下载失败：$($package.name)" }
        $received = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($received -ne $package.sha256) { throw "SHA256不一致，保留partial供排查：$($package.name)" }
        Move-Item -LiteralPath $partial -Destination $archive
    }
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $package.sha256) { throw "已有压缩包SHA256不一致，请核查后重新下载：$archive" }
    if (!(Test-Path -LiteralPath $destination)) {
        # ZIP的目录结构由固定hash约束；使用Python标准库避免Windows长路径/Expand-Archive性能问题。
        & python -m zipfile -e $archive $destination
        if ($LASTEXITCODE -ne 0) { throw "解压失败：$($package.name)" }
    }
    Write-Host "$($package.name) $($package.version): SHA256 verified"
}
