#include "app/startup.h"
#include <windows.h>
#include <rapidjson/document.h>
#include <rapidjson/error/en.h>
#include <fstream>
#include <iterator>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace character {
namespace {
unsigned PositiveInteger(const char* text) {
    const std::string value(text);
    if (value.empty() || value.find_first_not_of("0123456789") != std::string::npos)
        throw std::runtime_error("verification-frame-count must be a positive integer");
    const auto count = std::stoull(value);
    if (!count || count > std::numeric_limits<unsigned>::max())
        throw std::runtime_error("verification-frame-count is out of range");
    return static_cast<unsigned>(count);
}

StartupOptions ReadConfig(const std::filesystem::path& file) {
    std::ifstream input(file, std::ios::binary);
    if (!input) throw std::runtime_error("Cannot open startup config: " + file.u8string());
    const std::string bytes((std::istreambuf_iterator<char>(input)), {});
    // 复用已固定版本的 RapidJSON，不把解析器类型带到应用接口。
    // 接受 Windows 文本编辑器常见的 UTF-8 BOM；路径字符串按 UTF-8 解码。
    const size_t bom = bytes.compare(0, 3, "\xEF\xBB\xBF") == 0 ? 3 : 0;
    rapidjson::Document document;
    document.Parse<rapidjson::kParseValidateEncodingFlag>(bytes.data() + bom, bytes.size() - bom);
    if (document.HasParseError())
        throw std::runtime_error("Invalid JSON in " + file.u8string() + ": " +
            rapidjson::GetParseError_En(document.GetParseError()) +
            " at byte " + std::to_string(document.GetErrorOffset() + bom));
    if (!document.IsObject()) throw std::runtime_error("Startup config must be a JSON object");
    auto path = [&](const char* key) {
        const auto found = document.FindMember(key);
        if (found == document.MemberEnd() || !found->value.IsString() || !found->value.GetStringLength())
            throw std::runtime_error(std::string("Config requires a nonempty path: ") + key);
        std::string value(found->value.GetString(), found->value.GetStringLength());
        if (value.find('\0') != std::string::npos)
            throw std::runtime_error(std::string("Config path contains a NUL character: ") + key);
        auto result = std::filesystem::u8path(value);
        // 相对路径以 JSON 所在文件夹为基准；默认 JSON 就在 EXE 旁。
        // 不调用 SetCurrentDirectory，因此不会偷偷改变其它模块的路径语义。
        if (result.is_relative()) result = file.parent_path() / result;
        return result.lexically_normal();
    };
    StartupOptions options;
    options.assets = path("assets"); options.shaders = path("shaders");
    options.energy = path("energy_lut"); options.output = path("output");
    if (document.HasMember("render")) {
        const auto& render = document["render"];
        if (!render.IsObject()) throw std::runtime_error("Config render must be an object");
        auto dimension = [&](const char* key, unsigned fallback) {
            const auto found = render.FindMember(key);
            if (found == render.MemberEnd()) return fallback;
            if (!found->value.IsUint() || found->value.GetUint() < 16 || found->value.GetUint() > 4096)
                throw std::runtime_error(std::string("Config render.") + key + " must be an integer in [16, 4096]");
            return found->value.GetUint();
        };
        options.width = dimension("width", options.width);
        options.height = dimension("height", options.height);
        auto quality=[&](const char* key,unsigned fallback,unsigned maximum){
            auto found=render.FindMember(key);if(found==render.MemberEnd())return fallback;
            if(!found->value.IsUint()||found->value.GetUint()<1||found->value.GetUint()>maximum)
                throw std::runtime_error(std::string("Config render.")+key+" is outside supported quality range");
            return found->value.GetUint();
        };
        options.movingSpp=quality("moving_spp",options.movingSpp,32);options.pausedSpp=quality("paused_spp",options.pausedSpp,32);
        options.maxScatters=quality("max_scatters",options.maxScatters,16);
        if(render.HasMember("presentation")){
            if(!render["presentation"].IsBool())throw std::runtime_error("Config render.presentation must be boolean");
            options.presentation=render["presentation"].GetBool();
        }
        if(render.HasMember("sky_intensity")){
            if(!render["sky_intensity"].IsNumber())throw std::runtime_error("Config render.sky_intensity must be a number");
            double value=render["sky_intensity"].GetDouble();
            if(!(value>=0&&value<=20))throw std::runtime_error("Config sky intensity outside [0,20]");
            options.skyIntensity=float(value);
        }
    }
    return options;
}

void ValidateInputs(const StartupOptions& options) {
    auto file = [](const std::filesystem::path& value) {
        if (!std::filesystem::is_regular_file(value))
            throw std::runtime_error("Required runtime file is missing: " + value.u8string());
    };
    file(options.assets / "animation.glb"); file(options.energy);
    for (const char* name : {"path.dxil", "accumulate.dxil", "guides.dxil", "temporal.dxil", "dxr_display_vs.dxil", "dxr_display_ps.dxil"})
        file(options.shaders / name);
}
}

