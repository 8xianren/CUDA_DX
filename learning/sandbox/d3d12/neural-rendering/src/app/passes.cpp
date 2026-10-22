#include "passes.h"
#include <fstream>
#include <cmath>
#include <algorithm>
#include <cstring>
#include <stdexcept>
#include <set>
namespace neural {
namespace {
template<class T> std::vector<T> Read(const std::filesystem::path& path,size_t count){
    std::ifstream file(path,std::ios::binary|std::ios::ate);
    if(!file||file.tellg()!=std::streamoff(count*sizeof(T)))throw std::runtime_error("invalid cached frame: "+path.string());
    file.seekg(0);std::vector<T> values(count);file.read(reinterpret_cast<char*>(values.data()),count*sizeof(T));
    if(!file)throw std::runtime_error("truncated frame");return values;
}
std::vector<gs::Gaussian> LoadAsset(const std::filesystem::path& path){
    // 不以sizeof(header struct)推测wire padding。24字节头+244字节记录已版本化。
    static_assert(sizeof(gs::Gaussian)==244,"GSBIN v1 record ABI changed");
    std::ifstream file(path,std::ios::binary);char magic[8];uint32_t header[4];
    file.read(magic,8);file.read(reinterpret_cast<char*>(header),16);
    if(!file||std::memcmp(magic,"GSBIN001",8)||header[0]>10000000||!header[0]||header[1]!=244||header[2]>3||header[3])
        throw std::runtime_error("unsupported GSBIN header");
    std::vector<gs::Gaussian> points(header[0]);file.read(reinterpret_cast<char*>(points.data()),points.size()*244);
    if(!file||file.peek()!=EOF)throw std::runtime_error("invalid GSBIN payload");
    // wire文件也是不可信输入；必须在排序和分位计算前拒绝NaN，避免破坏sort的序关系。
    std::set<uint32_t> ids;
    for(const auto& g:points){
        double norm=0;
        for(int k=0;k<3;++k)if(!std::isfinite(g.mean[k])||!std::isfinite(g.scale[k])||g.scale[k]<=0)
            throw std::runtime_error("invalid GSBIN position/scale");
        for(float q:g.rotation){if(!std::isfinite(q))throw std::runtime_error("invalid GSBIN quaternion");norm+=double(q)*q;}
        if(std::abs(norm-1)>1e-4)throw std::runtime_error("GSBIN quaternion not normalized");
        for(float sh:g.sh)if(!std::isfinite(sh))throw std::runtime_error("invalid GSBIN SH");
        if(!std::isfinite(g.opacity)||g.opacity<0||g.opacity>1||g.shDegree!=header[2]||!ids.insert(g.id).second)
            throw std::runtime_error("invalid GSBIN opacity/degree/identity");
    }
    // 保留真实资产位置/尺度；显示归一化是显式的均匀坐标变换，不改变原始导入文件。
    // 使用2%–98%分位包围盒抑制远景离群点；没有删除或挑选高斯来凑验收数量。
    float center[3],extent=0;
    for(int k=0;k<3;++k){std::vector<float> axis;axis.reserve(points.size());for(auto& g:points)axis.push_back(g.mean[k]);
        std::sort(axis.begin(),axis.end());float lo=axis[size_t(.02*(axis.size()-1))],hi=axis[size_t(.98*(axis.size()-1))];
        center[k]=(lo+hi)*.5f;extent=std::max(extent,(hi-lo)*.5f);}
    if(!(extent>0))throw std::runtime_error("degenerate asset bounds");
    for(auto& g:points)for(int k=0;k<3;++k){g.mean[k]=(g.mean[k]-center[k])/extent;g.scale[k]/=extent;}
    return points;
}
}
VolumePass::VolumePass():field(volume::MakeSphereField(128)){}
void VolumePass::Render(const Frame& f){
    volume::Camera c;c.tanHalfFovY=std::tan(25.f*3.14159265359f/180);
    volume::RenderOptions o;o.width=f.width;o.height=f.height;o.step=1.f/128;o.skipEmpty=true;
    field.Render(f.color,c,o,f.stream,f.depth,f.meshRay);
    RayDepthToCameraZ(f.depth,f.width,f.height,f.stream);
}
GaussianPass::GaussianPass(const std::filesystem::path& asset){
    encodedAppearance=!asset.empty();
    auto scene=asset.empty()?gs::makeScene(4096):LoadAsset(asset);
    if(asset.empty())for(auto& g:scene)g.mean[2]-=3.5f;
    renderer.setScene(std::move(scene));
}
void GaussianPass::Render(const Frame& f){
    gs::Camera c;c.width=f.width;c.height=f.height;c.worldToCamera[11]=3;
    c.fx=c.fy=f.height/(2*std::tan(25.f*3.14159265359f/180));c.cx=f.width*.5f;c.cy=f.height*.5f;c.nearPlane=.1f;
    last=renderer.render(c,f.color,f.depth,f.meshZ,f.stream);
    // 参考训练照片通常在sRGB编码空间拟合；先合成其外观值，再解码到本app
    // 的线性输出契约。这不是重新训练为物理辐射场，也不声称复现上游所有合成细节。
    if(encodedAppearance)DecodeAppearance(f.color,f.width*f.height,f.stream);
}
NerfPass::NerfPass(std::filesystem::path p):directory(std::move(p)){}
void NerfPass::Render(const Frame& f){
    if(width!=f.width||height!=f.height){
        if(!((f.width==640&&f.height==360)||(f.width==320&&f.height==240)))
            throw std::runtime_error("cached NeRF camera extent unavailable; export this camera first");
        auto path=directory;if(f.width==320)path/="resize-320x240";
        color=Read<float4>(path/"nerf_color_occluded.f32",size_t(f.width)*f.height);
        depth=Read<float>(path/"nerf_depth_occluded.f32",size_t(f.width)*f.height);width=f.width;height=f.height;
        for(auto p:color)if(!std::isfinite(p.x)||!std::isfinite(p.y)||!std::isfinite(p.z)||!std::isfinite(p.w)||p.w<0||p.w>1.00001f)
            throw std::runtime_error("invalid cached NeRF radiance");
    }
    CudaCheck(cudaMemcpyAsync(f.color,color.data(),color.size()*sizeof(float4),cudaMemcpyHostToDevice,f.stream),"NeRF staging RGBA");
    CudaCheck(cudaMemcpyAsync(f.depth,depth.data(),depth.size()*sizeof(float),cudaMemcpyHostToDevice,f.stream),"NeRF staging depth");
}
}
