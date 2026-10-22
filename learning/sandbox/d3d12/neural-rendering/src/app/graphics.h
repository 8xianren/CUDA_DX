#pragma once
#include "shared_texture.h"
#include <map>

namespace neural {
// D3D12 网格/合成模块。只借用 UploadContext；纹理由 FrameResources 拥有。
// CUDA 模块不持有 PSO/descriptor，图形模块也不管理高斯/NeRF 参数。
class Graphics {
public:
    Graphics(UploadContext&,const std::filesystem::path& shaders);
    void Mesh(aa::Texture& color,aa::Texture& linearZ,aa::Texture& depth,bool foreground=true);
    void Composite(aa::Texture& radiance,aa::Texture& mesh,aa::Texture& target,bool useRadiance,bool encode);
private:
    UploadContext& c;
    std::filesystem::path path;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12PipelineState> meshPso;
    std::map<DXGI_FORMAT,ComPtr<ID3D12PipelineState>> compositePso;
    ComPtr<ID3D12DescriptorHeap> srv,rtv,dsv;
};
}
