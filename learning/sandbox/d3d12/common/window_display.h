#pragma once
#include "../r13-renderer/dxr_display_reference.h"
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <array>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iterator>
#include <vector>
#include <cstdio>
using Microsoft::WRL::ComPtr;
// R.13与PT.10共用窗口/光栅PSO/交换链/readback；不依赖具体相机或路径记录类型。
// 外部借用device/queue；本对象必须在最后提交Fence完成后销毁。
#pragma comment(lib,"user32.lib")
class WindowDisplay {
public:
    static constexpr UINT Width=480,Height=270;
    struct Constants {UINT sourceRect[4]{0,0,160,90},destination[4]{0,0,480,270};UINT sourceStride=160;float exposureEV=0;UINT pixelByteStride=16,mode=0;};
    static_assert(sizeof(Constants)==48,"Display root constants must be 12 DWORD");
    WindowDisplay(IDXGIFactory6* factory,ID3D12Device5* dev,ID3D12CommandQueue* queue,const std::filesystem::path& shaders,bool resizable=false,const wchar_t* title=L"GPU HDR to SDR validation"):dev_(dev){
        instance_=GetModuleHandleW(nullptr);WNDCLASSW wc{};wc.lpfnWndProc=procedure;wc.hInstance=instance_;wc.lpszClassName=L"SharedHdrDisplayLesson";
        require(RegisterClassW(&wc)!=0,"RegisterClassW");
        // 调用者选择固定客户区或可调整窗口；实际Resize只在渲染线程的Fence安全点应用。
        DWORD style=resizable?WS_OVERLAPPEDWINDOW:WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU;RECT rect{0,0,Width,Height};
        require(AdjustWindowRect(&rect,style,FALSE)!=0,"AdjustWindowRect");
        hwnd_=CreateWindowW(wc.lpszClassName,title,style,
            CW_USEDEFAULT,CW_USEDEFAULT,rect.right-rect.left,rect.bottom-rect.top,nullptr,nullptr,instance_,this);
        require(hwnd_!=nullptr,"CreateWindowW");
        DXGI_SWAP_CHAIN_DESC1 desc{};desc.Width=Width;desc.Height=Height;desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.SampleDesc.Count=1;desc.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;desc.BufferCount=2;
        desc.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;desc.Scaling=DXGI_SCALING_STRETCH;desc.AlphaMode=DXGI_ALPHA_MODE_IGNORE;
        // D3D12的第一个参数是DIRECT queue而不是device；窗口模式、无指定输出限制。
        ComPtr<IDXGISwapChain1> initial;check(factory->CreateSwapChainForHwnd(queue,hwnd_,&desc,nullptr,nullptr,&initial),"CreateSwapChainForHwnd");
        check(initial.As(&swap_),"SwapChain3");check(factory->MakeWindowAssociation(hwnd_,DXGI_MWA_NO_ALT_ENTER),"Disable AltEnter");
        UINT support=0;check(swap_->CheckColorSpaceSupport(DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709,&support),"Check SDR color space");
        require((support&DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT)!=0,"SDR presentation unsupported");
        check(swap_->SetColorSpace1(DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709),"Set SDR color space");
        D3D12_DESCRIPTOR_HEAP_DESC hd{};hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;hd.NumDescriptors=2;
        check(dev->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&rtvs_)),"Create RTV heap");
        stride_=dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
        create_size_resources();
        // 不需要shader-visible heap：历史通过root SRV，RTV通过CPU descriptor handle。
        D3D12_ROOT_PARAMETER params[2]{};params[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;
        params[0].Descriptor.ShaderRegister=0;params[0].ShaderVisibility=D3D12_SHADER_VISIBILITY_PIXEL;
        params[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
        params[1].Constants={0,0,12};params[1].ShaderVisibility=D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_ROOT_SIGNATURE_DESC rd{};rd.NumParameters=2;rd.pParameters=params;rd.Flags=D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
        ComPtr<ID3DBlob> blob,error;HRESULT hr=D3D12SerializeRootSignature(&rd,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&error);
        if(FAILED(hr)&&error)std::fprintf(stderr,"Display root: %s\n",(char*)error->GetBufferPointer());check(hr,"Display root serialization");
        check(dev->CreateRootSignature(0,blob->GetBufferPointer(),blob->GetBufferSize(),IID_PPV_ARGS(&root_)),"Display root");
        auto vs=read_shader(shaders/"dxr_display_vs.dxil"),ps=read_shader(shaders/"dxr_display_ps.dxil");
        D3D12_GRAPHICS_PIPELINE_STATE_DESC p{};p.pRootSignature=root_.Get();p.VS={vs.data(),vs.size()};p.PS={ps.data(),ps.size()};
        p.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
        p.SampleMask=UINT_MAX;p.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;p.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;
        p.RasterizerState.DepthClipEnable=TRUE;p.DepthStencilState.DepthEnable=FALSE;p.DepthStencilState.StencilEnable=FALSE;
        p.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;p.NumRenderTargets=1;p.RTVFormats[0]=desc.Format;p.SampleDesc.Count=1;
        check(dev->CreateGraphicsPipelineState(&p,IID_PPV_ARGS(&pso_)),"Display graphics PSO");
        // Texture的readback行pitch不是width*4：通过API获得256字节对齐的footprint。
        ShowWindow(hwnd_,SW_SHOW);UpdateWindow(hwnd_);
        std::printf("display %ux%u RGBA8_UNORM buffers=2 rowPitch=%u bytes=%llu\n",Width,Height,footprint_.Footprint.RowPitch,(unsigned long long)readbackBytes_);
    }
    ~WindowDisplay(){for(auto& b:back_)b.Reset();swap_.Reset();if(hwnd_)DestroyWindow(hwnd_);UnregisterClassW(L"SharedHdrDisplayLesson",instance_);}
    WindowDisplay(const WindowDisplay&)=delete;WindowDisplay& operator=(const WindowDisplay&)=delete;
    bool pump(){MSG message{};while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){
        if(message.message==WM_QUIT)return false;TranslateMessage(&message);DispatchMessageW(&message);}return !GetPropW(hwnd_,L"CloseRequested");}
    bool suspended()const{return minimized_||pendingW_==0||pendingH_==0;}
    UINT width()const{return width_;}UINT height()const{return height_;}unsigned resizes()const{return resizes_;}
    // 仅消费本窗口收到的按键消息；不读取其它应用的键盘状态。系统自动重复产生连续移动步进。
    bool take_key(UINT key){if(key>=256)return false;bool value=keys_[key];keys_[key]=false;return value;}
    // 调用者必须先等待旧提交并清理旧录制引用。WM_SIZE仅记录意图，不能在回调里释放GPU资源。
    bool apply_resize(){
        if(suspended()||(pendingW_==width_&&pendingH_==height_))return false;
        require(pendingW_<=4096&&pendingH_<=4096,"Resize exceeds lesson 4096 limit");
        readback_.Reset();for(auto& b:back_)b.Reset();
        check(swap_->ResizeBuffers(0,pendingW_,pendingH_,DXGI_FORMAT_UNKNOWN,0),"ResizeBuffers");
        width_=pendingW_;height_=pendingH_;create_size_resources();++resizes_;
        std::printf("resize generation=%u size=%ux%u pitch=%u bytes=%llu\n",resizes_,width_,height_,footprint_.Footprint.RowPitch,(unsigned long long)readbackBytes_);return true;
    }
    // 自动验收走真实Win32尺寸/最小化消息，不伪造WM_SIZE来冒充资源resize。
    void request_client_size(UINT w,UINT h){RECT r{0,0,LONG(w),LONG(h)};
        require(AdjustWindowRect(&r,DWORD(GetWindowLongPtrW(hwnd_,GWL_STYLE)),FALSE)!=0,"Resize AdjustWindowRect");
        require(SetWindowPos(hwnd_,nullptr,0,0,r.right-r.left,r.bottom-r.top,SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE)!=0,"SetWindowPos");}
    void minimize(){ShowWindow(hwnd_,SW_MINIMIZE);}void restore(){ShowWindow(hwnd_,SW_RESTORE);}
    // Camera只需x/y/w/h字段；源行跨度与像素字节步长分开，不能混淆。
    template<class Camera>
    Constants constants(const Camera& camera,float ev,UINT sourceWidth=160,UINT sourceHeight=96,UINT byteStride=16,UINT mode=0)const{
        Constants c;c.sourceRect[0]=camera.x;c.sourceRect[1]=camera.y;c.sourceRect[2]=camera.w;c.sourceRect[3]=camera.h;c.exposureEV=ev;c.sourceStride=sourceWidth;c.pixelByteStride=byteStride;c.mode=mode;
        require(camera.w&&camera.h&&UINT64(camera.x)+camera.w<=sourceWidth&&UINT64(camera.y)+camera.h<=sourceHeight,"Source rectangle out of history bounds");
        UINT dw,dh; // 最大内接等比例矩形；栅格化取整导致最多一像素比例误差，极小窗至少1x1。
        if(UINT64(width_)*camera.h<=UINT64(height_)*camera.w){dw=width_;dh=std::max(1u,UINT(UINT64(width_)*camera.h/camera.w));}
        else {dh=height_;dw=std::max(1u,UINT(UINT64(height_)*camera.w/camera.h));}
        c.destination[0]=(width_-dw)/2;c.destination[1]=(height_-dh)/2;c.destination[2]=dw;c.destination[3]=dh;return c;
    }
    // 外部消费者回接可从COMMON状态及共享buffer的非零平面偏移读取；默认参数保持旧课UAV历史接口。
    // byteOffset只改变根SRV基址，不改变shader的像素/行跨度。调用前后均恢复sourceState。
    void record(ID3D12GraphicsCommandList* list,ID3D12Resource* history,const Constants& constants,
        D3D12_RESOURCE_STATES sourceState=D3D12_RESOURCE_STATE_UNORDERED_ACCESS,UINT64 byteOffset=0){
        // 有效输入受4096尺寸限制，因此shader的整数像素中心映射不会溢出32位。
        auto* s=constants.sourceRect;auto* d=constants.destination;
        require(history&&s[2]&&s[3]&&d[2]&&d[3]&&constants.sourceStride<=4096&&constants.mode<=3,"Invalid display dimensions/mode");
        require(UINT64(s[0])+s[2]<=constants.sourceStride&&UINT64(s[1])+s[3]<=4096,"Display source bounds");
        require(UINT64(d[0])+d[2]<=width_&&UINT64(d[1])+d[3]<=height_,"Display destination bounds");
        require(constants.pixelByteStride>=12&&constants.pixelByteStride%4==0,"Display byte stride");
        UINT64 end=(UINT64(s[1]+s[3]-1)*constants.sourceStride+s[0]+s[2]-1)*constants.pixelByteStride+12;
        require(end<=history->GetDesc().Width&&end<=UINT_MAX,"Display buffer byte bounds");
        display_reference::exposure_multiplier(constants.exposureEV); // 拒绝NaN/超范围补偿。

        UINT index=swap_->GetCurrentBackBufferIndex();seen_[index]++;auto* back=back_[index].Get();
        // transition同时约束之前DXR UAV写与之后PS读；无需在它前面重复加UAV barrier。
        require(byteOffset%4==0&&byteOffset<=history->GetDesc().Width&&end<=history->GetDesc().Width-byteOffset,"Display source offset bounds");
        transition(list,history,sourceState,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        transition(list,back,D3D12_RESOURCE_STATE_PRESENT,D3D12_RESOURCE_STATE_RENDER_TARGET);
        list->SetGraphicsRootSignature(root_.Get());list->SetPipelineState(pso_.Get());
        list->SetGraphicsRootShaderResourceView(0,history->GetGPUVirtualAddress()+byteOffset);
        require(!suspended(),"Never draw a minimized/zero-size window");
        list->SetGraphicsRoot32BitConstants(1,12,&constants,0);
        D3D12_VIEWPORT viewport{0,0,float(width_),float(height_),0,1};D3D12_RECT scissor{0,0,LONG(width_),LONG(height_)};
        list->RSSetViewports(1,&viewport);list->RSSetScissorRects(1,&scissor);
        auto rtv=handle(index);list->OMSetRenderTargets(1,&rtv,FALSE,nullptr);
        list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);list->DrawInstanced(3,1,0,0);
        // 诊断读回直接复制实际Back Buffer，验证真正被Present的字节，不另算一张“参考图片”。
        transition(list,back,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION src{};src.pResource=back;src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;src.SubresourceIndex=0;
        D3D12_TEXTURE_COPY_LOCATION dst{};dst.pResource=readback_.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint_;
        list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
        transition(list,back,D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_PRESENT);
        transition(list,history,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,sourceState);
    }
    void present(){HRESULT hr=swap_->Present(1,0);if(hr==DXGI_STATUS_OCCLUDED)++occluded_;else check(hr,"Present");++presents_;}
    // 兼容R.13 CPU记录；PT.10直接提供自己的线性RGB读取器，不复制旧192B诊断结构。
    template<class Record>
    bool verify(const Record* records,const Constants& cst,const std::filesystem::path& snapshot){
        return verify_rgb([records](size_t i){return std::array<float,3>{records[i].meanCount[0],records[i].meanCount[1],records[i].meanCount[2]};},cst,snapshot);
    }
    bool verify_rgb(const std::function<std::array<float,3>(size_t)>& rgb,const Constants& cst,const std::filesystem::path& snapshot){
        // 调用者已等待本帧Fence；单个readback只在逐帧flush模式下安全，不能直接用于多帧在途。
        unsigned char* bytes=nullptr;D3D12_RANGE read{0,SIZE_T(readbackBytes_)};
        check(readback_->Map(0,&read,reinterpret_cast<void**>(&bytes)),"Map display readback");
        std::ofstream out;if(!snapshot.empty()){out.open(snapshot,std::ios::binary);out<<"P6\n"<<width_<<" "<<height_<<"\n255\n";}
        auto* d=cst.destination;auto* s=cst.sourceRect;
        for(UINT y=0;y<height_;++y)for(UINT x=0;x<width_;++x){auto* p=bytes+footprint_.Offset+size_t(y)*footprint_.Footprint.RowPitch+x*4;
            bool inside=x>=d[0]&&y>=d[1]&&x<d[0]+d[2]&&y<d[1]+d[3];
            // CPU用double像素中心映射独立对照GPU整数表达式；黑边严格检查0而非读取越界history。
            UINT sx=inside?s[0]+UINT(std::floor((double(x-d[0])+.5)*s[2]/d[2])):0;
            UINT sy=inside?s[1]+UINT(std::floor((double(y-d[1])+.5)*s[3]/d[3])):0;
            auto h=rgb(sy*cst.sourceStride+sx);
            for(UINT c=0;c<3;++c){int expected=inside?display_byte(h[c],cst.exposureEV,cst.mode):0;
                unsigned delta=unsigned(std::abs(int(p[c])-expected));maxByteError_=std::max(maxByteError_,delta);if(delta>1)++badChannels_;}
            if(p[3]!=255)++badAlpha_;if(out.is_open())out.write(reinterpret_cast<char*>(p),3);
        }
        if(out.is_open()){out.flush();require(bool(out),"Display PPM write");}
        D3D12_RANGE noWrite{0,0};readback_->Unmap(0,&noWrite);++verified_;return badChannels_==0&&badAlpha_==0;
    }
    bool finish(unsigned expectedFrames=96){std::printf("display presents=%u verified=%u bufferUse=%u/%u occluded=%u maxByteError=%u badRGB=%u badAlpha=%u\n",
        presents_,verified_,seen_[0],seen_[1],occluded_,maxByteError_,badChannels_,badAlpha_);
        return presents_==expectedFrames&&verified_==expectedFrames&&seen_[0]&&seen_[1]&&!badChannels_&&!badAlpha_;}
    unsigned max_byte_error()const{return maxByteError_;}
    unsigned presents()const{return presents_;}
private:
    // mode0为本课正常显示；1硬截断、2漏sRGB、3重复sRGB均为显式诊断对照。
    static unsigned display_byte(float value,float ev,UINT mode){
        double x=value*display_reference::exposure_multiplier(ev);
        require(std::isfinite(x)&&x>=0,"Invalid display HDR");
        double linear=mode==1?std::min(x,1.0):display_reference::reinhard(x);
        double encoded=mode==2?linear:display_reference::srgb_encode(linear);
        if(mode==3)encoded=display_reference::srgb_encode(encoded);
        return display_reference::quantize8(encoded);
    }
    // 头文件自给其D3D辅助函数，避免依赖某个旧宿主的全局函数或CUDA编译环境。
    static void require(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
    static void check(HRESULT hr,const char* message){if(FAILED(hr))throw std::runtime_error(std::string(message)+" HRESULT="+std::to_string(uint32_t(hr)));}
    static void transition(ID3D12GraphicsCommandList* list,ID3D12Resource* resource,D3D12_RESOURCE_STATES before,D3D12_RESOURCE_STATES after){
        D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        b.Transition={resource,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,before,after};list->ResourceBarrier(1,&b);
    }
    static ComPtr<ID3D12Resource> make_buffer(ID3D12Device* dev,D3D12_HEAP_TYPE type,UINT64 bytes,D3D12_RESOURCE_FLAGS flags,D3D12_RESOURCE_STATES state){
        D3D12_HEAP_PROPERTIES heap{};heap.Type=type;heap.CreationNodeMask=heap.VisibleNodeMask=1;
        D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;d.Width=bytes;d.Height=1;
        d.DepthOrArraySize=d.MipLevels=d.SampleDesc.Count=1;d.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;d.Flags=flags;
        ComPtr<ID3D12Resource> r;check(dev->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&d,state,nullptr,IID_PPV_ARGS(&r)),"Display readback allocation");return r;
    }
    void create_size_resources(){
        for(UINT i=0;i<2;++i){check(swap_->GetBuffer(i,IID_PPV_ARGS(&back_[i])),"Get resized buffer");
            D3D12_RENDER_TARGET_VIEW_DESC r{};r.Format=DXGI_FORMAT_R8G8B8A8_UNORM;r.ViewDimension=D3D12_RTV_DIMENSION_TEXTURE2D;
            dev_->CreateRenderTargetView(back_[i].Get(),&r,handle(i));}
        auto bd=back_[0]->GetDesc();require(bd.Width==width_&&bd.Height==height_,"Back Buffer size mismatch");
        dev_->GetCopyableFootprints(&bd,0,1,0,&footprint_,nullptr,nullptr,&readbackBytes_);
        readback_=make_buffer(dev_,D3D12_HEAP_TYPE_READBACK,readbackBytes_,D3D12_RESOURCE_FLAG_NONE,D3D12_RESOURCE_STATE_COPY_DEST);
    }
    static LRESULT CALLBACK procedure(HWND w,UINT m,WPARAM a,LPARAM b){
        if(m==WM_NCCREATE){auto* cs=reinterpret_cast<CREATESTRUCTW*>(b);SetWindowLongPtrW(w,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(cs->lpCreateParams));}
        auto* self=reinterpret_cast<WindowDisplay*>(GetWindowLongPtrW(w,GWLP_USERDATA));
        if(m==WM_SIZE&&self){RECT r{};GetClientRect(w,&r);self->minimized_=a==SIZE_MINIMIZED;
            self->pendingW_=self->minimized_?0:UINT(r.right-r.left);self->pendingH_=self->minimized_?0:UINT(r.bottom-r.top);return 0;}
        if(m==WM_KEYDOWN&&self&&a<256){self->keys_[a]=true;return 0;}
        // WM_CLOSE只记请求，外层先排空GPU再销毁HWND/交换链，避免窗口回调里释放在途资源。
        if(m==WM_CLOSE){SetPropW(w,L"CloseRequested",reinterpret_cast<HANDLE>(1));return 0;}
        return DefWindowProcW(w,m,a,b);
    }
    static std::vector<char> read_shader(const std::filesystem::path& path){std::ifstream f(path,std::ios::binary);
        require(bool(f),"Display DXIL missing: compile VSMain/PSMain first");std::vector<char> v((std::istreambuf_iterator<char>(f)),{});require(!v.empty(),"Empty display DXIL");return v;}
    D3D12_CPU_DESCRIPTOR_HANDLE handle(UINT i)const{auto h=rtvs_->GetCPUDescriptorHandleForHeapStart();h.ptr+=SIZE_T(i)*stride_;return h;}
    HINSTANCE instance_=nullptr;HWND hwnd_=nullptr;UINT stride_=0;
    ID3D12Device5* dev_;UINT width_=Width,height_=Height,pendingW_=Width,pendingH_=Height;bool minimized_=false;unsigned resizes_=0;
    ComPtr<IDXGISwapChain3> swap_;ComPtr<ID3D12DescriptorHeap> rtvs_;ComPtr<ID3D12Resource> back_[2],readback_;
    ComPtr<ID3D12RootSignature> root_;ComPtr<ID3D12PipelineState> pso_;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint_{};UINT64 readbackBytes_=0;
    unsigned presents_=0,verified_=0,seen_[2]{},occluded_=0,maxByteError_=0,badChannels_=0,badAlpha_=0;
    bool keys_[256]{};
};
