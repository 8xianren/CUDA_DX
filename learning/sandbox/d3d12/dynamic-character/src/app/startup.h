#pragma once
#include <filesystem>

namespace character {
// 启动配置属于应用装配层；资产/仿真/渲染模块只接收已解析的路径和数值，
// 不自行读取 JSON，也不依赖进程的当前工作目录。
struct StartupOptions {
    std::filesystem::path assets, shaders, energy, output;
    unsigned width = 1280, height = 720, verificationFrames = 0;
    unsigned movingSpp=4,pausedSpp=16,maxScatters=6;
    bool presentation=true;float skyIntensity=1;
};
std::filesystem::path ExecutableDirectory();
StartupOptions LoadStartupOptions(int argc, char** argv);
// 双击启动没有可保留的终端；失败时弹窗并尽力在 EXE 旁写错误日志。
void ReportStartupError(const char* message, bool showDialog) noexcept;
}
