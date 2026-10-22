param([string]$Python = "C:/Users/TU/AppData/Local/Programs/Python/Python313/python.exe")
$ErrorActionPreference = 'Stop'
$course = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$venvPython = Join-Path $course '.venv/Scripts/python.exe'
if (-not (Test-Path -LiteralPath $venvPython)) {
    & $Python -m venv (Join-Path $course '.venv')
    if ($LASTEXITCODE -ne 0) { throw '创建本课 Python 虚拟环境失败' }
}
# CUDA13.0官方wheel包含sm_120；不使用Windows默认CPU包冒充CUDA验收。
& $venvPython -m pip install 'torch==2.14.1+cu130' --index-url https://download.pytorch.org/whl/cu130
if ($LASTEXITCODE -ne 0) { throw '安装官方 PyTorch CUDA wheel 失败' }
& $venvPython -m pip install 'numpy==2.5.4' 'pillow==13.0.0'
if ($LASTEXITCODE -ne 0) { throw '安装 NeRF 辅助依赖失败' }
& $venvPython -c 'import torch; assert torch.cuda.is_available(); assert torch.cuda.get_device_capability()==(12,0); assert "sm_120" in torch.cuda.get_arch_list(); print(torch.__version__,torch.cuda.get_device_name())'
if ($LASTEXITCODE -ne 0) { throw 'PyTorch CUDA/sm_120 环境验证失败' }
