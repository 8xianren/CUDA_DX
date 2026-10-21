#pragma once
#include "material_sampling.h"
// PT.8/PT.10共享材质主线，继续借用C/D的几何/纹理资源；不复制设备、上传或AS实现。
// t5布局64B，t4仍是16B MeshRecord。返回对象拥有Upload表和sampler heap。
struct PbrMaterialRecord {
    float base[4],emission[4];
    float metallic,roughness;uint32_t baseTexture,mrTexture;
    uint32_t emissionTexture,baseSampler,mrSampler,emissionSampler;
};
static_assert(sizeof(PbrMaterialRecord)==64&&offsetof(PbrMaterialRecord,metallic)==32);
// 可选教学IOR按材质索引提供；0表示原glTF金属粗糙度，正值表示无吸收平滑介质。
// 这是显式教学覆盖，不宣称实现KHR_materials_transmission；写入原本保留的emission.w。
MaterialBindings PreparePbrBindings(UploadContext&,const CpuScene&,const GpuScene&,const std::vector<float>* dielectricIors=nullptr);
