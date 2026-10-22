#pragma once
#include "gpu_resources.h"
#include "temporal_contract.h"
#include <map>
namespace aa {
class PostChain {
    UploadContext& c;fs::path shaders;
    ComPtr<ID3D12RootSignature> computeRoot,displayRoot;
    ComPtr<ID3D12DescriptorHeap> descriptors,rtv;
    std::map<std::string,ComPtr<ID3D12PipelineState>> compute;
    std::map<DXGI_FORMAT,ComPtr<ID3D12PipelineState>> display;
    Texture coefficients[2];UINT cursor=0;
    ID3D12PipelineState* Compute(const std::string&);
public:
    PostChain(UploadContext&,const fs::path&);
    void BeginFrame(){cursor=0;} // 只在上一帧Fence完成后复用descriptor槽。
    void Dispatch(const std::string&,const PostConstants&,Texture& current,Texture& history,
                  Texture& motion,Texture& depth,Texture& reactive,Texture& out,Texture& diagnostic);
    void Nis(Texture& input,Texture& output);
    void Display(Texture& input,Texture& output,UINT mode=3,float exposure=0,bool ui=false,UINT frame=0);
};
}
