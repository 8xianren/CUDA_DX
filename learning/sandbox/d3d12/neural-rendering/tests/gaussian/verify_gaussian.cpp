#include "../../src/gaussian/gaussian.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <random>
#include <stdexcept>

namespace {
void require(bool value, const char *message) {
    if (!value)
        throw std::runtime_error(message);
}
void ck(cudaError_t e) {
    if (e != cudaSuccess)
        throw std::runtime_error(cudaGetErrorString(e));
}
template <class T> struct Device {
    T *p{};
    Device(size_t n) { ck(cudaMalloc(&p, n * sizeof(T))); }
    ~Device() { cudaFree(p); }
};
std::vector<float4> read(float4 *p, size_t n) {
    std::vector<float4> v(n);
    ck(cudaMemcpy(v.data(), p, n * sizeof(float4), cudaMemcpyDeviceToHost));
    return v;
}
double difference(const std::vector<float4> &a, const std::vector<float4> &b) {
    double error = 0;
    for (size_t i = 0; i < a.size(); ++i) {
        const float *x = &a[i].x, *y = &b[i].x;
        for (int k = 0; k < 4; ++k)
            error = std::max(error, double(std::abs(x[k] - y[k])));
    }
    return error;
}
void savePpm(const std::filesystem::path &path, const std::vector<float4> &v, int w, int h) {
    std::ofstream f(path, std::ios::binary);
    f << "P6\n" << w << " " << h << "\n255\n";
    for (auto c : v)
        for (float ch : {c.x, c.y, c.z}) {
            unsigned char q =
                static_cast<unsigned char>(255 * std::pow(std::min(1.f, std::max(0.f, ch)), 1 / 2.2f));
            f.write(reinterpret_cast<const char *>(&q), 1);
        }
}
} // namespace
int main(int argc, char **argv) {
    try {
        // 工作目录默认仓库根；显式 results 参数可让 CTest/独立运行都写入本课 G6/G7/G8，不污染源代码根。
        const std::filesystem::path root =
            argc > 1 ? argv[1] : "learning/sandbox/d3d12/neural-rendering/results";
        const bool profile = argc > 2 && std::string(argv[2]) == "--profile";
        const bool checkOnly = argc > 2 && std::string(argv[2]) == "--check-only";
        std::filesystem::create_directories(root / "g6");
        std::filesystem::create_directories(root / "g7");
        std::filesystem::create_directories(root / "g8");
        gs::Camera camera;
        camera.width = 128;
        camera.height = 96;
        camera.fx = camera.fy = 100;
        camera.cx = 64;
        camera.cy = 48;
        gs::Renderer renderer;
        auto scene = gs::makeScene(profile ? 10000 : 128);
        // 人为制造完全相同深度、不同 id 和颜色的重叠高斯，以检验排序平局不是偶然没有出现。
        for (unsigned i = 0; i < std::min<size_t>(12, scene.size()); ++i) {
            scene[i].mean[2] = 3;
            scene[i].mean[0] = 0;
            scene[i].mean[1] = 0;
        }
        renderer.setScene(scene);
        Device<float4> output(size_t(camera.width) * camera.height);
        Device<float> depth(size_t(camera.width) * camera.height);
        auto stats = renderer.render(camera, output.p, depth.p);
        if (profile) {
            std::cout << "PROFILE gaussian_count=" << stats.gaussianCount
                      << " references=" << stats.references << " splat_ms=" << stats.splatMs << "\n";
            return 0;
        }
        unsigned checks = 0;
        auto test = [&](bool b, const char *m) {
            require(b, m);
            ++checks;
        };
        // 解析 oracle：中心球高斯 Sigma2D=diag((f*s/z)^2+.3)。独立于 projectOne 的代码路径。
        gs::Gaussian sphere;
        sphere.id = 500;
        sphere.mean[2] = 2;
        sphere.scale[0] = sphere.scale[1] = sphere.scale[2] = .2f;
        auto known = gs::projectCpu(sphere, camera);
        test(std::abs(known.u - 64) < 1e-6 && std::abs(known.v - 48) < 1e-6 && known.z == 2,
             "analytic projected center");
        test(std::abs(known.xx - 100.3f) < 2e-5 && std::abs(known.yy - 100.3f) < 2e-5 && known.xy == 0,
             "analytic spherical covariance");
        sphere.scale[0] = .2f;
        sphere.scale[1] = .1f;
        sphere.rotation[0] = std::sqrt(.5f);
        sphere.rotation[3] = std::sqrt(.5f);
        known = gs::projectCpu(sphere, camera);
        test(std::abs(known.xx - 25.3f) < 5e-5 && std::abs(known.yy - 100.3f) < 5e-5,
             "90 degree covariance axes swap");
        sphere.mean[0] = .4f;
        sphere.mean[1] = .2f;
        known = gs::projectCpu(sphere, camera);
        test(std::abs(known.u - 84) < 1e-5 && std::abs(known.v - 38) < 1e-5, "pixel Y inversion");
        std::vector<gs::Gaussian> adversarial(5, sphere);
        for (unsigned i = 0; i < 5; ++i)
            adversarial[i].id = 1000 + i;
        adversarial[0].mean[2] = -1;
        adversarial[1].scale[0] = 0;
        adversarial[2].scale[0] = 1000;
        adversarial[3].mean[0] = 1000;
        adversarial[4].mean[0] = std::numeric_limits<float>::quiet_NaN();
        renderer.setScene(adversarial);
        auto badStats = renderer.render(camera, output.p);
        auto bad = renderer.readProjected();
        const gs::Reject expected[] = {gs::Reject::BehindCamera, gs::Reject::Degenerate, gs::Reject::Oversize,
                                       gs::Reject::Offscreen, gs::Reject::NonFinite};
        // 远处 x=1000 的投影 Jacobian 也会扩大椭圆，使用 x=10,z=2 与小 z 尺度构造真实离屏案例。
        adversarial[3].mean[0] = 10;
        adversarial[3].scale[2] = .0001f;
        renderer.setScene(adversarial);
        badStats = renderer.render(camera, output.p);
        bad = renderer.readProjected();
        for (unsigned i = 0; i < 5; ++i)
            test(bad[i].reject == expected[i], "adversarial projection reject reason");
        renderer.setScene(scene);
        stats = renderer.render(camera, output.p, depth.p);
        auto projected = renderer.readProjected();
        std::vector<gs::Projected> cpu;
        double maxProjectError = 0;
        for (size_t i = 0; i < renderer.scene().size(); ++i) {
            auto p = gs::projectCpu(renderer.scene()[i], camera);
            cpu.push_back(p);
            const auto &q = projected[i];
            test(p.reject == q.reject, "CPU/GPU projection reject");
            if (p.reject != gs::Reject::Visible)
                continue;
            for (auto pair : {std::pair<float, float>{p.u, q.u},
                              {p.v, q.v},
                              {p.z, q.z},
                              {p.xx, q.xx},
                              {p.xy, q.xy},
                              {p.yy, q.yy}})
                maxProjectError = std::max(maxProjectError, double(std::abs(pair.first - pair.second)));
            test(p.minX == q.minX && p.minY == q.minY && p.maxX == q.maxX && p.maxY == q.maxY,
                 "CPU/GPU projection bounding rectangle");
        }
        test(maxProjectError < 1e-3, "CPU/GPU projection tolerance");
        auto reference = gs::referencesCpu(renderer.scene(), cpu, camera),
             gpuRefs = renderer.readReferences();
        test(reference.size() == gpuRefs.size(), "CPU/GPU duplicate count");
        for (size_t i = 0; i < reference.size(); ++i)
            test(reference[i].key == gpuRefs[i].key && reference[i].id == gpuRefs[i].id,
                 "tile set and depth stable-id order");
        auto gpuImage = read(output.p, size_t(camera.width) * camera.height);
        auto cpuImage = gs::splatCpu(cpu, reference, camera);
        double error = difference(gpuImage, cpuImage);
        test(error < 3e-5, "CPU/GPU premultiplied splat image");
        std::mt19937 random(17);
        std::shuffle(scene.begin(), scene.end(), random);
        renderer.setScene(scene);
        renderer.render(camera, output.p);
        auto shuffled = read(output.p, gpuImage.size());
        test(std::memcmp(gpuImage.data(), shuffled.data(), gpuImage.size() * sizeof(float4)) == 0,
             "shuffle bitwise identical image");
        auto shuffledRefs = renderer.readReferences();
        test(shuffledRefs.size() == gpuRefs.size(), "shuffle list size");
        for (size_t i = 0; i < gpuRefs.size(); ++i)
            test(shuffledRefs[i].key == gpuRefs[i].key && shuffledRefs[i].id == gpuRefs[i].id,
                 "shuffle exact sorted key/id");
        // 非 tile 整数倍 viewport：最后一行/列无效线程仍参与 barrier，验证早退不会破坏同步。
        gs::Camera odd = camera;
        odd.width = 131;
        odd.height = 97;
        Device<float4> oddImage(size_t(odd.width) * odd.height);
        renderer.render(odd, oddImage.p);
        std::vector<gs::Projected> oddCpu;
        for (const auto &g : renderer.scene())
            oddCpu.push_back(gs::projectCpu(g, odd));
        auto oddRef = gs::referencesCpu(renderer.scene(), oddCpu, odd);
        test(difference(read(oddImage.p, size_t(odd.width) * odd.height), gs::splatCpu(oddCpu, oddRef, odd)) <
                 3e-5,
             "partial tile edges CPU/GPU match");
        std::vector<float> mesh(gpuImage.size(), std::numeric_limits<float>::infinity());
        for (int y = 0; y < camera.height; ++y)
            for (int x = 0; x < camera.width / 2; ++x)
                mesh[y * camera.width + x] = .1f;
        Device<float> meshGpu(mesh.size());
        ck(cudaMemcpy(meshGpu.p, mesh.data(), mesh.size() * sizeof(float), cudaMemcpyHostToDevice));
        renderer.render(camera, output.p, depth.p, meshGpu.p);
        auto meshResult = read(output.p, gpuImage.size());
        double meshError = difference(meshResult, gs::splatCpu(cpu, reference, camera, mesh.data()));
        test(meshError < 3e-5, "mesh linear-Z occlusion");
        for (int y = 0; y < camera.height; ++y)
            for (int x = 0; x < camera.width / 2; ++x)
                test(meshResult[y * camera.width + x].w == 0, "opaque mesh hides behind Gaussians");
        auto dup = scene;
        dup.push_back(scene.front());
        bool rejected = false;
        try {
            renderer.setScene(dup);
        } catch (const std::exception &) {
            rejected = true;
        }
        test(rejected, "duplicate stable id rejected");
        renderer.setScene({});
        renderer.render(camera, output.p);
        auto empty = read(output.p, gpuImage.size());
        test(std::all_of(empty.begin(), empty.end(),
                         [](float4 p) { return p.x == 0 && p.y == 0 && p.z == 0 && p.w == 0; }),
             "empty scene transparent");
        gs::Camera invalid = camera;
        invalid.worldToCamera[0] = 2;
        rejected = false;
        try {
            renderer.render(invalid, output.p);
        } catch (const std::exception &) {
            rejected = true;
        }
        test(rejected, "non-rigid camera rejected");
        invalid = camera;
        invalid.fx = std::numeric_limits<float>::quiet_NaN();
        rejected = false;
        try {
            renderer.render(invalid, output.p);
        } catch (const std::exception &) {
            rejected = true;
        }
        test(rejected, "non-finite intrinsics rejected");
        // 9000 个高斯均覆盖 512² 图像的 1024 个 tile，9,216,000 引用超过8M预算。必须在复制内核前显式失败。
        gs::Camera capCamera = camera;
        capCamera.width = capCamera.height = 512;
        capCamera.cx = capCamera.cy = 256;
        capCamera.maxRadiusPixels = 10000;
        std::vector<gs::Gaussian> overBudget(9000, sphere);
        for (unsigned i = 0; i < overBudget.size(); ++i) {
            auto &q = overBudget[i];
            q.id = i;
            q.mean[0] = q.mean[1] = 0;
            q.mean[2] = 2;
            q.scale[0] = q.scale[1] = q.scale[2] = 10;
        }
        renderer.setScene(overBudget);
        Device<float4> capImage(512 * 512);
        rejected = false;
        try {
            renderer.render(capCamera, capImage.p);
        } catch (const std::exception &e) {
            rejected = std::string(e.what()).find("8,000,000") != std::string::npos;
        }
        test(rejected, "reference budget checked before duplicate writes");
        if (checkOnly) {
            std::cout << "PASS " << checks << " functional checks (benchmark reports not overwritten)\n";
            return 0;
        }
        // 大场景记录稳定重复运行的逐阶段 GPU event 时间；不把 CUDA 初始化、CPU 排序与 PCIe 上传算作 kernel
        // 时间。
        gs::Camera large = camera;
        large.width = 640;
        large.height = 360;
        large.cx = 320;
        large.cy = 180;
        large.fx = large.fy = 386;
        renderer.setScene(gs::makeScene(100000));
        Device<float4> largeImage(size_t(large.width) * large.height);
        for (int i = 0; i < 3; ++i)
            renderer.render(large, largeImage.p);
        gs::Stats big{};
        double times[6]{};
        const int iterations = 10;
        for (int i = 0; i < iterations; ++i) {
            big = renderer.render(large, largeImage.p);
            float t[] = {big.projectMs, big.scanMs, big.duplicateMs, big.sortMs, big.rangesMs, big.splatMs};
            for (int j = 0; j < 6; ++j)
                times[j] += t[j] / iterations;
        }
        cudaDeviceProp prop{};
        ck(cudaGetDeviceProperties(&prop, 0));
        int runtime = 0, driver = 0;
        ck(cudaRuntimeGetVersion(&runtime));
        ck(cudaDriverGetVersion(&driver));
        std::ofstream g6(root / "g6" / "projection.json");
        g6 << std::setprecision(10)
           << "{\n  \"known_analytic_cases\":4,\n  "
              "\"adversarial_reasons\":[\"behind_camera\",\"degenerate\",\"oversize\",\"offscreen\",\"non_"
              "finite\"],\n  \"projection_max_abs_error\":"
           << maxProjectError << ",\n  \"bounding_rectangles_equal\":true\n}\n";
        std::ofstream g7(root / "g7" / "binning.json");
        g7 << std::setprecision(10) << "{\n  \"gpu\":\"" << prop.name << "\",\n  \"cuda_runtime\":" << runtime
           << ",\n  \"cuda_driver_api\":" << driver
           << ",\n  \"resolution\":[640,360],\n  \"gaussians\":" << big.gaussianCount
           << ",\n  \"visible\":" << big.visibleCount << ",\n  \"references\":" << big.references
           << ",\n  \"tiles\":" << big.tiles << ",\n  \"persistent_bytes\":" << big.persistentBytes
           << ",\n  \"cub_scratch_bytes\":" << big.scratchBytes
           << ",\n  \"warmup\":3,\n  \"measured_runs\":10,\n  \"stage_ms\":{\"projection\":" << times[0]
           << ",\"scan\":" << times[1] << ",\"duplicate\":" << times[2] << ",\"sort\":" << times[3]
           << ",\"ranges\":" << times[4] << ",\"splat\":" << times[5]
           << "},\n  \"cpu_tile_membership_and_order_equal\":true,\n  \"shuffle_keys_ids_equal\":true\n}\n";
        std::ofstream g8(root / "g8" / "splat.json");
        g8 << std::setprecision(10) << "{\n  \"checks_passed\":" << checks
           << ",\n  \"resolution\":[128,96],\n  \"gaussians\":128,\n  \"rgba_max_abs_error\":" << error
           << ",\n  \"mesh_occlusion_max_abs_error\":" << meshError
           << ",\n  \"shuffle_bitwise_identical\":true,\n  \"empty_scene_transparent\":true,\n  "
              "\"block_threads\":256,\n  \"shared_bytes_per_block\":10240,\n  \"large_splat_ms\":"
           << times[5] << "\n}\n";
        savePpm(root / "g8" / "gaussian-reference.ppm", gpuImage, camera.width, camera.height);
        savePpm(root / "g8" / "gaussian-large.ppm", read(largeImage.p, size_t(large.width) * large.height),
                large.width, large.height);
        std::cout << "PASS " << checks << " checks; projection_max=" << maxProjectError
                  << " rgba_max=" << error << " references=" << big.references << " splat_ms=" << times[5]
                  << "\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "FAIL " << e.what() << "\n";
        return 1;
    }
}
