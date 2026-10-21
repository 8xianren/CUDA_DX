#include "path_history.h"
#include "energy_lut.h"
#include "../../d3d12/common/window_display.h"
#include <iostream>
#include <iomanip>

struct DisplayRect {UINT x=0,y=0,w=0,h=0;};
using HistoryImage=std::vector<PathHistoryPixel>;
void ValidateHistory(const HistoryImage& pixels,UINT count,UINT generation){
    for(const auto& p:pixels){
        Require(p.count==count&&p.generation==generation,"viewer history metadata");
        Require(p.value.errors[0]==0&&p.value.errors[1]==0,"viewer path error");
        for(float v:p.value.radiance)Require(std::isfinite(v)&&v>=0,"viewer invalid linear HDR");
    }
}
int main(int argc,char** argv){
    if(argc!=6){std::cerr<<"path_viewer scene.gltf shader-directory energy.bin output-directory verify|interactive\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    try{
        Check(com,"COM");const bool interactive=std::string(argv[5])=="interactive";
        Require(interactive||std::string(argv[5])=="verify","viewer mode");
        std::filesystem::path shaders=argv[2],out=argv[4];std::filesystem::create_directories(out);
        auto cpu=LoadCpuScene(argv[1]);UploadContext context;auto gpu=UploadScene(context,cpu);auto blases=BuildMeshBlases(context,gpu);
        context.SubmitWait();gpu.staging.clear();for(auto& b:blases)b.scratch.Reset();
        auto frame=BuildInstanceFrame(context,cpu,gpu,blases,false);auto iors=TeachingIors(cpu);
        auto bindings=PreparePbrBindings(context,cpu,gpu,&iors);auto energy=pbr_energy::Load(argv[3]);
        bindings.energy=InstanceUpload(context,energy.data.data(),energy.data.size()*sizeof(float));
        PathConfig cfg;cfg.width=384;cfg.height=192;cfg.spp=8;SetPathCamera(cfg,Vector(cfg.eye),{0,1.7,0});
        auto lights=MakePathLights(cpu,WorldTriangles(cpu),cfg);
        PathHistory history(context,shaders/"path.dxil",shaders/"accumulate.dxil");
        ComPtr<IDXGIFactory6> factory;Check(CreateDXGIFactory2(DXGI_CREATE_FACTORY_DEBUG,IID_PPV_ARGS(&factory)),"viewer factory");
        WindowDisplay display(factory.Get(),context.device.Get(),context.queue.Get(),shaders,true,
            L"PT.10 DXR | +/- exposure | WASD pan | R reset | T tone | Esc close");
        // 阶段化日志直接记录实际交换链尺寸、显示矩形、历史计数和代号，避免拿窗口大小冒充内部采样尺寸。
        std::ofstream csv(out/"display.csv");csv<<std::setprecision(12)
            <<"stage,width,height,source_width,source_height,spp,generation,ev,mode,dest_x,dest_y,dest_width,dest_height,max_byte_error\n";
        unsigned rendered=0;
        auto record=[&](UINT spp,bool force=false){cfg.spp=spp;return history.Record(bindings,gpu,frame,cfg,lights,0,0,force);};
        auto show=[&](const std::string& name,float ev,UINT mode,bool capture=true){
            Require(display.pump()&&!display.suspended(),"display closed/minimized during validation");
            DisplayRect rectangle{0,0,cfg.width,cfg.height};auto controls=display.constants(rectangle,ev,cfg.width,cfg.height,sizeof(PathHistoryPixel),mode);
            // 显示直接读取同一DEFAULT历史资源。CPU读回只是验收旁路，没有把图像上传回来显示。
            display.record(context.list.Get(),history.Resource(),controls);
            // Execute→Present→Signal→Wait：Fence既覆盖渲染/读回，也位于Present之后。
            auto image=history.Readback([&]{display.present();});ValidateHistory(image,history.Count(),history.Generation());
            Require(display.verify_rgb([&](size_t i){const auto* p=image[i].value.radiance;return std::array<float,3>{p[0],p[1],p[2]};},controls,
                capture?out/(name+".ppm"):std::filesystem::path{}),"actual back buffer differs from CPU display reference");
            auto* d=controls.destination;csv<<name<<','<<display.width()<<','<<display.height()<<','<<cfg.width<<','<<cfg.height<<','
                <<history.Count()<<','<<history.Generation()<<','<<ev<<','<<mode<<','<<d[0]<<','<<d[1]<<','<<d[2]<<','<<d[3]<<','<<display.max_byte_error()<<'\n';
            ++rendered;return image;
        };
        // 先积累64spp；管线、历史、配置都在GPU通路，批次之间无需CPU图像复制。
        for(unsigned batch=0;batch<8;++batch){record(8);if(batch%4==3)history.Flush();}
        auto original=history.Readback();ValidateHistory(original,64,1);
        if(interactive){
            float ev=0;UINT mode=0;double panX=0,panY=0;bool first=true;
            while(display.pump()){
                if(display.take_key(VK_ESCAPE))break;
                // 最小化暂停采样与Present；WM_SIZE仅记录意图，资源重建在上一帧Fence完成后进行。
                if(display.suspended()){MsgWaitForMultipleObjectsEx(0,nullptr,16,QS_ALLINPUT,MWMO_INPUTAVAILABLE);continue;}
                display.apply_resize();
                if(display.take_key(VK_OEM_PLUS)||display.take_key(VK_ADD))ev=std::min(16.f,ev+.5f);
                if(display.take_key(VK_OEM_MINUS)||display.take_key(VK_SUBTRACT))ev=std::max(-16.f,ev-.5f);
                if(display.take_key('T'))mode=1-mode;
                bool moved=false;
                if(display.take_key('A')){panX-=.2;moved=true;}if(display.take_key('D')){panX+=.2;moved=true;}
                if(display.take_key('W')){panY+=.2;moved=true;}if(display.take_key('S')){panY-=.2;moved=true;}
                if(moved)SetPathCamera(cfg,{panX,3.8+panY,15},{panX,1.7+panY,0});
                bool force=display.take_key('R');if(!first||moved||force)record(1,force);first=false;
                // 交互入口沿用同步参考路径，便于诊断；此时每帧仍读回，不作为最终性能基准。
                show("interactive-"+std::to_string(rendered),ev,mode,false);
            }
        }else{
            for(auto entry:{std::pair<const char*,float>{"ev-minus2",-2},{"ev-zero",0},{"ev-plus2",2}}){
                auto after=show(entry.first,entry.second,0);
                Require(history.Count()==64&&history.Generation()==1&&after.size()==original.size()&&
                    memcmp(after.data(),original.data(),after.size()*sizeof(PathHistoryPixel))==0,"exposure changed linear history");
            }
            // 负对照仍实际绘制并读回；Python对比正常图确认漏编码变暗、重复编码变亮。
            for(auto entry:{std::pair<const char*,UINT>{"omit-srgb",2},{"double-srgb",3},{"hard-clip",1}}){
                auto after=show(entry.first,0,entry.second);
                Require(memcmp(after.data(),original.data(),after.size()*sizeof(PathHistoryPixel))==0,"display mode changed history");
            }
            display.request_client_size(641,359);Require(display.pump(),"window closed");Require(display.apply_resize(),"odd window resize missing");
            auto after=show("odd-window",0,0);Require(history.Count()==64&&history.Generation()==1,"output resize invalidated fixed internal target");
            display.request_client_size(321,481);Require(display.pump(),"window closed");Require(display.apply_resize(),"portrait resize missing");
            after=show("portrait-window",0,0);Require(memcmp(after.data(),original.data(),after.size()*sizeof(PathHistoryPixel))==0,"letterbox changed history");
            display.minimize();Require(display.pump()&&display.suspended(),"minimize event missing");
            auto submitted=context.submitted;auto count=history.Count();auto presents=display.presents();
            for(unsigned i=0;i<3;++i){Require(!display.apply_resize(),"minimized resize");MsgWaitForMultipleObjectsEx(0,nullptr,16,QS_ALLINPUT,MWMO_INPUTAVAILABLE);Require(display.pump(),"closed while minimized");}
            Require(context.submitted==submitted&&history.Count()==count&&display.presents()==presents,"minimize must not dispatch or present");
            display.restore();Require(display.pump()&&!display.suspended(),"restore missing");display.apply_resize();
            Require(!record(4),"unchanged target should continue");show("continued-68spp",0,0);Require(history.Count()==68&&history.Generation()==1,"continuation metadata");
            SetPathCamera(cfg,{1.2,3.8,15},{1.2,1.7,0});Require(record(4),"camera must reset");show("camera-reset",0,0);
            Require(history.Count()==4&&history.Generation()==2,"camera reset metadata");
            // 内部采样尺寸与仅交换链尺寸不同：它改变了像素积分域，必须重置并重分配历史。
            cfg.width=160;cfg.height=90;Require(record(4),"internal resolution must reset");show("internal-resize",0,0);
            Require(history.Count()==4&&history.Generation()==3,"internal resize metadata");
            display.request_client_size(480,270);Require(display.pump(),"window closed");display.apply_resize();
            Require(record(4,true),"manual reset");show("manual-reset",0,0);Require(history.Generation()==4,"manual generation");

            // 合成HDR标尺只检验显示传递函数，不代替前面真实DXR图像。其余112B特征故意与RGB无关。
            // x=1经Reinhard为.5，漏/正常/重复sRGB对应约128/188/223码，便于定位重复编码。
            const float values[]{0,1e-6f,.001f,.00314062f,.00314064f,.01f,.18f,.5f,1,2,4,16,1024,65504};
            const UINT w=UINT(std::size(values)),h=3;std::vector<PathHistoryPixel> ramp(w*h);
            for(UINT y=0;y<h;++y)for(UINT x=0;x<w;++x){auto& p=ramp[y*w+x];
                for(UINT k=0;k<3;++k)p.value.radiance[k]=(y==0||k==y-1)?values[x]:0;
                p.value.radiance[3]=999;p.value.albedo[0]=888;p.count=123;p.generation=456;
            }
            auto upload=InstanceUpload(context,ramp.data(),ramp.size()*sizeof(PathHistoryPixel));
            auto desc=BufferDesc(ramp.size()*sizeof(PathHistoryPixel));desc.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
            auto buffer=MakeResource(context,desc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);
            context.list->CopyBufferRegion(buffer.Get(),0,upload.Get(),0,desc.Width);
            Transition(context,buffer.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            for(auto entry:{std::pair<const char*,UINT>{"probe-normal",0},{"probe-omit",2},{"probe-double",3},{"probe-clip",1}}){
                DisplayRect rectangle{0,0,w,h};auto controls=display.constants(rectangle,0,w,h,sizeof(PathHistoryPixel),entry.second);
                display.record(context.list.Get(),buffer.Get(),controls);context.SubmitWait([&]{display.present();});
                Require(display.verify_rgb([&](size_t i){auto* p=ramp[i].value.radiance;return std::array<float,3>{p[0],p[1],p[2]};},controls,out/(std::string(entry.first)+".ppm")),"GPU display ramp");
                auto* d=controls.destination;csv<<entry.first<<','<<display.width()<<','<<display.height()<<','<<w<<','<<h
                    <<",123,456,0,"<<entry.second<<','<<d[0]<<','<<d[1]<<','<<d[2]<<','<<d[3]<<','<<display.max_byte_error()<<'\n';++rendered;
            }
            Require(rendered==16,"unexpected display stage count");
        }
        // 用户可在交互模式的首帧前关闭；这不是“两个Back Buffer都必须用到”的自动验收场景。
        bool complete=display.finish(rendered);if(!interactive)Require(complete,"display verification summary");
        Require(context.CheckDebug()==0,"viewer debug error");
        Require(bool(csv),"display CSV write failed");
        std::cout<<"PATH DISPLAY PASS frames="<<rendered<<" max_byte_error="<<display.max_byte_error()<<" mode="<<argv[5]<<'\n';
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}
    CoUninitialize();return 0;
}
