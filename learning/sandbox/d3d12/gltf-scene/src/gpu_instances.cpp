#include "gpu_instances.h"
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <iostream>
ComPtr<ID3D12Resource> InstanceUpload(UploadContext& c,const void* bytes,size_t size) {
    auto resource=MakeResource(c,BufferDesc(size),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
    void* mapped=nullptr;D3D12_RANGE noRead{0,0};Check(resource->Map(0,&noRead,&mapped),"instance upload Map");
    memcpy(mapped,bytes,size);D3D12_RANGE written{0,size};resource->Unmap(0,&written);return resource;
}
std::vector<AccelerationBuffers> BuildMeshBlases(UploadContext& c,const GpuScene& gpu) {
    std::vector<AccelerationBuffers> out;
    for(const auto& geometry:gpu.geometry) {
        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS input{};
        input.Type=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
        input.Flags=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
        input.DescsLayout=D3D12_ELEMENTS_LAYOUT_ARRAY;input.NumDescs=1;input.pGeometryDescs=&geometry;
        out.push_back(BuildAcceleration(c,input));
    }
    return out; // 只按共享mesh定义构建，绝不能放在node-instance循环里重复构建。
}
InstanceFrame BuildInstanceFrame(UploadContext& c,const CpuScene& cpu,const GpuScene& gpu,
    const std::vector<AccelerationBuffers>& blases,bool hideFirst) {
    if(cpu.instances.empty()||cpu.instances.size()>0x1000000u) throw std::runtime_error("instance count outside 24-bit ID range");
    InstanceFrame out;
    for(size_t i=0;i<cpu.instances.size();++i) {
        const auto& instance=cpu.instances[i];const auto& world=cpu.nodes.at(instance.nodeIndex).world;
        // TLAS仅接受仿射矩阵。零缩放导致不可逆变换，本课明确拒绝而不交给驱动猜测。
        const auto& m=world.m;
        for(float x:m) if(!std::isfinite(x)) throw std::runtime_error("nonfinite world");
        if(std::abs(m[12])+std::abs(m[13])+std::abs(m[14])+std::abs(m[15]-1)>1e-6f) throw std::runtime_error("non-affine world");
        const double det=double(m[0])*(double(m[5])*m[10]-double(m[6])*m[9])-double(m[1])*(double(m[4])*m[10]-double(m[6])*m[8])+double(m[2])*(double(m[4])*m[9]-double(m[5])*m[8]);
        if(std::abs(det)<1e-10) throw std::runtime_error("singular world transform");
        out.records.push_back({world,gpu.meshes.at(instance.meshIndex).material,instance.nodeIndex,instance.meshIndex,0});
        D3D12_RAYTRACING_INSTANCE_DESC desc{};
        // CPU World是row-major的4×4；DXR是row-major的3×4，因此逐元素拷贝前三行，不转置。
        for(int r=0;r<3;++r) for(int col=0;col<4;++col) desc.Transform[r][col]=m[r*4+col];
        desc.InstanceID=UINT(i);desc.InstanceMask=(hideFirst&&i==0)?0:0xff;
        desc.InstanceContributionToHitGroupIndex=0; // 所有实例共用一个HitGroup，材质通过InstanceID查表。
        desc.Flags=D3D12_RAYTRACING_INSTANCE_FLAG_TRIANGLE_CULL_DISABLE;
        desc.AccelerationStructure=blases.at(instance.meshIndex).result->GetGPUVirtualAddress();
        out.descriptors.push_back(desc);
        std::cout<<"instance="<<i<<" node="<<instance.nodeIndex<<" mesh="<<instance.meshIndex
                 <<" material="<<out.records.back().material<<" origin="<<m[3]<<","<<m[7]<<","<<m[11]
                 <<" BLAS="<<desc.AccelerationStructure<<" mask="<<desc.InstanceMask<<"\n";
    }
    out.objects=InstanceUpload(c,out.records.data(),out.records.size()*sizeof(InstanceRecord));
    out.instanceUpload=InstanceUpload(c,out.descriptors.data(),out.descriptors.size()*sizeof(D3D12_RAYTRACING_INSTANCE_DESC));
    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS input{};
    input.Type=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
    input.Flags=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
    input.NumDescs=UINT(out.descriptors.size());input.DescsLayout=D3D12_ELEMENTS_LAYOUT_ARRAY;
    input.InstanceDescs=out.instanceUpload->GetGPUVirtualAddress();out.tlas=BuildAcceleration(c,input);
    return out; // 本帧objects/instanceUpload/TLAS及scratch均活到GPU完成，不覆盖上帧仍在读的数据。
}
InstanceCamera MakeInstanceCamera(float panX) {
    // 固定正交观察：eye=(11+panX,1,10)，朝-Z，up=+Y，RH观察坐标；
    // 近远距离1/20，x视域[-7,7]、y[-8,8]，D3D NDC z∈[0,1]。
    // View=T(-eye)，Projection把观察盒子标准化。显式合成P*V，保留R.13的列向量约定。
    InstanceCamera camera;Matrix4 view,projection;
    view.m[3]=-(11+panX);view.m[7]=-1;view.m[11]=-10;
    projection.m={1.f/7,0,0,0, 0,1.f/8,0,0, 0,0,-1.f/19,-1.f/19, 0,0,0,1};
    camera.viewProjection=Multiply(projection,view);
    // 解析逆：NDC→world；近点z=9、远点z=-10。RayGen再从两个点生成射线。
    camera.inverseViewProjection.m={7,0,0,11+panX, 0,8,0,1, 0,0,-19,9, 0,0,0,1};
    auto identity=Multiply(camera.viewProjection,camera.inverseViewProjection);
    for(int r=0;r<4;++r) for(int col=0;col<4;++col)
        if(std::abs(identity.m[r*4+col]-(r==col?1.f:0.f))>1e-5f) throw std::runtime_error("camera inverse mismatch");
    return camera;
}
