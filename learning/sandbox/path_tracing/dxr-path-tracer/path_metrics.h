#pragma once
#include "path_scene.h"
// D3D timestamp只有EndQuery，没有BeginQuery。每个槽写入一次GPU tick；Resolve复制到READBACK，
// 必须等覆盖Resolve的Fence后才能Map。六个槽位属于一个串行帧，禁止跨未退役帧复用。
class PathGpuClock {
    ComPtr<ID3D12QueryHeap> heap_;
    ComPtr<ID3D12Resource> readback_;
    UINT64 frequency_=0;
public:
    explicit PathGpuClock(UploadContext& c){
        D3D12_QUERY_HEAP_DESC desc{};desc.Type=D3D12_QUERY_HEAP_TYPE_TIMESTAMP;desc.Count=6;
        Check(c.device->CreateQueryHeap(&desc,IID_PPV_ARGS(&heap_)),"timestamp query heap");
        readback_=MakeResource(c,BufferDesc(6*sizeof(UINT64)),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
        Check(c.queue->GetTimestampFrequency(&frequency_),"timestamp frequency");Require(frequency_>0,"zero timestamp frequency");
    }
    void Mark(ID3D12GraphicsCommandList* list,UINT index){Require(index<6,"timestamp slot");list->EndQuery(heap_.Get(),D3D12_QUERY_TYPE_TIMESTAMP,index);}
    void Resolve(ID3D12GraphicsCommandList* list){list->ResolveQueryData(heap_.Get(),D3D12_QUERY_TYPE_TIMESTAMP,0,6,readback_.Get(),0);}
    std::array<double,5> ReadCompleted(){
        UINT64* ticks=nullptr;D3D12_RANGE range{0,6*sizeof(UINT64)},empty{0,0};
        Check(readback_->Map(0,&range,reinterpret_cast<void**>(&ticks)),"timestamp Map");
        std::array<UINT64,6> copy{};memcpy(copy.data(),ticks,range.End);readback_->Unmap(0,&empty);
        std::array<double,5> ms{};for(unsigned i=0;i<5;++i){Require(copy[i+1]>=copy[i],"nonmonotonic GPU timestamp");ms[i]=double(copy[i+1]-copy[i])*1000/double(frequency_);}return ms;
    }
};
struct PathMemorySnapshot {UINT64 localUsage=0,localBudget=0,nonLocalUsage=0;};
inline PathMemorySnapshot QueryPathMemory(UploadContext& c){
    ComPtr<IDXGIFactory6> factory;Check(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)),"memory factory");
    ComPtr<IDXGIAdapter3> adapter;Check(factory->EnumAdapterByLuid(c.device->GetAdapterLuid(),IID_PPV_ARGS(&adapter)),"memory adapter LUID");
    DXGI_QUERY_VIDEO_MEMORY_INFO local{},nonlocal{};
    Check(adapter->QueryVideoMemoryInfo(0,DXGI_MEMORY_SEGMENT_GROUP_LOCAL,&local),"local video memory");
    Check(adapter->QueryVideoMemoryInfo(0,DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL,&nonlocal),"nonlocal video memory");
    // CurrentUsage是API报告的当前进程占用，Budget是OS动态预算；都不是整张卡的“已用/物理容量”。
    return {local.CurrentUsage,local.Budget,nonlocal.CurrentUsage};
}
