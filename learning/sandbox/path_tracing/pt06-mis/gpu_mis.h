#pragma once
#include "gpu_instances.h"
// StructuredBuffer布局，不是cbuffer的16B打包规则。四组16B便于逐字段核对。
struct MisConfig {
    uint32_t width=32,height=32,rounds=64,seed=0;
    uint32_t receiver=0,emitter=0,pad0=0,pad1=0;
    float halfLight=.25f,rho=.8f,le=1,halfView=1.2f;
    float panX=0,panY=0,cameraZ=.5f,pad2=0;
};
struct MisPixel {
    float estimates[4]; // BSDF、NEE、balance、power，均为线性辐亮度。
    uint32_t diagnostics[4]; // 主命中material+1、灯采样命中数、BSDF命中数、保留。
};
static_assert(sizeof(MisConfig)==64 && offsetof(MisConfig,halfLight)==32 && offsetof(MisConfig,panX)==48);
static_assert(sizeof(MisPixel)==32 && offsetof(MisPixel,diagnostics)==16);
// 同步验收入口：返回前等待Fence，局部资源才允许释放。场景/BLAS/TLAS由调用者持有。
std::vector<MisPixel> DispatchMis(UploadContext&,const InstanceFrame&,const MisConfig&,const std::filesystem::path&);
