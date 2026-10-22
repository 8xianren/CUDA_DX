// G.9参考资产专用相机预览：无窗口、无bbox重定位，直接消费配对PLY转换后的GSBIN和相机。
#include "../../src/gaussian/gaussian.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
void require(bool value, const char *message) {
    if (!value) throw std::runtime_error(message);
}
void check(cudaError_t error) {
    if (error != cudaSuccess) throw std::runtime_error(cudaGetErrorString(error));
}
template<class T> struct Device {
    T *pointer{};
    explicit Device(size_t count) { check(cudaMalloc(&pointer, count * sizeof(T))); }
    ~Device() { cudaFree(pointer); }
    Device(const Device &) = delete;
    Device &operator=(const Device &) = delete;
};
template<class T> void exactRead(std::ifstream &file, T *destination, size_t count) {
    file.read(reinterpret_cast<char *>(destination), std::streamsize(count * sizeof(T)));
    require(bool(file), "truncated reference input");
}
std::vector<gs::Gaussian> loadScene(const std::filesystem::path &path) {
    std::ifstream file(path, std::ios::binary);
    char magic[8]; uint32_t header[4];
    exactRead(file, magic, 8); exactRead(file, header, 4);
    require(std::string(magic, 8) == "GSBIN001", "unknown Gaussian wire format");
    static_assert(sizeof(gs::Gaussian) == 244, "runtime ABI differs from declared wire format");
    require(header[0] > 0 && header[0] <= 10000000 && header[1] == 244 && header[2] <= 3 && header[3] == 0,
            "invalid Gaussian header");
    require(std::filesystem::file_size(path) == 24ull + uint64_t(header[0]) * 244, "Gaussian file size mismatch");
    // 输入是经严格导入验证的小端浮点wire，当前Windows/x86也是小端且layout由上面static_assert限定。
    // 生产跨平台加载器应逐字段解码；这里没有对大资产进行归一化、裁剪或减少高斯数量。
    std::vector<gs::Gaussian> scene(header[0]);
    exactRead(file, scene.data(), scene.size());
    for (size_t i = 0; i < scene.size(); ++i)
        require(scene[i].id == i && scene[i].shDegree == header[2], "unstable Gaussian identity or SH degree");
    return scene;
}
gs::Camera loadCamera(const std::filesystem::path &path) {
    std::ifstream file(path, std::ios::binary);
    uint32_t dimensions[2]; float values[18];
    exactRead(file, dimensions, 2); exactRead(file, values, 18);
    require(std::filesystem::file_size(path) == 80 && dimensions[0] == 640 && dimensions[1] == 360,
            "unexpected camera binary dimensions");
    gs::Camera camera;
    camera.width = int(dimensions[0]); camera.height = int(dimensions[1]);
    std::copy(values, values + 12, camera.worldToCamera);
    camera.fx = values[12]; camera.fy = values[13]; camera.cx = values[14]; camera.cy = values[15];
    camera.nearPlane = values[16]; camera.maxRadiusPixels = values[17];
    return camera;
}
}

int main(int argc, char **argv) {
    try {
        require(argc == 2, "usage: reference_render.exe <course-directory>");
        const std::filesystem::path root = argv[1], output = root / "results/g9/reference-preview";
        std::filesystem::create_directories(output);
        cudaDeviceProp device{};
        check(cudaGetDeviceProperties(&device, 0));
        require(device.major == 12 && device.minor == 0, "reference validation requires sm_120");
        const auto begin = std::chrono::steady_clock::now();
        auto scene = loadScene(root / "downloads/reference/camera-paired-train-7000.gsbin");
        auto camera = loadCamera(root / "downloads/reference/camera-paired-camera0.bin");
        gs::Renderer renderer;
        renderer.setScene(std::move(scene));
        const double loadMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin).count();
        const size_t pixels = size_t(camera.width) * camera.height;
        Device<float4> color(pixels);
        Device<float> depth(pixels);
        // API返回前同步所用CUDA stream，事件阶段时间来自gs::Renderer，而非CPU launch耗时。
        // 仅做一轮暖机+一轮测量，报告明确是预览样本，不冒充统计稳定的性能基准。
        renderer.render(camera, color.pointer, depth.pointer);
        const auto renderBegin = std::chrono::steady_clock::now();
        const auto stats = renderer.render(camera, color.pointer, depth.pointer);
        const double renderMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - renderBegin).count();
        std::vector<float4> host(pixels);
        check(cudaMemcpy(host.data(), color.pointer, pixels * sizeof(float4), cudaMemcpyDeviceToHost));
        size_t nonzero = 0; double alphaSum = 0;
        for (const auto &pixel : host) {
            require(std::isfinite(pixel.x) && std::isfinite(pixel.y) && std::isfinite(pixel.z) && std::isfinite(pixel.w),
                    "reference render contains nonfinite color");
            require(pixel.w >= 0 && pixel.w <= 1.000001f, "reference alpha outside bounds");
            nonzero += pixel.w > .01f; alphaSum += pixel.w;
        }
        require(nonzero > pixels / 4 && stats.visibleCount > 1000, "reference camera did not reveal meaningful geometry");
        std::ofstream raw(output / "camera0.f32", std::ios::binary);
        raw.write(reinterpret_cast<const char *>(host.data()), std::streamsize(host.size() * sizeof(float4)));
        raw.close();
        std::ofstream report(output / "render.json");
        report << std::setprecision(10)
               << "{\n  \"status\": \"PASS\",\n  \"gpu\": \"" << device.name << "\",\n"
               << "  \"capability\": [12,0],\n  \"resolution\": [640,360],\n"
               << "  \"full_gaussian_count\": " << stats.gaussianCount << ",\n"
               << "  \"visible_gaussian_count\": " << stats.visibleCount << ",\n"
               << "  \"references\": " << stats.references << ",\n"
               << "  \"persistent_bytes\": " << stats.persistentBytes << ",\n"
               << "  \"scratch_bytes\": " << stats.scratchBytes << ",\n"
               << "  \"load_set_scene_ms\": " << loadMs << ",\n"
               << "  \"single_render_wall_ms\": " << renderMs << ",\n"
               << "  \"gpu_stages_ms\": {\"project\": " << stats.projectMs << ", \"scan\": " << stats.scanMs
               << ", \"duplicate\": " << stats.duplicateMs << ", \"sort\": " << stats.sortMs
               << ", \"ranges\": " << stats.rangesMs << ", \"splat\": " << stats.splatMs << "},\n"
               << "  \"alpha_gt_0_01_pixels\": " << nonzero << ",\n  \"mean_alpha\": " << alphaSum / pixels << ",\n"
               << "  \"rejected\": [";
        for (unsigned i = 0; i < unsigned(gs::Reject::Count); ++i) {
            if (i) report << ',';
            report << stats.rejected[i];
        }
        report << "],\n  \"measurement\": \"one warmup plus one measured preview; not a repeated performance benchmark\",\n"
               << "  \"scene_transform\": \"none; original paired asset coordinates\",\n"
               << "  \"quality_limit\": \"teaching rasterizer; no official-image PSNR equivalence claimed\"\n}\n";
        std::cout << "reference_preview PASS full=" << stats.gaussianCount << " visible=" << stats.visibleCount
                  << " wall_ms=" << renderMs << " output=" << output.string() << '\n';
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "reference_preview FAIL: " << error.what() << '\n';
        return 1;
    }
}
