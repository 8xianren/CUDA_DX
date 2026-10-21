#pragma once
#include "ray_buffer_dispatch.h"
// 配置按StructuredBuffer布局：16B整数+16B rho+16B Le+16B轮盘赌配置。
struct PathConfig {uint32_t paths=4096,maxScatters=8,seed=0,mode=0;
    float rho[3]{.6f,.4f,.2f};uint32_t pad0=0;
    float emission[3]{.1f,.2f,.3f};uint32_t pad1=0;
    uint32_t rrMode=0,rrStart=3; // 0关闭，1正确补偿，2故意漏补偿；首次尝试到达rrStart前做决策
    float rrMin=.05f,rrMax=.95f;};
// 每个路径/深度一个128B记录，用于逐顶点审计，不是生产渲染器的像素格式。
struct PathRecord {
    float position[4]; // xyz命中点，w=本段t
    float beta[4]; // xyz抵达时吞吐量，w=当前发光项的BSDF MIS权重
    float radiance[4]; // xyz截至本顶点NEE后的累计值，w=上一跳BSDF PDF
    float lightPoint[4]; // xyz本顶点灯样本，w=DXR可见性
    float direct[4]; // xyz已乘beta的NEE贡献，w=该样本光源策略权重
    float rayDirection[4]; // xyz实际射线方向；避免从经过边界修正的短线段反推方向
    uint32_t diagnostics[4]; // material+1，本顶点TraceRay次数，异常计数，depth
    float roulette[4]; // 存活概率s、独立随机数u、是否做了决策、是否延伸到下一顶点
};
static_assert(sizeof(PathConfig)==64&&offsetof(PathConfig,emission)==32);
static_assert(offsetof(PathConfig,rrMode)==48);
static_assert(sizeof(PathRecord)==128&&offsetof(PathRecord,roulette)==112);
std::vector<PathRecord> Run(UploadContext&,const InstanceFrame&,const PathConfig&,const std::filesystem::path&);
