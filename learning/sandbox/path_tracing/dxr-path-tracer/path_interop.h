#pragma once
#include "path_history.h"
#include "path_cuda.h"
#include "path_metrics.h"
#include <memory>
// 可替换消费者：对象在提交前准备资源；Enqueue只能在给定stream上排队，不能持有CPU图像。
// 共享指针属于PathInterop；消费者析构必须早于映射释放。尺寸改变时重建两者。
class PathConsumer {
public:
    virtual ~PathConsumer()=default;
    virtual void Enqueue()=0;
    virtual void CheckCompleted()=0;
};
std::unique_ptr<PathConsumer> MakeOidnConsumer(int device,cudaStream_t stream,float4* packet,UINT width,UINT height,bool guides);
struct InteropResult {
    std::vector<float4> packet;
    std::vector<PathHistoryPixel> source;
    uint64_t ready=0,done=0,allocationBytes=0;
    unsigned stamp=0;
    float consumerMilliseconds=0; // CUDA event包围消费者+审计；排除等待生产者的时间。
    // 同一D3D queue的相邻timestamp差：render、pack、交接间隔、显示及backbuffer复制、HDR读回。
    // 交接间隔包含CUDA和队列/CPU提交空隙，不能再加consumerMilliseconds重复计算。
    std::array<double,5> gpuMilliseconds{};
};
class PathInterop {
    UploadContext& c_;
    UINT width_,height_;
    size_t pixels_,bytes_;
    uint64_t allocation_=0,round_=0;
    int cudaDevice_=-1;
    cudaStream_t stream_=nullptr;
    cudaExternalMemory_t memory_=nullptr;
    cudaExternalSemaphore_t semaphore_=nullptr;
    float4* pointer_=nullptr;
    cudaEvent_t begin_=nullptr,end_=nullptr;
    ComPtr<ID3D12Resource> shared_,readback_,sourceReadback_;
    ComPtr<ID3D12Fence> fence_;
    ComPtr<ID3D12RootSignature> root_;
    ComPtr<ID3D12PipelineState> pack_;
    ComPtr<ID3D12CommandAllocator> allocator_;
    ComPtr<ID3D12GraphicsCommandList> consumerList_;
    PathGpuClock clock_;
    bool frameBegun_=false;
    void ReleaseCuda() noexcept;
public:
    PathInterop(UploadContext&,UINT width,UINT height,const std::filesystem::path& packDxil);
    ~PathInterop();
    PathInterop(const PathInterop&)=delete;
    PathInterop& operator=(const PathInterop&)=delete;
    int Device() const{return cudaDevice_;}
    cudaStream_t Stream() const{return stream_;}
    float4* Pointer() const{return pointer_;}
    uint64_t AllocationBytes() const{return allocation_;}
    // 在本组Record前调用；到Run前不要中途Flush，否则render区间会含CPU空闲时间。
    void BeginFrame(){Require(!frameBegun_,"frame already begun");clock_.Mark(c_.list.Get(),0);frameBegun_=true;}
    // 同步验收边界：Record/pack -> D3D fence -> CUDA -> D3D fence -> Readback，末尾才等CPU。
    // source始终借用；方法成功返回后，所有参与资源均已退役，可以读回、resize和释放。
    // recordDisplay在回接列表上录制，借用shared资源（进入/离开COMMON）；present在其Execute后调用。
    InteropResult Run(PathHistory&,PathConsumer* consumer=nullptr,
        const std::function<void(ID3D12GraphicsCommandList*,ID3D12Resource*)>& recordDisplay={},
        const std::function<void()>& present={});
};
void CudaCheck(cudaError_t error,const char* operation);
