#pragma once
#include "gpu_instances.h"
#include <filesystem>

// 所有帧共用离屏目标；同一DIRECT队列天然顺序执行，因此目标本身不需要多份。
// 每帧独立readback/allocator/list用于有限批次验收，绝不reset仍在飞行中的allocator。
struct FrameCommands {
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> list;
    ComPtr<ID3D12Resource> pixels,instances,vertices;
};
struct RenderSettings {
    bool capture=true; // 性能模式禁止每帧图像/顶点读回，验收另行提交。
    unsigned pixelIterations=0;
    ID3D12QueryHeap* timestamps=nullptr;
    ID3D12Resource* timestampReadback=nullptr;
    unsigned queryBase=0;
};
struct Raster {
    InstanceCamera camera=MakeInstanceCamera();
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12PipelineState> pso;
    ComPtr<ID3D12Resource> target,cameraBuffer;
    ComPtr<ID3D12DescriptorHeap> rtv;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    uint64_t copyBytes=0;
    Raster(UploadContext& c,const std::filesystem::path& shader,unsigned width=224,unsigned height=256);
    FrameCommands Record(UploadContext& c,const GpuScene& gpu,const CpuScene& cpu,
                         ID3D12Resource* objects,uint64_t bytes,ID3D12Resource* dynamicVertices=nullptr,
                         const RenderSettings& settings={});
    std::vector<float> ReadPixels(FrameCommands& frame)const;
};
