#pragma once
#include "path_scene.h"
#include <array>
// 历史键只包含线性积分目标/采样策略，排除批大小、样本偏移和后续显示曝光。
// revision由场景编辑入口递增；相机值/尺寸/灯强度等直接比较。CPU原始结构可能有padding，
// 因此逐字段构造数组再比较，不能对任意C++配置直接memcmp。
struct PathHistoryKey {
    std::array<float,23> floats{};
    std::array<uint32_t,8> integers{};
    uint64_t sceneRevision=0,materialRevision=0;
    bool operator==(const PathHistoryKey& b) const {
        return floats==b.floats&&integers==b.integers&&sceneRevision==b.sceneRevision&&materialRevision==b.materialRevision;
    }
};
PathHistoryKey MakeHistoryKey(const PathConfig&,uint64_t sceneRevision,uint64_t materialRevision);
struct PathHistoryPixel {PathPixel value;uint32_t count=0,generation=0,guideMode=0,pad1=0;};
static_assert(sizeof(PathHistoryPixel)==128);
// Record可连续录制多批，期间无CPU读回或Fence等待。对象拥有批次输出、历史、PSO和配置上传。
// Flush只提交/等Fence/回收上传；Readback额外复制历史用于验收。两者都不是生产帧调度器。
// 外部场景资源在Flush/Readback完成前不得替换。Resize需要完成已有录制批次后才能释放旧buffer。
// 正常退出也必须先Flush或Readback，再析构本对象；析构函数不会隐式提交仍在录制的命令。
class PathHistory {
    UploadContext& context_;
    MaterialRayPipeline rays_;
    ComPtr<ID3D12RootSignature> root_;
    ComPtr<ID3D12PipelineState> accumulate_;
    ComPtr<ID3D12Resource> batch_,history_;
    std::vector<ComPtr<ID3D12Resource>> uploads_;
    PathHistoryKey key_{};
    bool valid_=false;
    UINT width_=0,height_=0,count_=0,generation_=0;
public:
    PathHistory(UploadContext&,const std::filesystem::path& rayDxil,const std::filesystem::path& accumulateDxil);
    // 返回是否开启新一代历史。sampleOffset由内部count决定，调用者传入值被覆盖。
    bool Record(const MaterialBindings&,const GpuScene&,const InstanceFrame&,PathConfig,
        const std::vector<PathLight>&,uint64_t sceneRevision,uint64_t materialRevision,bool forceReset=false);
    // beforeSignal可Present或加入外部消费者队列交接；末尾本地Fence覆盖所有回接到同queue的工作。
    void Flush(const std::function<void()>& beforeSignal = {});
    std::vector<PathHistoryPixel> Readback(const std::function<void()>& beforeSignal = {});
    UINT Count() const {return count_;}
    UINT Generation() const {return generation_;}
    ID3D12Resource* Resource() const {return history_.Get();} // 借用；当前状态始终为UAV。
};
