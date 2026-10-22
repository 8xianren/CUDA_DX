#pragma once
#include "gaussian.h"
#include <cmath>

namespace gs {
// 这是 CPU/CUDA 共用的纯数学函数；验收另外用已知球形/旋转椭球解析值检查公式，避免只比较同一个错误。
__host__ __device__ inline Projected projectOne(const Gaussian &g, const Camera &c) {
    Projected p{};
    p.id = g.id;
    bool finite = true;
    for (int k = 0; k < 3; ++k)
        finite = finite && isfinite(g.mean[k]) && isfinite(g.scale[k]);
    for (int k = 0; k < 4; ++k)
        finite = finite && isfinite(g.rotation[k]);
    finite = finite && isfinite(g.opacity) && g.shDegree <= 3;
    for (unsigned k = 0; k < 3 * (g.shDegree <= 3 ? (g.shDegree + 1) * (g.shDegree + 1) : 0); ++k)
        finite = finite && isfinite(g.sh[k]);
    if (!finite)
        return p;
    float qn = 0;
    for (int k = 0; k < 4; ++k)
        qn += g.rotation[k] * g.rotation[k];
    if (!isfinite(qn) || qn < 1e-12f || g.scale[0] <= 1e-7f || g.scale[1] <= 1e-7f || g.scale[2] <= 1e-7f ||
        g.opacity < 0 || g.opacity > 1) {
        p.reject = Reject::Degenerate;
        return p;
    }
    float x = 0, y = 0, z = 0;
    for (int k = 0; k < 3; ++k) {
        x += c.worldToCamera[k] * g.mean[k];
        y += c.worldToCamera[4 + k] * g.mean[k];
        z += c.worldToCamera[8 + k] * g.mean[k];
    }
    x += c.worldToCamera[3];
    y += c.worldToCamera[7];
    z += c.worldToCamera[11];
    p.z = z;
    if (z <= c.nearPlane) {
        p.reject = Reject::BehindCamera;
        return p;
    }
    p.u = c.fx * x / z + c.cx;
    p.v = c.cy - c.fy * y / z;
    const float invQ = 1 / sqrtf(qn), w = g.rotation[0] * invQ, a = g.rotation[1] * invQ,
                b = g.rotation[2] * invQ, d = g.rotation[3] * invQ;
    const float r[9] = {1 - 2 * (b * b + d * d), 2 * (a * b - w * d),     2 * (a * d + w * b),
                        2 * (a * b + w * d),     1 - 2 * (a * a + d * d), 2 * (b * d - w * a),
                        2 * (a * d - w * b),     2 * (b * d + w * a),     1 - 2 * (a * a + b * b)};
    // A=W R S，Sigma_camera=A A^T。直接让 J*A 的各行点乘，等价于 J Sigma_camera J^T，少存一个矩阵。
    // 投影 u=fx*x/z+cx,v=cy-fy*y/z，故 J 第二行的 y 导数为负，不能忽略图像坐标翻转。
    float cameraAxes[9]{};
    for (int row = 0; row < 3; ++row)
        for (int col = 0; col < 3; ++col)
            for (int k = 0; k < 3; ++k)
                cameraAxes[row * 3 + col] += c.worldToCamera[row * 4 + k] * r[k * 3 + col] * g.scale[col];
    float jx[3], jy[3];
    for (int k = 0; k < 3; ++k) {
        jx[k] = c.fx / z * cameraAxes[k] - c.fx * x / (z * z) * cameraAxes[6 + k];
        jy[k] = -c.fy / z * cameraAxes[3 + k] + c.fy * y / (z * z) * cameraAxes[6 + k];
    }
    p.xx = .3f;
    p.yy = .3f;
    p.xy = 0;
    for (int k = 0; k < 3; ++k) {
        p.xx += jx[k] * jx[k];
        p.xy += jx[k] * jy[k];
        p.yy += jy[k] * jy[k];
    }
    float det = p.xx * p.yy - p.xy * p.xy;
    if (!isfinite(det) || det <= 1e-8f) {
        p.reject = Reject::Degenerate;
        return p;
    }
    p.conic[0] = p.yy / det;
    p.conic[1] = -p.xy / det;
    p.conic[2] = p.xx / det;
    const float half = (p.xx + p.yy) * .5f;
    const float lambda = half + sqrtf(fmaxf(0, (p.xx - p.yy) * (p.xx - p.yy) * .25f + p.xy * p.xy));
    const float radius = ceilf(3 * sqrtf(lambda));
    if (!isfinite(radius) || radius > c.maxRadiusPixels) {
        p.reject = Reject::Oversize;
        return p;
    }
    if (p.u + radius < 0 || p.v + radius < 0 || p.u - radius >= c.width || p.v - radius >= c.height) {
        p.reject = Reject::Offscreen;
        return p;
    }
    p.minX = (int)fmaxf(0, floorf(p.u - radius));
    p.minY = (int)fmaxf(0, floorf(p.v - radius));
    p.maxX = (int)fminf((float)c.width, ceilf(p.u + radius));
    p.maxY = (int)fminf((float)c.height, ceilf(p.v + radius));
    p.tileMinX = p.minX / 16;
    p.tileMinY = p.minY / 16;
    p.tileMaxX = (p.maxX + 15) / 16;
    p.tileMaxY = (p.maxY + 15) / 16;
    p.tileCount = (p.tileMaxX - p.tileMinX) * (p.tileMaxY - p.tileMinY);
    if (!p.tileCount) {
        p.reject = Reject::Offscreen;
        return p;
    }
    // 相机位置 C=-W^T t，仅支持刚体相机。SH 输入世界空间单位方向 (mean-C)，没有旋转几何的副作用。
    float v[3];
    float length2 = 0;
    for (int k = 0; k < 3; ++k) {
        v[k] = g.mean[k];
        for (int row = 0; row < 3; ++row)
            v[k] += c.worldToCamera[row * 4 + k] * c.worldToCamera[row * 4 + 3];
        length2 += v[k] * v[k];
    }
    const float invLength = 1 / sqrtf(fmaxf(length2, 1e-20f));
    float sx = v[0] * invLength, sy = v[1] * invLength, sz = v[2] * invLength;
    float sh[16] = {.28209479177387814f, -.4886025119029199f * sy, .4886025119029199f * sz,
                    -.4886025119029199f * sx};
    sh[4] = 1.0925484305920792f * sx * sy;
    sh[5] = -1.0925484305920792f * sy * sz;
    sh[6] = .31539156525252005f * (2 * sz * sz - sx * sx - sy * sy);
    sh[7] = -1.0925484305920792f * sx * sz;
    sh[8] = .5462742152960396f * (sx * sx - sy * sy);
    sh[9] = -.5900435899266435f * sy * (3 * sx * sx - sy * sy);
    sh[10] = 2.890611442640554f * sx * sy * sz;
    sh[11] = -.4570457994644658f * sy * (4 * sz * sz - sx * sx - sy * sy);
    sh[12] = .3731763325901154f * sz * (2 * sz * sz - 3 * sx * sx - 3 * sy * sy);
    sh[13] = -.4570457994644658f * sx * (4 * sz * sz - sx * sx - sy * sy);
    sh[14] = 1.445305721320277f * sz * (sx * sx - sy * sy);
    sh[15] = -.5900435899266435f * sx * (sx * sx - 3 * sy * sy);
    for (int ch = 0; ch < 3; ++ch) {
        float value = .5f;
        for (unsigned k = 0; k < (g.shDegree + 1) * (g.shDegree + 1); ++k)
            value += g.sh[k * 3 + ch] * sh[k];
        p.rgb[ch] = fmaxf(0, value);
    }
    p.opacity = g.opacity;
    p.reject = Reject::Visible;
    return p;
}
} // namespace gs
