#pragma once
#include "volume.h"
#include "gaussian.h"
#include "external.h"
#include <filesystem>
#include <memory>
#include <string>
namespace neural {
struct Frame {
    int width,height;
    float4* color;float* depth;const float* meshZ;const float* meshRay;
    cudaStream_t stream;
};
// 每个Pass只借用Frame里的设备指针，所有权在app帧资源。API返回后是否完成
// 由stream与external fence规定，不能因C++函数返回就把color交给D3D12。
class RadiancePass {
public:
    virtual ~RadiancePass()=default;
    virtual const char* Name() const=0;
    virtual void Render(const Frame&)=0;
    virtual size_t RepresentationBytes() const=0;
};
class VolumePass final:public RadiancePass {
    volume::Volume field;
public:
    VolumePass();const char* Name()const override{return "volume";}
    void Render(const Frame&)override;
    size_t RepresentationBytes()const override{return field.StorageBytes();}
};
class GaussianPass final:public RadiancePass {
    gs::Renderer renderer;
    bool encodedAppearance=false;
public:
    gs::Stats last{};
    explicit GaussianPass(const std::filesystem::path& asset={});
    const char* Name()const override{return "gaussian";}
    void Render(const Frame&)override;
    size_t RepresentationBytes()const override{return renderer.scene().size()*sizeof(gs::Gaussian);}
};
// 缓存的NeRF输出属于固定相机契约。CPU文件->cudaMemcpyAsync->共享array
// 是明确的 staging 路径，并非让D3D12直接拥有PyTorch allocator里的张量。
class NerfPass final:public RadiancePass {
    std::filesystem::path directory;
    int width=0,height=0;
    std::vector<float4> color;
    std::vector<float> depth;
public:
    explicit NerfPass(std::filesystem::path);
    const char* Name()const override{return "nerf_cached";}
    void Render(const Frame&)override;
    size_t RepresentationBytes()const override{return color.size()*sizeof(float4)+depth.size()*sizeof(float);}
};
void MeshDepthToRay(const float* z,float* ray,int width,int height,cudaStream_t);
void DecodeAppearance(float4* color,int count,cudaStream_t);
void RayDepthToCameraZ(float* depth,int width,int height,cudaStream_t);
}
