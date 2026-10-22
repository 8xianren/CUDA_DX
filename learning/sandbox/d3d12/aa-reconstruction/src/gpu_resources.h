#pragma once
#include "gpu_upload.h"
#include <filesystem>
#include <string>
#include <array>

// F主线复用C/D的设备、队列、Fence和错误检查，新增资源视图/读回组织，
// 不复制人物控制或PT积分器。单队列同步提交是验收基线，不代表多帧生产调度。
namespace aa {
namespace fs=std::filesystem;
// 同一纹理若同时供像素着色器和计算着色器只读，可组合这两个 READ 状态。
// 写状态（RT/UAV/COPY_DEST等）不能随意与它组合；状态转换由Texture::To记录。
constexpr auto ReadState=D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE|D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
// Texture是资源的拥有者：ComPtr持有COM引用；format/尺寸/sample与创建参数一致。
// state是宿主对“已记录命令执行到此处”的状态账本，不是GPU当前进度的查询结果。
// 其他模块借用resource.Get()与视图时不得提前释放/替换它；CPU回收仍由Fence决定。
struct Texture {
    ComPtr<ID3D12Resource> resource;
    D3D12_RESOURCE_STATES state=D3D12_RESOURCE_STATE_COMMON;
    DXGI_FORMAT format=DXGI_FORMAT_UNKNOWN;
    UINT width=0,height=0,samples=1;
    void To(UploadContext&,D3D12_RESOURCE_STATES);
};
// 默认堆二维纹理，只有一个mip/array slice。flags声明RT/DS/UAV等用途，
// samples声明每像素样本数；clearColor只提供优化清除值，不执行Clear命令。
Texture MakeTexture(UploadContext&,UINT w,UINT h,DXGI_FORMAT,D3D12_RESOURCE_FLAGS,UINT samples=1,const float* clearColor=nullptr);
// Heap返回描述符槽位的拥有者；句柄只定位其中一个槽，不拥有heap或texture。
// visible=true只用于GPU会解引用的CBV/SRV/UAV表；RTV/DSV是CPU侧描述符。
ComPtr<ID3D12DescriptorHeap> Heap(UploadContext&,D3D12_DESCRIPTOR_HEAP_TYPE,UINT,bool visible=false);
D3D12_CPU_DESCRIPTOR_HANDLE Cpu(UploadContext&,ID3D12DescriptorHeap*,UINT index=0);
D3D12_GPU_DESCRIPTOR_HANDLE Gpu(UploadContext&,ID3D12DescriptorHeap*,UINT index=0);
// Srv/Uav将“如何解释资源”的view写入调用者指定槽位；不会创建像素存储，
// 也不会转换资源状态。这组助手只支持普通单样本Texture2D，MSAA需先Resolve。
void Srv(UploadContext&,Texture&,ID3D12DescriptorHeap*,UINT);
void Uav(UploadContext&,Texture&,ID3D12DescriptorHeap*,UINT);
std::vector<uint8_t> Shader(const fs::path&);
ComPtr<ID3D12RootSignature> Root(UploadContext&,const D3D12_ROOT_SIGNATURE_DESC&);
void Viewport(UploadContext&,UINT,UINT);
// ReadTexture会记录COPY_SOURCE转换和拷贝，再SubmitWait后Map；返回CPU拥有的
// 紧密float4数组，索引=(y*width+x)*4+channel，Readback的256B行pitch在此剥除。
// half只做数值解码，不做曝光/色调映射；源纹理返回时仍处于COPY_SOURCE。
std::vector<float> ReadTexture(UploadContext&,Texture&);
// UploadFloat只接收RGBA32F紧密数组，上传并等待完成后才释放临时UPLOAD资源。
// SaveFloat保留线性浮点值；SavePpm是方便查看的8位图，不是数值验收真值。
void UploadFloat(UploadContext&,Texture&,const std::vector<float>&);
void SaveFloat(const fs::path&,const std::vector<float>&);
void SavePpm(const fs::path&,const std::vector<float>&,UINT,UINT,bool tone=true);
// 每个Timer拥有两个timestamp槽与16字节读回区。Begin/End只是记录GPU命令，
// Milliseconds不替调用者等待；本课每帧Fence后读取，下一帧才可复用同两个槽。
// 测得的是两条GPU timestamp之间的队列时间，不含CPU准备、等待或屏幕扫描输出。
struct Timer {
    ComPtr<ID3D12QueryHeap> query;
    ComPtr<ID3D12Resource> readback;
    UINT64 frequency=0;
    explicit Timer(UploadContext&);
    void Begin(UploadContext&);
    void End(UploadContext&);
    double Milliseconds(); // 仅在覆盖ResolveQueryData的Fence完成后调用。
};
// 原生Flip交换链只使用1 sample，F1专门直接Resolve进BackBuffer，F2以后走全屏显示。
// Window拥有HWND、交换链和对两个BackBuffer的引用，借用c（c必须活得更久）。
// Back()返回当前索引的借用引用，不能跨Resize保存。这里是自动验收窗口；
// Resize由测试显式调用，并非包含最小化/拖动尺寸/多帧调度的完整引擎窗口层。
class Window {
    UploadContext& c;
    HWND hwnd=nullptr;
    ComPtr<IDXGISwapChain3> swap;
    std::array<Texture,2> buffers;
public:
    UINT width,height,presents=0;
    Window(UploadContext&,UINT,UINT);
    ~Window();
    Texture& Back();
    void Resize(UINT,UINT);
    void Present();
};
}
