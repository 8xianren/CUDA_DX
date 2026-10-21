#pragma once
#include "gpu_instances.h"
// 输入每条射线32B，与HLSL一致。近表面短射线只检验命中材质，不构成相机或光照积分器。
struct MaterialRay {float origin[3],tmin;float direction[3],tmax;};
static_assert(sizeof(MaterialRay)==32);
using LinearRGBA=std::array<float,4>;
// 资源所有权与命令执行分开：bindings拥有两张Upload表和sampler heap。
// 必须与生成它的GpuScene配套使用；索引是该场景内的编号，不是跨场景全局句柄。
// 工厂完成只表示CPU准备就绪，不能据此推断其它纹理上传/TLAS构建已在GPU完成。
struct MaterialBindings {
    ComPtr<ID3D12Resource> meshes,materials;
    // 可选t7：PT.8能量表。未使用的旧shader不读取它；调度器绑定有效的备用buffer地址。
    ComPtr<ID3D12Resource> energy;
    ComPtr<ID3D12DescriptorHeap> samplers;
};
MaterialBindings PrepareMaterialBindings(UploadContext&,const CpuScene&,const GpuScene&);
// sampler字段翻译由D.3和后续PBR共用；仅返回CPU描述，不创建GPU资源。
D3D12_SAMPLER_DESC MakeTextureSamplerDesc(const TextureBinding&);
// 可复用的材质DXR管线：只创建一次根签名、State Object和SBT。
// Record只录制，不提交/等待/分配输出。调用者拥有所有输入和输出，并保证：
// 配置处于GENERIC_READ，输出处于UAV；资源与本对象至少活到提交Fence完成。
// 多次写同一输出或交给后续compute时，由调用者插入相应transition/UAV barrier。
class MaterialRayPipeline {
    ComPtr<ID3D12RootSignature> root_;
    RayPipeline pipeline_;
public:
    MaterialRayPipeline(UploadContext&,const std::filesystem::path& dxil);
    void Record(UploadContext&,const MaterialBindings&,const GpuScene&,const InstanceFrame&,
        ID3D12Resource* configuration,ID3D12Resource* output,UINT width,UINT height) const;
};
// t0..t5沿用场景/mesh/material绑定，t6由调用者定义，u0为调用者的输出布局。
// 同步提交/读回实现只保留一份；调用者必须让自定义材质表布局与shader匹配。
std::vector<uint8_t> DispatchMaterialBuffer(UploadContext&,const MaterialBindings&,const GpuScene&,
    const InstanceFrame&,const void* config,size_t configBytes,UINT width,UINT height,size_t outputBytes,
    const std::filesystem::path& dxil);
// 同步验收封装：借用已准备资源，录制Dispatch/Copy，提交并等待，然后返回自有CPU读回。
// GPU生命周期已在本调用内闭合；未来异步版本必须返回/持有pending资源及Fence，而非直接删掉等待。
std::vector<LinearRGBA> SampleHitMaterials(UploadContext&,const MaterialBindings&,const GpuScene&,
    const InstanceFrame&,const std::vector<MaterialRay>&,const std::filesystem::path&);
