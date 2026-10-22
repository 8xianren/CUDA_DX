#include "gpu_resources.h"
#include <DirectXPackedVector.h>
#include <fstream>
#include <cmath>
#include <algorithm>
#include <cstring>
#include <stdexcept>
namespace aa {
// Transition只把barrier加入当前命令列表；此处随即更新CPU账本，以便后续记录
// 使用正确的StateBefore。它既不执行列表，也不等待GPU，不能替代Fence。
void Texture::To(UploadContext& c,D3D12_RESOURCE_STATES next){if(state!=next){Transition(c,resource.Get(),state,next);state=next;}}
Texture MakeTexture(UploadContext& c,UINT w,UINT h,DXGI_FORMAT format,D3D12_RESOURCE_FLAGS flags,UINT samples,const float* clearColor){
    // 给教学数据设有限尺寸上界；底层Check把API失败转为异常，调用者不得继续
    // 使用未创建成功的资源。DEFAULT堆适合GPU访问，CPU读写须经独立上传/读回堆。
    if(!w||!h||w>8192||h>8192)throw std::runtime_error("invalid texture extent");
    Texture t;t.width=w;t.height=h;t.format=format;t.samples=samples;
    D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;d.Width=w;d.Height=h;
    d.DepthOrArraySize=d.MipLevels=1;d.Format=format;d.SampleDesc.Count=samples;d.Flags=flags;
    D3D12_HEAP_PROPERTIES hp{};hp.Type=D3D12_HEAP_TYPE_DEFAULT;
    D3D12_CLEAR_VALUE cv{};cv.Format=format;cv.Color[3]=1;if(clearColor)memcpy(cv.Color,clearColor,16);
    bool depth=flags&D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
    // typeless存储可有不同兼容view；深度附件的优化清除格式要匹配D32_FLOAT
    // DSV，而非R32_TYPELESS本身。普通Z采用near→0、far→1，清1配合LESS测试。
    if(depth){cv.Format=DXGI_FORMAT_D32_FLOAT;cv.DepthStencil.Depth=1;}
    const auto* clear=(depth||(flags&D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET))?&cv:nullptr;
    // CommittedResource自带底层分配；初始COMMON不等于已清零。cv仅帮助驱动
    // 优化后面的ClearRenderTarget/DepthStencil，实际初始化由场景Clear完成。
    Check(c.device->CreateCommittedResource(&hp,D3D12_HEAP_FLAG_NONE,&d,t.state,clear,IID_PPV_ARGS(&t.resource)),"F Create texture");return t;
}
ComPtr<ID3D12DescriptorHeap> Heap(UploadContext& c,D3D12_DESCRIPTOR_HEAP_TYPE type,UINT count,bool visible){
    // 描述符存的是访问元数据，不能替资源持有COM引用。即使heap仍存在，
    // 提前销毁纹理也会留下悬空view。GPU可见槽也不能在在途命令读取时覆写。
    D3D12_DESCRIPTOR_HEAP_DESC d{};d.Type=type;d.NumDescriptors=count;d.Flags=visible?D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE:D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
    ComPtr<ID3D12DescriptorHeap> h;Check(c.device->CreateDescriptorHeap(&d,IID_PPV_ARGS(&h)),"F descriptor heap");return h;
}
// 描述符句柄是opaque地址；步长必须向device按heap类型查询，不能假定32/64B。
// CPU handle用于Create*View/绑定RTV，GPU handle用于root descriptor table。
// 两个地址空间不可互换，index的容量约束由拥有heap的模块负责。
D3D12_CPU_DESCRIPTOR_HANDLE Cpu(UploadContext& c,ID3D12DescriptorHeap* h,UINT i){auto p=h->GetCPUDescriptorHandleForHeapStart();p.ptr+=SIZE_T(i)*c.device->GetDescriptorHandleIncrementSize(h->GetDesc().Type);return p;}
D3D12_GPU_DESCRIPTOR_HANDLE Gpu(UploadContext& c,ID3D12DescriptorHeap* h,UINT i){auto p=h->GetGPUDescriptorHandleForHeapStart();p.ptr+=UINT64(i)*c.device->GetDescriptorHandleIncrementSize(h->GetDesc().Type);return p;}
void Srv(UploadContext& c,Texture& t,ID3D12DescriptorHeap* h,UINT i){
    // D32深度资源用R32_TYPELESS创建后，可经R32_FLOAT SRV读同一份32bit值。
    // 这个view只改变解释与访问方式，不会自动将非线性z/w转成线性viewZ。
    D3D12_SHADER_RESOURCE_VIEW_DESC d{};d.Format=t.format==DXGI_FORMAT_R32_TYPELESS?DXGI_FORMAT_R32_FLOAT:t.format;
    d.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;d.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;d.Texture2D.MipLevels=1;
    c.device->CreateShaderResourceView(t.resource.Get(),&d,Cpu(c,h,i));
}
// UAV允许compute写入普通单样本颜色纹理；资源创建时须允许UNORDERED_ACCESS。
// nullptr counter表示不是带计数器的结构化buffer，写后同步由调用者放UAV barrier。
void Uav(UploadContext& c,Texture& t,ID3D12DescriptorHeap* h,UINT i){D3D12_UNORDERED_ACCESS_VIEW_DESC d{};d.Format=t.format;d.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE2D;c.device->CreateUnorderedAccessView(t.resource.Get(),nullptr,&d,Cpu(c,h,i));}
// Shader返回DXIL字节的CPU副本；Root序列化绑定布局，CreateRootSignature复制
// 所需信息，因此函数返回后局部blob可销毁。创建失败交给Check，不能继续绑定空对象。
std::vector<uint8_t> Shader(const fs::path& p){std::ifstream f(p,std::ios::binary);if(!f)throw std::runtime_error("missing shader: "+p.string());return{std::istreambuf_iterator<char>(f),{}};}
ComPtr<ID3D12RootSignature> Root(UploadContext& c,const D3D12_ROOT_SIGNATURE_DESC& d){ComPtr<ID3DBlob>b,e;Check(D3D12SerializeRootSignature(&d,D3D_ROOT_SIGNATURE_VERSION_1,&b,&e),"F serialize root");ComPtr<ID3D12RootSignature>r;Check(c.device->CreateRootSignature(0,b->GetBufferPointer(),b->GetBufferSize(),IID_PPV_ARGS(&r)),"F root");return r;}
void Viewport(UploadContext& c,UINT w,UINT h){D3D12_VIEWPORT v{0,0,float(w),float(h),0,1};D3D12_RECT s{0,0,LONG(w),LONG(h)};c.list->RSSetViewports(1,&v);c.list->RSSetScissorRects(1,&s);}
std::vector<float> ReadTexture(UploadContext& c,Texture& t){
    // 一像素多个sample不能直接当一个float4；由调用者决定Resolve语义。
    // 本函数只读subresource0，不负责压缩纹理、数组、额外mip或任意格式转换。
    if(t.samples!=1)throw std::runtime_error("Resolve MSAA before readback");
    auto d=t.resource->GetDesc();D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp{};UINT rows;UINT64 rowBytes,bytes;
    c.device->GetCopyableFootprints(&d,0,1,0,&fp,&rows,&rowBytes,&bytes);
    // footprint给出buffer中的Offset、对齐后的RowPitch与总字节数；GPU纹理
    // 内部可能是平铺布局，不能按width*bytesPerPixel直接Map默认堆资源。
    auto read=MakeResource(c,BufferDesc(bytes),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    t.To(c,D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION a{},b{};a.pResource=read.Get();a.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;a.PlacedFootprint=fp;
    b.pResource=t.resource.Get();b.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;c.list->CopyTextureRegion(&a,0,0,0,&b,nullptr);
    // read拥有读回buffer，源texture由调用者持有。SubmitWait先执行当前列表，
    // 再Signal/等待Fence，保证Copy完成后才Map；Map本身不提供这项GPU同步。
    // range声明CPU将读取的字节范围以辅助缓存管理；它不是另一种内存拷贝。
    c.SubmitWait();uint8_t* mapped=nullptr;D3D12_RANGE range{0,SIZE_T(bytes)};Check(read->Map(0,&range,reinterpret_cast<void**>(&mapped)),"F read Map");
    std::vector<float> result(size_t(t.width)*t.height*4,0);
    // 逐行跳过对齐空隙，再按真实格式解码。缺失通道保持0，alpha默认1；
    // RG/单通道guide也统一放进float4数组，便于CPU oracle复用同一文件布局。
    for(UINT y=0;y<t.height;++y)for(UINT x=0;x<t.width;++x){auto* p=mapped+fp.Offset+y*fp.Footprint.RowPitch;auto* out=&result[(size_t(y)*t.width+x)*4];out[3]=1;
        if(t.format==DXGI_FORMAT_R16G16B16A16_FLOAT||t.format==DXGI_FORMAT_R16G16_FLOAT){UINT n=t.format==DXGI_FORMAT_R16G16_FLOAT?2:4;for(UINT k=0;k<n;++k)out[k]=DirectX::PackedVector::XMConvertHalfToFloat(reinterpret_cast<uint16_t*>(p)[x*n+k]);}
        else if(t.format==DXGI_FORMAT_R32G32B32A32_FLOAT)memcpy(out,p+x*16,16);
        else if(t.format==DXGI_FORMAT_R32_FLOAT||t.format==DXGI_FORMAT_R32_TYPELESS)out[0]=reinterpret_cast<float*>(p)[x];
        else if(t.format==DXGI_FORMAT_R8G8B8A8_UNORM)for(UINT k=0;k<4;++k)out[k]=p[x*4+k]/255.f;
        else if(t.format==DXGI_FORMAT_R8_UNORM)out[0]=p[x]/255.f;
        else throw std::runtime_error("unsupported readback format");
    }
    // CPU没有写回readback，故Unmap的written range为[0,0)。复制出的vector
    // 独立拥有数据，函数退出后释放read不会影响结果；源状态保持COPY_SOURCE。
    D3D12_RANGE noWrite{0,0};read->Unmap(0,&noWrite);return result;
}
void SaveFloat(const fs::path& p,const std::vector<float>& v){fs::create_directories(p.parent_path());std::ofstream f(p,std::ios::binary);f.write(reinterpret_cast<const char*>(v.data()),v.size()*sizeof(float));if(!f)throw std::runtime_error("write float failed");}
void UploadFloat(UploadContext& c,Texture& t,const std::vector<float>& values){
    // oracle只上传已知RGBA32F布局，元素数包括四个通道；拒绝隐式重解释，
    // 避免把half/RG数据的字节数错当成float4后越界复制。
    if(t.format!=DXGI_FORMAT_R32G32B32A32_FLOAT||values.size()!=size_t(t.width)*t.height*4)throw std::runtime_error("oracle upload requires RGBA32F");
    auto d=t.resource->GetDesc();D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp;UINT rows;UINT64 rowBytes,bytes;c.device->GetCopyableFootprints(&d,0,1,0,&fp,&rows,&rowBytes,&bytes);
    auto upload=MakeResource(c,BufferDesc(bytes),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);uint8_t* dst;D3D12_RANGE noRead{0,0};Check(upload->Map(0,&noRead,reinterpret_cast<void**>(&dst)),"oracle upload Map");
    // noRead表明CPU只写，不需要读取旧缓存内容。按footprint写每一行，Unmap
    // 只结束CPU访问；upload必须保留到后面的CopyTextureRegion Fence完成。
    for(UINT y=0;y<t.height;++y)memcpy(dst+fp.Offset+y*fp.Footprint.RowPitch,values.data()+size_t(y)*t.width*4,size_t(rowBytes));upload->Unmap(0,nullptr);
    t.To(c,D3D12_RESOURCE_STATE_COPY_DEST);D3D12_TEXTURE_COPY_LOCATION a{},b{};a.pResource=t.resource.Get();a.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;b.pResource=upload.Get();b.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;b.PlacedFootprint=fp;c.list->CopyTextureRegion(&a,0,0,0,&b,nullptr);t.To(c,ReadState);c.SubmitWait();
}
// PPM预览可选Reinhard后接sRGB编码，最后量化8bit；它会丢失HDR范围与细微误差。
// 定量比较应读取SaveFloat的线性float32文件，不能对这张预览图反推原始精度。
void SavePpm(const fs::path& p,const std::vector<float>& v,UINT w,UINT h,bool tone){fs::create_directories(p.parent_path());std::ofstream f(p,std::ios::binary);f<<"P6\n"<<w<<" "<<h<<"\n255\n";for(size_t i=0;i<size_t(w)*h;++i)for(int k=0;k<3;++k){float a=std::max(0.f,v[i*4+k]);if(tone){a=a/(1+a);a=a<=.0031308f?12.92f*a:1.055f*std::pow(a,1.f/2.4f)-.055f;}auto b=uint8_t(std::clamp(a,0.f,1.f)*255+.5f);f.put(char(b));}if(!f)throw std::runtime_error("write ppm failed");}
// timestamp没有BeginQuery阶段：两次EndQuery分别写时间点0/1，ResolveQueryData
// 将两个uint64写到readback。频率来自同一command queue，毫秒=差值*1000/频率。
// 显式等待由宿主承担；若跨队列测量，还需时钟/同步设计，不能直接套此同步示例。
Timer::Timer(UploadContext& c){D3D12_QUERY_HEAP_DESC d{};d.Count=2;d.Type=D3D12_QUERY_HEAP_TYPE_TIMESTAMP;Check(c.device->CreateQueryHeap(&d,IID_PPV_ARGS(&query)),"F timestamp heap");readback=MakeResource(c,BufferDesc(16),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);Check(c.queue->GetTimestampFrequency(&frequency),"timestamp frequency");}
void Timer::Begin(UploadContext& c){c.list->EndQuery(query.Get(),D3D12_QUERY_TYPE_TIMESTAMP,0);}
void Timer::End(UploadContext& c){c.list->EndQuery(query.Get(),D3D12_QUERY_TYPE_TIMESTAMP,1);c.list->ResolveQueryData(query.Get(),D3D12_QUERY_TYPE_TIMESTAMP,0,2,readback.Get(),0);}
double Timer::Milliseconds(){UINT64* p;D3D12_RANGE r{0,16};Check(readback->Map(0,&r,reinterpret_cast<void**>(&p)),"timestamp Map");double ms=double(p[1]-p[0])*1000/double(frequency);D3D12_RANGE w{0,0};readback->Unmap(0,&w);return ms;}
static LRESULT CALLBACK WndProc(HWND h,UINT m,WPARAM w,LPARAM l){if(m==WM_CLOSE){DestroyWindow(h);return 0;}return DefWindowProcW(h,m,w,l);}
Window::Window(UploadContext& context,UINT w,UINT h):c(context),width(w),height(h){
    // AdjustWindowRect将期望client像素尺寸换成含边框的window尺寸。
    // 交换链绑定DIRECT queue；Flip discard双缓冲每个buffer为单样本RGBA8，
    // MSAA渲染目标必须另外创建并Resolve，不能把swapchain的sample改成4。
    WNDCLASSW wc{};wc.lpfnWndProc=WndProc;wc.hInstance=GetModuleHandleW(nullptr);wc.lpszClassName=L"FReconstructionLesson";RegisterClassW(&wc);
    RECT r{0,0,LONG(w),LONG(h)};AdjustWindowRect(&r,WS_OVERLAPPEDWINDOW,FALSE);
    hwnd=CreateWindowW(wc.lpszClassName,L"F1-F10 AA reconstruction laboratory",WS_OVERLAPPEDWINDOW,CW_USEDEFAULT,CW_USEDEFAULT,r.right-r.left,r.bottom-r.top,nullptr,nullptr,wc.hInstance,nullptr);if(!hwnd)throw std::runtime_error("F window failed");
    ComPtr<IDXGIFactory4> f;Check(CreateDXGIFactory2(0,IID_PPV_ARGS(&f)),"F swap factory");DXGI_SWAP_CHAIN_DESC1 d{};d.Width=w;d.Height=h;d.Format=DXGI_FORMAT_R8G8B8A8_UNORM;d.SampleDesc.Count=1;d.BufferCount=2;d.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;d.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;
    ComPtr<IDXGISwapChain1> s;Check(f->CreateSwapChainForHwnd(c.queue.Get(),hwnd,&d,nullptr,nullptr,&s),"F swapchain");Check(s.As(&swap),"swap3");f->MakeWindowAssociation(hwnd,DXGI_MWA_NO_ALT_ENTER);ShowWindow(hwnd,SW_SHOW);Resize(w,h);
}
Window::~Window(){if(hwnd&&IsWindow(hwnd))DestroyWindow(hwnd);}
// Present后DXGI可能切换索引，因此每次绘制都重新取当前buffer，不能简单
// 假定奇偶帧固定对应某个地址。buffers持有GetBuffer增加的COM引用。
Texture& Window::Back(){return buffers[swap->GetCurrentBackBufferIndex()];}
void Window::Resize(UINT w,UINT h){
    // 同步基线中所有已提交工作由c的Fence覆盖。先等待，再释放GetBuffer引用，
    // 才可ResizeBuffers；在途命令/外部持有的BackBuffer引用会使此流程不合法。
    // 描述符槽本身不拥有资源；调用者后续为新buffer重新创建RTV，不能沿用旧view。
    c.SubmitWait();for(auto& b:buffers)b.resource.Reset();Check(swap->ResizeBuffers(2,w,h,DXGI_FORMAT_R8G8B8A8_UNORM,0),"F ResizeBuffers");width=w;height=h;
    for(UINT i=0;i<2;++i){auto& b=buffers[i];b.width=w;b.height=h;b.format=DXGI_FORMAT_R8G8B8A8_UNORM;b.state=D3D12_RESOURCE_STATE_PRESENT;Check(swap->GetBuffer(i,IID_PPV_ARGS(&b.resource)),"F backbuffer");}
}
// 先把当前buffer转成PRESENT，再提交绘制，回调中Present，最后在同一queue
// Signal并等待Fence。因此allocator可安全Reset；这不是“Present调用返回就
// 等于屏幕已显示”。窗口消息也在此泵送，本课没有多帧并行或真实显示延迟测量。
void Window::Present(){Back().To(c,D3D12_RESOURCE_STATE_PRESENT);c.SubmitWait([&]{Check(swap->Present(0,0),"F Present");});++presents;MSG m;while(PeekMessageW(&m,nullptr,0,0,PM_REMOVE)){TranslateMessage(&m);DispatchMessageW(&m);}}
}
