#include "gaussian.h"
#include "projection_math.cuh"
#include <algorithm>
#include <array>
#include <cub/cub.cuh>
#include <limits>
#include <math_constants.h>
#include <stdexcept>
#include <string>

namespace gs {
namespace {
void check(cudaError_t result, const char *operation) {
    if (result != cudaSuccess)
        throw std::runtime_error(std::string(operation) + ": " + cudaGetErrorString(result));
}
template <class T> struct Buffer {
    T *data{};
    size_t capacity{};
    ~Buffer() {
        if (data)
            cudaFree(data);
    } // 所有权只属于 Renderer；输出 RGBA/depth 指针属于调用者。
    void reserve(size_t n) {
        if (n <= capacity)
            return;
        if (data) {
            check(cudaFree(data), "cudaFree growth");
            data = nullptr;
            capacity = 0;
        }
        if (n) {
            check(cudaMalloc(&data, n * sizeof(T)), "cudaMalloc");
            capacity = n;
        }
    }
    size_t bytes() const { return capacity * sizeof(T); }
};
struct Events {
    cudaEvent_t e[12]{};
    Events() {
        for (auto &v : e)
            check(cudaEventCreate(&v), "cudaEventCreate");
    }
    ~Events() {
        for (auto v : e)
            if (v)
                cudaEventDestroy(v);
    }
};

__global__ void projectKernel(const Gaussian *g, Projected *p, uint64_t *counts, uint32_t *rejected,
                              uint32_t n, Camera c) {
    unsigned i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n)
        return;
    p[i] = projectOne(g[i], c);
    counts[i] = p[i].tileCount;
    atomicAdd(rejected + unsigned(p[i].reject), 1u);
}
__global__ void duplicateKernel(const Projected *p, const uint64_t *inclusive, uint64_t *keys,
                                uint32_t *indices, uint32_t n, unsigned tilesX) {
    unsigned i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n || p[i].reject != Reject::Visible)
        return;
    uint64_t cursor = i ? inclusive[i - 1] : 0;
    const auto q = p[i];
    // 正有限 z 的 IEEE754 位序与数值升序相同；不能对负 z、NaN 直接这么做（投影阶段已剔除）。
    // inclusive scan 已证明每个高斯拥有互不重叠的 [prefix-count,prefix) 写区间，不需要原子分配。
    for (int y = q.tileMinY; y < q.tileMaxY; ++y)
        for (int x = q.tileMinX; x < q.tileMaxX; ++x) {
            keys[cursor] = (uint64_t(y * tilesX + x) << 32) | __float_as_uint(q.z);
            indices[cursor] = i;
            ++cursor;
        }
}
__global__ void rangeKernel(const uint64_t *keys, uint2 *ranges, uint32_t n) {
    unsigned i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n)
        return;
    unsigned tile = unsigned(keys[i] >> 32);
    if (i == 0 || unsigned(keys[i - 1] >> 32) != tile)
        ranges[tile].x = i;
    if (i + 1 == n || unsigned(keys[i + 1] >> 32) != tile)
        ranges[tile].y = i + 1;
}
struct SharedGaussian {
    float u, v, z, a, b, c, r, g, blue, opacity;
};
__global__ void splatKernel(const Projected *projected, const uint32_t *indices, const uint2 *ranges,
                            float4 *out, float *depth, const float *mesh, Camera camera) {
    // 固定 16×16 block = 256 线程。每个线程对应一个像素，但批量载入阶段每线程负责一个高斯引用。
    // 当前 tile 的 256 个像素复用同一批高斯，减少重复 global load。40 bytes×256=10 KiB shared/block。
    __shared__ SharedGaussian shared[256];
    unsigned lane = threadIdx.y * 16 + threadIdx.x, x = blockIdx.x * 16 + threadIdx.x,
             y = blockIdx.y * 16 + threadIdx.y;
    unsigned tile = blockIdx.y * gridDim.x + blockIdx.x;
    uint2 range = ranges[tile];
    bool valid = x < unsigned(camera.width) && y < unsigned(camera.height);
    size_t pixel = size_t(y) * camera.width + x;
    float t = 1, r = 0, g = 0, b = 0, weightedZ = 0;
    bool done = !valid;
    float meshZ = valid && mesh ? mesh[pixel] : CUDART_INF_F;
    for (unsigned start = range.x; start < range.y; start += 256) {
        // 已完成像素仍须参与 barrier；只有整个 block 都结束才可以共同 break，避免 divergent __syncthreads
        // 死锁。
        int finished = __syncthreads_count(done);
        if (finished == 256)
            break;
        unsigned index = start + lane;
        if (index < range.y) {
            const auto p = projected[indices[index]];
            shared[lane] = {p.u,        p.v,      p.z,      p.conic[0], p.conic[1],
                            p.conic[2], p.rgb[0], p.rgb[1], p.rgb[2],   p.opacity};
        }
        __syncthreads();
        unsigned count = min(256u, range.y - start);
        if (!done)
            for (unsigned j = 0; j < count; ++j) {
                const auto q = shared[j];
                if (q.z >= meshZ)
                    continue;
                float dx = x + .5f - q.u, dy = y + .5f - q.v;
                float power = -.5f * (q.a * dx * dx + 2 * q.b * dx * dy + q.c * dy * dy);
                if (power < -4.5f || power > 0)
                    continue;
                float alpha = fminf(.99f, q.opacity * expf(power));
                if (alpha < 1 / 255.f)
                    continue;
                float weight = t * alpha;
                r += weight * q.r;
                g += weight * q.g;
                b += weight * q.blue;
                weightedZ += weight * q.z;
                t *= 1 - alpha;
                if (t < 1e-4f) {
                    done = true;
                    break;
                }
            }
        // 下一轮 __syncthreads_count 同时保证所有读取结束后才能覆盖 shared。
    }
    if (valid) {
        out[pixel] = make_float4(r, g, b, 1 - t);
        if (depth)
            depth[pixel] = (1 - t) > 1e-8f ? weightedZ / (1 - t) : CUDART_INF_F;
    }
}
} // namespace
struct Renderer::Impl {
    std::vector<Gaussian> host;
    Buffer<Gaussian> gaussians;
    Buffer<Projected> projected;
    Buffer<uint64_t> counts, prefix, keyIn, keyOut;
    Buffer<uint32_t> indexIn, indexOut, rejected;
    Buffer<uint2> ranges;
    Buffer<unsigned char> scratch;
    uint32_t lastReferences{};
    cudaStream_t lastStream{};
};
Renderer::Renderer() : impl_(new Impl) {}
Renderer::~Renderer() = default;
const std::vector<Gaussian> &Renderer::scene() const { return impl_->host; }
void Renderer::setScene(std::vector<Gaussian> scene) {
    if (scene.size() > 4000000)
        throw std::runtime_error("Gaussian count exceeds teaching renderer cap 4,000,000");
    // CUB SortPairs 是稳定 radix sort。先按 stable id 排列源高斯，复制引用保持顺序；相同(tile,z) 因而按 id
    // 排列。 这避免将深度量化以塞入 id，也避免假设输入数组顺序固定。重复 id 直接报错，不能默默破坏 shuffle
    // 不变量。
    std::sort(scene.begin(), scene.end(), [](const Gaussian &a, const Gaussian &b) { return a.id < b.id; });
    for (size_t i = 1; i < scene.size(); ++i)
        if (scene[i - 1].id == scene[i].id)
            throw std::runtime_error("duplicate Gaussian stable id");
    auto &s = *impl_;
    s.host = std::move(scene);
    const size_t n = s.host.size();
    s.gaussians.reserve(n);
    s.projected.reserve(n);
    s.counts.reserve(n);
    s.prefix.reserve(n);
    s.rejected.reserve(unsigned(Reject::Count));
    if (n)
        check(cudaMemcpy(s.gaussians.data, s.host.data(), n * sizeof(Gaussian), cudaMemcpyHostToDevice),
              "upload Gaussians");
}
Stats Renderer::render(const Camera &camera, float4 *rgba, float *depth, const float *mesh,
                       cudaStream_t stream) {
    if (!rgba || camera.width < 1 || camera.height < 1 || camera.width > 16384 || camera.height > 16384 ||
        camera.fx <= 0 || camera.fy <= 0 || camera.nearPlane <= 0 || camera.maxRadiusPixels <= 0)
        throw std::runtime_error("invalid output/camera dimensions or projection");
    for (float v : {camera.fx, camera.fy, camera.cx, camera.cy, camera.nearPlane, camera.maxRadiusPixels})
        if (!std::isfinite(v))
            throw std::runtime_error("non-finite camera projection");
    for (float v : camera.worldToCamera)
        if (!std::isfinite(v))
            throw std::runtime_error("non-finite camera");
    // 相机须为刚体：SH 观察方向使用 W^T 求逆，不能允许缩放/剪切偷偷进入 view 矩阵。
    for (int r = 0; r < 3; ++r)
        for (int k = 0; k < 3; ++k) {
            float dot = 0;
            for (int j = 0; j < 3; ++j)
                dot += camera.worldToCamera[r * 4 + j] * camera.worldToCamera[k * 4 + j];
            if (std::abs(dot - (r == k ? 1.f : 0.f)) > 1e-3f)
                throw std::runtime_error("camera rotation is not orthonormal");
        }
    auto &s = *impl_;
    s.lastStream = stream;
    Stats stats{};
    stats.gaussianCount = uint32_t(s.host.size());
    unsigned n = stats.gaussianCount;
    const unsigned tilesX = (camera.width + 15) / 16, tilesY = (camera.height + 15) / 16;
    stats.tiles = tilesX * tilesY;
    s.ranges.reserve(stats.tiles);
    Events events;
    auto record = [&](int i) { check(cudaEventRecord(events.e[i], stream), "record stage event"); };
    check(cudaMemsetAsync(s.rejected.data, 0, unsigned(Reject::Count) * sizeof(uint32_t), stream),
          "clear reject counts");
    record(0);
    if (n)
        projectKernel<<<(n + 255) / 256, 256, 0, stream>>>(s.gaussians.data, s.projected.data, s.counts.data,
                                                           s.rejected.data, n, camera);
    record(1);
    size_t scanBytes = 0;
    if (n) {
        check(cub::DeviceScan::InclusiveSum(nullptr, scanBytes, s.counts.data, s.prefix.data, n, stream),
              "query scan scratch");
        s.scratch.reserve(scanBytes);
    }
    record(2);
    if (n) {
        check(
            cub::DeviceScan::InclusiveSum(s.scratch.data, scanBytes, s.counts.data, s.prefix.data, n, stream),
            "CUB InclusiveSum");
    }
    record(3);
    uint64_t total = 0;
    if (n)
        check(cudaMemcpyAsync(&total, s.prefix.data + n - 1, sizeof(total), cudaMemcpyDeviceToHost, stream),
              "read reference count");
    check(cudaStreamSynchronize(stream), "count boundary");
    // 计数一直用 uint64；先检查再缩为 uint32 并分配。超出上限时报错，不截断/不溢出写入。
    // 8M 引用时 key+index 双缓冲约 192 MiB，另计 CUB scratch，适合本机 12 GiB 的课程预算。
    if (total > 8000000ull)
        throw std::runtime_error("tile duplicate count exceeds checked cap 8,000,000");
    s.lastReferences = stats.references = uint32_t(total);
    s.keyIn.reserve(total);
    s.keyOut.reserve(total);
    s.indexIn.reserve(total);
    s.indexOut.reserve(total);
    record(4);
    if (n && total)
        duplicateKernel<<<(n + 255) / 256, 256, 0, stream>>>(s.projected.data, s.prefix.data, s.keyIn.data,
                                                             s.indexIn.data, n, tilesX);
    record(5);
    size_t sortBytes = 0;
    if (total) {
        check(cub::DeviceRadixSort::SortPairs(nullptr, sortBytes, s.keyIn.data, s.keyOut.data, s.indexIn.data,
                                              s.indexOut.data, stats.references, 0, 64, stream),
              "query sort scratch");
        s.scratch.reserve(std::max(scanBytes, sortBytes));
    }
    record(6);
    if (total) {
        check(cub::DeviceRadixSort::SortPairs(s.scratch.data, sortBytes, s.keyIn.data, s.keyOut.data,
                                              s.indexIn.data, s.indexOut.data, stats.references, 0, 64,
                                              stream),
              "CUB SortPairs");
    }
    record(7);
    record(8);
    check(cudaMemsetAsync(s.ranges.data, 0, stats.tiles * sizeof(uint2), stream), "clear ranges");
    if (total)
        rangeKernel<<<(stats.references + 255) / 256, 256, 0, stream>>>(s.keyOut.data, s.ranges.data,
                                                                        stats.references);
    record(9);
    record(10);
    splatKernel<<<dim3(tilesX, tilesY), dim3(16, 16), 0, stream>>>(s.projected.data, s.indexOut.data,
                                                                   s.ranges.data, rgba, depth, mesh, camera);
    record(11);
    check(cudaGetLastError(), "Gaussian kernels");
    check(cudaMemcpyAsync(stats.rejected, s.rejected.data, sizeof(stats.rejected), cudaMemcpyDeviceToHost,
                          stream),
          "read reject counts");
    check(cudaStreamSynchronize(stream), "Gaussian render completion");
    float *times[] = {&stats.projectMs, &stats.scanMs,   &stats.duplicateMs,
                      &stats.sortMs,    &stats.rangesMs, &stats.splatMs};
    for (int i = 0; i < 6; ++i)
        check(cudaEventElapsedTime(times[i], events.e[i * 2], events.e[i * 2 + 1]), "elapsed stage time");
    stats.visibleCount = stats.rejected[0];
    stats.scratchBytes = s.scratch.bytes();
    stats.persistentBytes = s.gaussians.bytes() + s.projected.bytes() + s.counts.bytes() + s.prefix.bytes() +
                            s.keyIn.bytes() + s.keyOut.bytes() + s.indexIn.bytes() + s.indexOut.bytes() +
                            s.rejected.bytes() + s.ranges.bytes();
    return stats;
}
std::vector<Projected> Renderer::readProjected() const {
    const auto &s = *impl_;
    std::vector<Projected> p(s.host.size());
    if (!p.empty())
        check(cudaMemcpy(p.data(), s.projected.data, p.size() * sizeof(Projected), cudaMemcpyDeviceToHost),
              "read projected");
    return p;
}
std::vector<Reference> Renderer::readReferences() const {
    const auto &s = *impl_;
    std::vector<uint64_t> keys(s.lastReferences);
    std::vector<uint32_t> indices(s.lastReferences);
    std::vector<Reference> result(s.lastReferences);
    if (s.lastReferences) {
        check(cudaMemcpy(keys.data(), s.keyOut.data, keys.size() * sizeof(uint64_t), cudaMemcpyDeviceToHost),
              "read keys");
        check(cudaMemcpy(indices.data(), s.indexOut.data, indices.size() * sizeof(uint32_t),
                         cudaMemcpyDeviceToHost),
              "read indices");
    }
    for (size_t i = 0; i < result.size(); ++i)
        result[i] = {keys[i], indices[i], s.host[indices[i]].id};
    return result;
}
} // namespace gs
