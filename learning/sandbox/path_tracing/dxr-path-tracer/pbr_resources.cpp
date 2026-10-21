#include "pbr_resources.h"
#include <cmath>
#include <cstring>
#include <stdexcept>
MaterialBindings PreparePbrBindings(UploadContext& c,const CpuScene& cpu,const GpuScene& gpu,const std::vector<float>* dielectricIors){
    if(cpu.materialAssets.materials.empty()||cpu.materialAssets.materials.size()!=gpu.materials.size())throw std::runtime_error("PBR material count mismatch");
    const UINT count=UINT(cpu.materialAssets.materials.size());
    if(dielectricIors&&dielectricIors->size()!=count)throw std::runtime_error("IOR override count");
    if(count>682)throw std::runtime_error("PBR sampler count exceeds 2048");
    MaterialBindings bindings;D3D12_DESCRIPTOR_HEAP_DESC desc{};desc.Type=D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER;
    desc.NumDescriptors=count*3;desc.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    Check(c.device->CreateDescriptorHeap(&desc,IID_PPV_ARGS(&bindings.samplers)),"PBR sampler heap");
    auto stride=c.device->GetDescriptorHandleIncrementSize(desc.Type);std::vector<PbrMaterialRecord> records;
    for(UINT i=0;i<count;++i){const auto& m=cpu.materialAssets.materials[i];
        // 当前主线只支持OPAQUE、几何法线、UV0。未实现的可见性/法线语义显式拒绝，不能静默渲染错。
        if(m.alpha!=AlphaMode::Opaque||m.doubleSided||m.textures[2].image>=0||m.textures[3].image>=0)
            throw std::runtime_error("PBR currently requires opaque single-sided material without normal/AO maps");
        if(!std::isfinite(m.metallic)||!std::isfinite(m.roughness)||m.metallic<0||m.metallic>1||m.roughness<0||m.roughness>1)
            throw std::runtime_error("PBR factor range");
        for(float v:m.baseColor)if(!std::isfinite(v)||v<0||v>1)throw std::runtime_error("PBR base color range");
        for(float v:m.emissive)if(!std::isfinite(v)||v<0)throw std::runtime_error("PBR emission range");
        PbrMaterialRecord r{};std::memcpy(r.base,m.baseColor.data(),16);std::memcpy(r.emission,m.emissive.data(),12);
        if(dielectricIors){float ior=(*dielectricIors)[i];if(!std::isfinite(ior)||ior<0||(ior>0&&(ior<1||ior>3)))throw std::runtime_error("teaching IOR override range");r.emission[3]=ior;}
        r.metallic=m.metallic;r.roughness=m.roughness;r.baseTexture=gpu.materials[i].srv[0];r.mrTexture=gpu.materials[i].srv[1];r.emissionTexture=gpu.materials[i].srv[4];
        r.baseSampler=3*i;r.mrSampler=3*i+1;r.emissionSampler=3*i+2;
        unsigned roles[]{0,1,4};
        for(unsigned j=0;j<3;++j){auto& b=m.textures[roles[j]];if(b.uvSet!=0)throw std::runtime_error("PBR requires UV0");
            auto s=MakeTextureSamplerDesc(b);auto handle=bindings.samplers->GetCPUDescriptorHandleForHeapStart();handle.ptr+=(3*i+j)*stride;
            c.device->CreateSampler(&s,handle);}
        records.push_back(r);
    }
    struct MeshRecord {UINT firstVertex,firstIndex,indexCount,pad;};std::vector<MeshRecord> meshes;
    for(auto& m:gpu.meshes)meshes.push_back({m.firstVertex,m.firstIndex,m.indexCount,0});
    bindings.meshes=InstanceUpload(c,meshes.data(),meshes.size()*sizeof(MeshRecord));
    bindings.materials=InstanceUpload(c,records.data(),records.size()*sizeof(PbrMaterialRecord));return bindings;
}
