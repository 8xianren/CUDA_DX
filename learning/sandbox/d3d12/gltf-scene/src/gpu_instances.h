#pragma once
#include "gpu_upload.h"
#include <filesystem>
// C++/HLSL明确按行存储；矩阵仍作用于列向量，不能把存储顺序误当作乘法约定。
struct InstanceRecord {
    Matrix4 world;
    uint32_t material=0,node=0,mesh=0,padding=0;
};
static_assert(sizeof(InstanceRecord)==80);
static_assert(offsetof(InstanceRecord,material)==64 && offsetof(InstanceRecord,mesh)==72);
static_assert(sizeof(D3D12_RAYTRACING_INSTANCE_DESC)==64);
struct InstanceFrame {
    std::vector<InstanceRecord> records;
    std::vector<D3D12_RAYTRACING_INSTANCE_DESC> descriptors;
    ComPtr<ID3D12Resource> objects,instanceUpload;
    AccelerationBuffers tlas;
};
std::vector<AccelerationBuffers> BuildMeshBlases(UploadContext&,const GpuScene&);
InstanceFrame BuildInstanceFrame(UploadContext&,const CpuScene&,const GpuScene&,const std::vector<AccelerationBuffers>&,bool hideFirst);
struct InstanceCamera {
    Matrix4 viewProjection,inverseViewProjection;
    uint32_t width=224,height=256,pad0=0,pad1=0;
};
static_assert(sizeof(InstanceCamera)==144);
InstanceCamera MakeInstanceCamera(float panX=0);
using HitIds=std::array<uint32_t,4>; // instance+1,material+1,primitive+1,0；全零表示miss。
struct InstanceImages {std::vector<HitIds> raster,ray;};
InstanceImages RenderInstances(UploadContext&,const GpuScene&,const InstanceFrame&,const InstanceCamera&,
    const std::filesystem::path& rasterShader,const std::filesystem::path& dxil);
ComPtr<ID3D12Resource> InstanceUpload(UploadContext&,const void*,size_t);
// D.2/D.3共用同一套16B payload、三导出符号与单HitGroup管线装配。
struct RayPipeline {ComPtr<ID3D12StateObject> state;ComPtr<ID3D12Resource> table;};
RayPipeline CreateLessonRayPipeline(UploadContext&,ID3D12RootSignature*,const std::filesystem::path&);
