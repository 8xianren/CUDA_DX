#include "sdk_upscalers.h"
#include "gpu_upload.h"
#include <filesystem>
#include <fstream>
#include <iostream>

// F.7/F.8低成本生命周期验收：本程序不声称测量图像质量，真实重建由主harness负责。
// 初始化/销毁之间Fence先完成；缺DLL是有意的失败注入，必须留下可回退状态。
int main(int argc, char** argv) {
    try {
        if (argc != 3) throw std::runtime_error("usage: sdk_probe depsRoot output.json");
        const std::filesystem::path deps = argv[1], result = argv[2];
        std::filesystem::create_directories(result.parent_path());
        UploadContext gpu;
        std::ofstream out(result);
        out << "{\n  \"scope\":\"initialization, quality-size query, resize lifecycle, missing DLL fallback; no image-quality claim\",\n  \"modes\":[\n";
        bool pass = true;
        for (int k = 0; k < 2; ++k) {
            for (int q = 0; q < 4; ++q) {
                aa::SdkUpscaler sdk;
                const bool ok = sdk.Initialize(gpu.device.Get(), k == 0 ? aa::SdkKind::Fsr : aa::SdkKind::XeSS,
                    static_cast<aa::SdkQuality>(q), 640, 360, 640, 360, deps);
                const uint32_t phases = ok ? sdk.JitterPhaseCount(sdk.RecommendedWidth(), 640) : 0;
                std::cout << k << ":" << q << " " << sdk.Status() << " input=" << sdk.RecommendedWidth() << "x" << sdk.RecommendedHeight() << " phases=" << phases << "\n";
                pass &= ok;
                out << "    {\"sdk\":\"" << (k == 0 ? "FSR" : "XeSS") << "\",\"quality_index\":" << q
                    << ",\"initialized\":" << (ok ? "true" : "false") << ",\"recommended_width\":" << sdk.RecommendedWidth()
                    << ",\"recommended_height\":" << sdk.RecommendedHeight() << ",\"jitter_phases\":" << phases << ",\"provider\":\"" << sdk.Provider() << "\"}";
                out << (k == 1 && q == 3 ? "\n" : ",\n");
                gpu.SubmitWait(); sdk.Shutdown();
            }
        }
        aa::SdkUpscaler resize;
        bool resizePass = resize.Initialize(gpu.device.Get(), aa::SdkKind::Fsr, aa::SdkQuality::Quality, 640, 360, 640, 360, deps);
        gpu.SubmitWait();
        resizePass &= resize.Initialize(gpu.device.Get(), aa::SdkKind::Fsr, aa::SdkQuality::Balanced, 800, 450, 800, 450, deps);
        gpu.SubmitWait(); resize.Shutdown();
        aa::SdkUpscaler absent;
        const bool missingFallback = !absent.Initialize(gpu.device.Get(), aa::SdkKind::Fsr, aa::SdkQuality::Quality,
            640, 360, 640, 360, deps / "intentionally-missing");
        const unsigned warnings = gpu.CheckDebug();
        pass &= resizePass && missingFallback && warnings == 0;
        out << "  ],\n  \"resize_lifecycle_pass\":" << (resizePass ? "true" : "false")
            << ",\n  \"missing_dll_returns_fallback\":" << (missingFallback ? "true" : "false")
            << ",\n  \"debug_warning_error\":" << warnings
            << ",\n  \"pass\":" << (pass ? "true" : "false") << "\n}\n";
        return pass ? 0 : 1;
    } catch (const std::exception& e) { std::cerr << e.what() << "\n"; return 2; }
}
