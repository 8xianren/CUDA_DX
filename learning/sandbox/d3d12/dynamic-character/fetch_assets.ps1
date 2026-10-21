# H1：仅获取作者公开提供的免费 Standard 包；不保存临时下载令牌。
# 下载包缓存归本课所有，不上传 Git；源 URL、版本和哈希由 prepare_assets.py 记录。
$ErrorActionPreference='Stop'
$cache=Join-Path $PSScriptRoot 'assets/downloads'
New-Item -ItemType Directory -Force $cache | Out-Null
foreach($slug in @('universal-animation-library','universal-base-characters')) {
    $zip=Join-Path $cache "$slug.zip"
    if(Test-Path -LiteralPath $zip){continue}
    $url="https://quaternius.itch.io/$slug"
    $page=Invoke-WebRequest $url -SessionVariable itchSession
    $csrf=[regex]::Match($page.Content,'name="csrf_token" value="([^"]+)"').Groups[1].Value
    $download=Invoke-RestMethod "$url/download_url" -Method Post -WebSession $itchSession -Body @{csrf_token=$csrf}
    $page=Invoke-WebRequest $download.url -WebSession $itchSession
    $csrf=[regex]::Match($page.Content,'name="csrf_token" value="([^"]+)"').Groups[1].Value
    # 免费下载页面只能看到获准下载的文件；仍检查只有一个 Standard 项，避免网站变化后误选。
    $ids=[regex]::Matches($page.Content,'data-upload_id="(\d+)"')
    if($ids.Count -ne 1 -or $page.Content -notmatch '\[Standard\]'){throw 'Free Standard download layout changed'}
    $file=Invoke-RestMethod "$url/file/$($ids[0].Groups[1].Value)" -Method Post -WebSession $itchSession -Body @{csrf_token=$csrf}
    if(!$file.url){throw 'No authorized download URL'}
    Invoke-WebRequest $file.url -OutFile "$zip.partial"
    Move-Item -LiteralPath "$zip.partial" -Destination $zip
}
$zip=Join-Path $cache 'kenney_nature-kit.zip'
if(!(Test-Path -LiteralPath $zip)){
    Invoke-WebRequest 'https://kenney.nl/media/pages/assets/nature-kit/37ac38a37b-1677698939/kenney_nature-kit.zip' -OutFile "$zip.partial"
    Move-Item -LiteralPath "$zip.partial" -Destination $zip
}
python (Join-Path $PSScriptRoot 'prepare_assets.py')
if($LASTEXITCODE -ne 0){throw 'Asset preparation failed'}
