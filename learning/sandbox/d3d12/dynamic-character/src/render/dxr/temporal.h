#pragma once
#include "path_config.h"
#include "material_sampling.h"
#include <memory>
namespace character {
struct MotionGuide {float position[4],normal[4],previousPixel[4],previousNormal[4];};
static_assert(sizeof(MotionGuide)==64);
class TemporalFilter {
    UploadContext& context_;unsigned width_,height_,slot_=0;bool valid_=false;
    MaterialRayPipeline guidePipeline_;ComPtr<ID3D12RootSignature> root_;ComPtr<ID3D12PipelineState> pipeline_;
    ComPtr<ID3D12Resource> guides_[2],colors_[2],previousVertices_;
    PathConfig previousConfig_{};std::vector<Matrix4> previousWorlds_;
    std::vector<ComPtr<ID3D12Resource>> uploads_;
public:
    TemporalFilter(UploadContext&,unsigned,unsigned,uint64_t,const std::filesystem::path&);
    // currentVertices在NON_PIXEL_SHADER_RESOURCE；linearHistory在UAV。返回颜色在SRV状态。
    ID3D12Resource* Record(const MaterialBindings&,const GpuScene&,const InstanceFrame&,const PathConfig&,ID3D12Resource* linearHistory,bool reset);
    void RetireAfterFence(){uploads_.clear();}
    ID3D12Resource* CurrentGuide()const{return guides_[slot_^1].Get();}
    ID3D12Resource* CurrentColor()const{return colors_[slot_^1].Get();}
};
}
