#include "material_sampling.h"
#include <stdexcept>
namespace {
struct MeshRecord {UINT firstVertex,firstIndex,indexCount,padding;};
struct MaterialRecord {LinearRGBA factor;UINT textureIndex,samplerIndex,pad0,pad1;};
static_assert(sizeof(MeshRecord)==16 && sizeof(MaterialRecord)==32);
D3D12_TEXTURE_ADDRESS_MODE Address(int mode){
    switch(mode){case 10497:return D3D12_TEXTURE_ADDRESS_MODE_WRAP;
    case 33071:return D3D12_TEXTURE_ADDRESS_MODE_CLAMP;case 33648:return D3D12_TEXTURE_ADDRESS_MODE_MIRROR;}
    throw std::runtime_error("unsupported texture address mode");
}
D3D12_FILTER Filter(const TextureBinding& b){
    // 未指定时选择线性。这是本渲染器策略，不是glTF强制默认。
    // glTF minFilter同时编码缩小与mip过滤；当前只有mip0，不声称已验收跨mip行为。
    D3D12_FILTER_TYPE min=D3D12_FILTER_TYPE_LINEAR,mag=D3D12_FILTER_TYPE_LINEAR,mip=D3D12_FILTER_TYPE_POINT;
    switch(b.minFilter){
    case 0:case 9729:case 9985:break;
    case 9728:case 9984:min=D3D12_FILTER_TYPE_POINT;break;
    case 9986:min=D3D12_FILTER_TYPE_POINT;mip=D3D12_FILTER_TYPE_LINEAR;break;
    case 9987:mip=D3D12_FILTER_TYPE_LINEAR;break;
    default:throw std::runtime_error("unsupported min filter");}
    if(b.magFilter==9728)mag=D3D12_FILTER_TYPE_POINT;
    else if(b.magFilter!=0&&b.magFilter!=9729)throw std::runtime_error("unsupported mag filter");
    return D3D12_ENCODE_BASIC_FILTER(min,mag,mip,D3D12_FILTER_REDUCTION_TYPE_STANDARD);
}
}
// 资源工厂边界：把CPU材质/mesh布局翻译成当前D3D12 shader契约。
// 只创建/Map Upload表与写sampler描述符，不录制Dispatch、不提交队列、不等待Fence。
// 返回对象拥有COM引用，不借用CpuScene的vector或Assimp内存；纹理仍由配套GpuScene持有。
MaterialBindings PrepareMaterialBindings(UploadContext& c,const CpuScene& cpu,const GpuScene& gpu){
    if(cpu.materialAssets.materials.empty()||cpu.materialAssets.materials.size()!=gpu.materials.size())
        throw std::runtime_error("CPU/GPU material count mismatch");
    std::vector<MeshRecord> meshes;for(const auto& m:gpu.meshes)meshes.push_back({m.firstVertex,m.firstIndex,m.indexCount,0});
    std::vector<MaterialRecord> materials;
    D3D12_DESCRIPTOR_HEAP_DESC hd{};hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER;
    hd.NumDescriptors=UINT(cpu.materialAssets.materials.size());hd.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    MaterialBindings out;Check(c.device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&out.samplers)),"material sampler heap");
    const auto stride=c.device->GetDescriptorHandleIncrementSize(hd.Type);
    for(UINT i=0;i<hd.NumDescriptors;++i){
        const auto& source=cpu.materialAssets.materials[i];const auto& binding=source.textures[0];
        if(binding.uvSet!=0)throw std::runtime_error("only UV0 supported");
        D3D12_SAMPLER_DESC desc=MakeTextureSamplerDesc(binding);
        auto handle=out.samplers->GetCPUDescriptorHandleForHeapStart();handle.ptr+=i*stride;
        // CreateSampler返回void；数值先在CPU检查，描述符错误由Debug Layer验收。
        c.device->CreateSampler(&desc,handle);
        materials.push_back({source.baseColor,gpu.materials.at(i).srv[0],i,0,0});
    }
    out.meshes=InstanceUpload(c,meshes.data(),meshes.size()*sizeof(MeshRecord));
    out.materials=InstanceUpload(c,materials.data(),materials.size()*sizeof(MaterialRecord));
    return out;
}
D3D12_SAMPLER_DESC MakeTextureSamplerDesc(const TextureBinding& binding){
    D3D12_SAMPLER_DESC desc{};desc.Filter=Filter(binding);
    desc.AddressU=Address(binding.wrapU);desc.AddressV=Address(binding.wrapV);desc.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    // 当前仅mip0；非比较采样，普通颜色与MR参数共用该转换，不共用各槽的sampler索引。
    desc.MaxAnisotropy=1;desc.ComparisonFunc=D3D12_COMPARISON_FUNC_NEVER;desc.MinLOD=0;desc.MaxLOD=0;return desc;
}