std::filesystem::path ExecutableDirectory() {
    // GetModuleFileNameW(nullptr, ...) 查当前 EXE 的绝对路径，不能用 argv[0]
    // 或 current_path() 替代：快捷方式、CMD、资源管理器都可以给出不同的工作目录。
    std::vector<wchar_t> buffer(512);
    for (;;) {
        const DWORD length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
        if (!length) throw std::runtime_error("GetModuleFileNameW failed: " + std::to_string(GetLastError()));
        if (length < buffer.size()) return std::filesystem::path(std::wstring(buffer.data(), length)).parent_path();
        if (buffer.size() >= 32768) throw std::runtime_error("Executable path exceeds supported length");
        buffer.resize(buffer.size() * 2);
    }
}

StartupOptions LoadStartupOptions(int argc, char** argv) {
    StartupOptions options;
    // 保留原验收脚本的四路径 + 可选帧数形式；它们的相对路径仍按调用方工作目录解释。
    if ((argc == 5 || argc == 6) && std::string(argv[1]).rfind("--", 0) != 0) {
        // 旧课程脚本保持原始小尺寸黑背景，便于对照已有数值证据。
        options.width=320;options.height=180;options.movingSpp=1;options.pausedSpp=4;options.maxScatters=4;options.presentation=false;
        options.assets = argv[1]; options.shaders = argv[2]; options.energy = argv[3]; options.output = argv[4];
        if (argc == 6) options.verificationFrames = PositiveInteger(argv[5]);
    } else {
        auto config = ExecutableDirectory() / "character_demo.json";
        unsigned frames = 0;
        for (int index = 1; index < argc; ++index) {
            const std::string flag(argv[index]);
            if (flag == "--config" && index + 1 < argc)
                config = std::filesystem::absolute(std::filesystem::path(argv[++index]));
            else if (flag == "--verify-frames" && index + 1 < argc)
                frames = PositiveInteger(argv[++index]);
            else throw std::runtime_error("Usage: character_demo [--config file.json] [--verify-frames N]\n"
                "Or: character_demo assets shaders energy.bin output [verification-frame-count]");
        }
        options = ReadConfig(config);
        options.verificationFrames = frames;
    }
    ValidateInputs(options);
    return options;
}

void ReportStartupError(const char* message, bool showDialog) noexcept {
    if (!showDialog) return;
    try {
        std::ofstream(ExecutableDirectory() / "startup-error.txt", std::ios::app) << message << '\n';
    } catch (...) { /* 日志目录不可写时，仍然要展示下面的错误提示。 */ }
    try {
        const int length = MultiByteToWideChar(CP_UTF8, 0, message, -1, nullptr, 0);
        std::vector<wchar_t> text(length > 0 ? length : 1, L'\0');
        if (length > 0) MultiByteToWideChar(CP_UTF8, 0, message, -1, text.data(), length);
        MessageBoxW(nullptr, text.data(), L"Character Demo 启动/运行失败", MB_OK | MB_ICONERROR);
    } catch (...) { /* 错误报告不得再次抛异常越过 main。 */ }
}
}
