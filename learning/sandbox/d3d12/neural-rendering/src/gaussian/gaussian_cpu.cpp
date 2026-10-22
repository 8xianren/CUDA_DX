#include "gaussian.h"
#include "projection_math.cuh"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

namespace gs {
Projected projectCpu(const Gaussian &g, const Camera &c) { return projectOne(g, c); }
std::vector<Reference> referencesCpu(const std::vector<Gaussian> &g, const std::vector<Projected> &projected,
                                     const Camera &c) {
    std::vector<Reference> refs;
    const uint32_t tilesX = (c.width + 15) / 16;
    // CPU 使用 push_back + comparison sort，与 GPU 的 scan 分配 + radix sort 是两条独立列表构造路径。
    for (uint32_t i = 0; i < g.size(); ++i) {
        const auto &p = projected[i];
        if (p.reject != Reject::Visible)
            continue;
        uint32_t bits;
        std::memcpy(&bits, &p.z, 4);
        for (int ty = p.tileMinY; ty < p.tileMaxY; ++ty)
            for (int tx = p.tileMinX; tx < p.tileMaxX; ++tx)
                refs.push_back({(uint64_t(ty * tilesX + tx) << 32) | bits, i, g[i].id});
    }
    std::sort(refs.begin(), refs.end(), [](const Reference &a, const Reference &b) {
        return a.key < b.key || (a.key == b.key && a.id < b.id);
    });
    return refs;
}
std::vector<float4> splatCpu(const std::vector<Projected> &p, const std::vector<Reference> &refs,
                             const Camera &c, const float *mesh) {
    std::vector<float4> out(size_t(c.width) * c.height);
    const unsigned tx = (c.width + 15) / 16, nt = tx * ((c.height + 15) / 16);
    std::vector<size_t> begin(nt, 0), end(nt, 0);
    for (size_t i = 0; i < refs.size(); ++i) {
        unsigned t = unsigned(refs[i].key >> 32);
        if (i == 0 || (refs[i - 1].key >> 32) != t)
            begin[t] = i;
        end[t] = i + 1;
    }
    for (int y = 0; y < c.height; ++y)
        for (int x = 0; x < c.width; ++x) {
            const size_t pixel = size_t(y) * c.width + x;
            const unsigned tile = (y / 16) * tx + x / 16;
            float t = 1, r = 0, g = 0, b = 0;
            for (size_t k = begin[tile]; k < end[tile] && t >= 1e-4f; ++k) {
                const auto &q = p[refs[k].index];
                if (mesh && q.z >= mesh[pixel])
                    continue;
                float dx = x + .5f - q.u, dy = y + .5f - q.v;
                float power = -.5f * (q.conic[0] * dx * dx + 2 * q.conic[1] * dx * dy + q.conic[2] * dy * dy);
                // 明确以椭圆 3σ 支持域截断。块包围矩形只是候选；矩形角落不能当作椭圆内部。
                if (power < -4.5f || power > 0)
                    continue;
                float alpha = std::min(.99f, q.opacity * std::exp(power));
                if (alpha < 1 / 255.f)
                    continue;
                float weight = t * alpha;
                r += weight * q.rgb[0];
                g += weight * q.rgb[1];
                b += weight * q.rgb[2];
                t *= 1 - alpha;
            }
            out[pixel] = make_float4(r, g, b, 1 - t);
        }
    return out;
}
std::vector<Gaussian> makeScene(uint32_t count) {
    std::vector<Gaussian> result(count);
    // 确定性的整数散列构造空间云团，不依赖标准库随机数实现。颜色 DC 存储实际 RGB 的逆变换。
    auto random = [](uint32_t x) {
        x ^= x >> 16;
        x *= 0x7feb352d;
        x ^= x >> 15;
        x *= 0x846ca68b;
        x ^= x >> 16;
        return (x & 0x00ffffff) / 16777216.f;
    };
    for (uint32_t i = 0; i < count; ++i) {
        auto &g = result[i];
        g.id = i;
        g.mean[0] = (random(i * 7 + 1) - .5f) * 2.8f;
        g.mean[1] = (random(i * 7 + 2) - .5f) * 1.7f;
        g.mean[2] = 2.5f + random(i * 7 + 3) * 2.0f;
        g.scale[0] = .015f + .055f * random(i * 7 + 4);
        g.scale[1] = .02f + .03f * random(i * 7 + 5);
        g.scale[2] = .025f;
        g.opacity = .15f + .6f * random(i * 7 + 6);
        float angle = random(i * 7 + 7) * 3.14159265f;
        g.rotation[0] = std::cos(angle);
        g.rotation[3] = std::sin(angle);
        for (int ch = 0; ch < 3; ++ch)
            g.sh[ch] = (.1f + .8f * random(i * 11 + ch + 20) - .5f) / .28209479177387814f;
    }
    return result;
}
} // namespace gs
