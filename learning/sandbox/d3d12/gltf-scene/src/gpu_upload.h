#pragma once
#include <windows.h>
#include <wrl/client.h>
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <dxgi1_6.h>
#include <vector>
#include <cstdint>
#include "cpu_scene.h"
using Microsoft::WRL::ComPtr;
void Check(HRESULT hr, const char* operation);
// 本课单DIRECT队列：复制、BLAS和预览串行录制，避免跨队列所有权掩盖上传机制。
struct UploadContext {
    ComPtr<ID3D12Device5> device;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList4> list;
    ComPtr<ID3D12Fence> fence;
    ComPtr<ID3D12InfoQueue> info;
    uint64_t submitted=0;
    UploadContext();
    void SubmitWait(); // 只用于课节验收；真实流式上传应通过Fence延迟回收，不逐批阻塞CPU。
    unsigned CheckDebug();
};
ComPtr<ID3D12Resource> MakeResource(UploadContext&,const D3D12_RESOURCE_DESC&,
    D3D12_HEAP_TYPE,D3D12_RESOURCE_STATES);
D3D12_RESOURCE_DESC BufferDesc(uint64_t bytes);
void Transition(UploadContext&,ID3D12Resource*,D3D12_RESOURCE_STATES,D3D12_RESOURCE_STATES);
struct Pixels {UINT width=0,height=0;std::vector<uint8_t> rgba;};
Pixels DecodeImage(const CpuImage&);
struct MeshRange {
    UINT firstVertex=0,vertexCount=0,firstIndex=0,indexCount=0,material=0;
};
struct GpuImage {
    ComPtr<ID3D12Resource> texture;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    UINT64 copyBytes=0;
    Pixels reference; // 仅验收保留CPU像素，生产按CPU用途选择是否保留。
};
struct GpuMaterial {
    std::array<UINT,5> srv{}; // 每槽保存descriptor索引；同图像可拥有线性和sRGB两个视图。
    std::array<float,4> factor{};
};
struct GpuScene {
    ComPtr<ID3D12Resource> vertices,indices;
    D3D12_VERTEX_BUFFER_VIEW vb{};
    D3D12_INDEX_BUFFER_VIEW ib{};
    ComPtr<ID3D12DescriptorHeap> descriptors;
    UINT descriptorStride=0;
    std::vector<MeshRange> meshes;
    std::vector<GpuMaterial> materials;
    std::vector<GpuImage> images;
    std::vector<D3D12_RAYTRACING_GEOMETRY_DESC> geometry;
    // Upload资源必须活到复制提交的Fence完成，不是Map/Unmap结束就能释放。
    std::vector<ComPtr<ID3D12Resource>> staging;
    std::vector<Vertex> referenceVertices;
    std::vector<uint32_t> referenceIndices;
};
GpuScene UploadScene(UploadContext&,const CpuScene&);
void VerifyCopiesAndBuildBlas(UploadContext&,GpuScene&);
