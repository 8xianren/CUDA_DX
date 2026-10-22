#pragma once
#include "gpu_resources.h"
#include <DirectXMath.h>
#include <map>
namespace aa {
// 时间以秒计，camera为相机世界X坐标。前后时刻共同确定物体/相机运动；
// reset时宿主将previous值设为current，避免首帧制造不存在的速度。
// jitterX/Y是内部渲染像素单位的几何偏移（右/下为正），不属于物理运动。
// lodBias只调材质mip采样；a2c请求MSAA alpha-to-coverage实验。
// outputAspect=0沿用目标宽高；跨SDK质量比较显式填输出宽高比，防止内部整数
// 尺寸舍入把相机视锥也改掉。viewport尺寸与投影宽高比是两个独立概念。
struct SceneFrame {float time=0,previousTime=0,camera=0,previousCamera=0,jitterX=0,jitterY=0,lodBias=0,outputAspect=0;bool a2c=false;};
// MRT契约：color线性HDR；motionDepth=(无jitter prev-current UV,当前viewZ,预期prevViewZ)；
// linearDepth供TAA上一帧查询；velocity单独保存render-pixel单位供SDK；reactive为透明区域。
// 前五项是同一次draw写入的五个RTV，depth是独立深度附件；所有附件尺寸/sample一致。
// linearDepth的R32F颜色通道存正的观察空间z（距离单位）；depth的R32_TYPELESS存储
// 经D32_FLOAT DSV写入投影后的z/w（通常0..1），二者数值与使用目的不能混用。
// Targets拥有纹理，Scene::Render只借用；重建/SDK输入的状态转换由后续阶段负责。
struct Targets {Texture color,motionDepth,linearDepth,velocity,reactive,depth;};
class Scene {
    // c由宿主拥有；以下ComPtr拥有本场景的GPU对象。RTV/DSV heap只有CPU句柄，
    // checkerSrv为shader-visible heap，checker纹理和其SRV在绘制期间均须存活。
    UploadContext& c;fs::path shaders;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12DescriptorHeap> rtv,dsv,checkerSrv;
    ComPtr<ID3D12Resource> vertices,constants,checker,checkerUpload;
    // vb只是地址/大小/stride，不拥有vertices；checkerUpload只在构造上传期存活。
    // constants固定96个256B对象槽，一帧内每次draw独占一个槽，下一帧复用前等Fence。
    D3D12_VERTEX_BUFFER_VIEW vb{};
    // PSO缓存拥有各sample/颜色格式/A2C/透明混合组合；返回的裸指针仅借用。
    std::map<uint64_t,ComPtr<ID3D12PipelineState>> psos;
    ID3D12PipelineState* Pso(UINT samples,DXGI_FORMAT,bool a2c,bool transparent);
public:
    Scene(UploadContext&,const fs::path&);
    Targets Create(UINT,UINT,UINT samples=1,DXGI_FORMAT color=DXGI_FORMAT_R16G16B16A16_FLOAT);
    // 仅记录绘制并写本帧UPLOAD常量，不自行提交。宿主必须保证上次使用这些
    // 常量的命令已经Fence完成，再调用Render；GPU资源生存期覆盖后续消费阶段。
    void Render(Targets&,const SceneFrame&);
    // 与shader相同约定的几何输入，但CPU独立用double投影检查已知点的motion方向。
    static std::array<float,2> PointUV(float x,float y,float z,float camera,UINT w,UINT h);
};
}
