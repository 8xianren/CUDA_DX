#include "path_guide_validation.h"
#include "energy_lut.h"
#include "../../d3d12/common/window_display.h"
#include <chrono>
#include <iomanip>
struct FinalRect {UINT x=0,y=0,w=0,h=0;};
// 同一积分器/历史/interop用于窗口验收和离屏评测。性能模式只关闭验证层，不切换简化着色器。
int main(int argc,char** argv){
    if(argc!=6){std::cerr<<"path_final scene.gltf shaders energy.bin output verify|benchmark|interactive\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    try{
        Check(com,"COM");std::string mode=argv[5];bool benchmark=mode=="benchmark",interactive=mode=="interactive";
        Require(benchmark||interactive||mode=="verify","final mode");
        std::filesystem::path shaders=argv[2],out=argv[4];std::filesystem::create_directories(out);
        auto cpu=LoadCpuScene(argv[1]);UploadContext c(!benchmark);auto gpu=UploadScene(c,cpu);auto blases=BuildMeshBlases(c,gpu);
        c.SubmitWait();gpu.staging.clear();for(auto& b:blases)b.scratch.Reset();
        auto frame=BuildInstanceFrame(c,cpu,gpu,blases,false);auto iors=TeachingIors(cpu);auto bindings=PreparePbrBindings(c,cpu,gpu,&iors);
        auto energy=pbr_energy::Load(argv[3]);bindings.energy=InstanceUpload(c,energy.data.data(),energy.data.size()*sizeof(float));
        c.SubmitWait();frame.tlas.scratch.Reset(); // AS初始化不进入稳态渲染区间；源实例表仍由frame持有。
        PathConfig cfg;cfg.flags=3;cfg.width=192;cfg.height=96;SetPathCamera(cfg,Vector(cfg.eye),{0,1.7,0});
        auto lights=MakePathLights(cpu,WorldTriangles(cpu),cfg);PathHistory history(c,shaders/"path.dxil",shaders/"accumulate.dxil");
        auto record=[&](UINT samples,bool reset=false){cfg.spp=samples;return history.Record(bindings,gpu,frame,cfg,lights,0,0,reset);};
        auto rays=[](const InteropResult& r){uint64_t n=0;for(auto& p:r.source)n+=p.value.events[0];return n;};
        std::ofstream memory(out/"memory.csv");memory<<"stage,width,height,local_usage_bytes,local_budget_bytes,nonlocal_usage_bytes,frame_logical_bytes,packet_allocation_bytes\n";
        auto memoryRow=[&](const std::string& name,uint64_t allocation){auto m=QueryPathMemory(c);
            memory<<name<<','<<cfg.width<<','<<cfg.height<<','<<m.localUsage<<','<<m.localBudget<<','<<m.nonLocalUsage<<','<<uint64_t(cfg.width)*cfg.height*336<<','<<allocation<<'\n';return m;};
        memoryRow("scene-before-frame",0);
        if(benchmark){
            std::ofstream times(out/"timings.csv");times<<std::setprecision(12)<<"width,height,consumer,repeat,spp,rays,render_ms,pack_ms,handoff_ms,display_copy_ms,readback_ms,cuda_ms,cpu_wall_ms,local_usage_bytes\n";
            std::ofstream quality(out/"quality.csv");quality<<"width,height,seed,spp,rays,prefix\n";
            for(UINT width:{192u,384u}){
                cfg.width=width;cfg.height=width/2;cfg.seed=0;
                PathInterop interop(c,cfg.width,cfg.height,shaders/"pack.dxil");
                // 各模式3次预热+9次计时；每次重置同一32spp随机序列，排除画面内容变化造成的射线数差异。
                for(unsigned kind=0;kind<3;++kind){
                    const char* name=kind==0?"raw":kind==1?"color":"guides";
                    std::unique_ptr<PathConsumer> consumer;if(kind)consumer=MakeOidnConsumer(interop.Device(),interop.Stream(),interop.Pointer(),cfg.width,cfg.height,kind==2);
                    for(int repeat=-3;repeat<9;++repeat){
                        auto begin=std::chrono::steady_clock::now();interop.BeginFrame();record(32,true);auto r=interop.Run(history,consumer.get());
                        double wall=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
                        ValidatePacket(r,kind==0);auto m=QueryPathMemory(c);
                        if(repeat>=0){times<<cfg.width<<','<<cfg.height<<','<<name<<','<<repeat<<",32,"<<rays(r);
                            for(double v:r.gpuMilliseconds)times<<','<<v;times<<','<<r.consumerMilliseconds<<','<<wall<<','<<m.localUsage<<'\n';}
                        if(repeat==8)memoryRow(std::to_string(width)+"-"+name+"-warm",r.allocationBytes);
                    }times.flush();std::cout<<"timing "<<width<<' '<<name<<" 3 warm + 9 measured PASS\n"<<std::flush;
                }
                auto guided=MakeOidnConsumer(interop.Device(),interop.Stream(),interop.Pointer(),cfg.width,cfg.height,true);
                auto color=MakeOidnConsumer(interop.Device(),interop.Stream(),interop.Pointer(),cfg.width,cfg.height,false);
                for(UINT seed:{0u,19u,41u}){
                    cfg.seed=seed;bool first=true;
                    for(UINT target:{4u,16u,64u,256u}){
                        InteropResult result;
                        while(first||history.Count()<target){
                            UINT count=first?0:history.Count(),batch=std::min(32u,target-count);
                            interop.BeginFrame();record(batch,first);first=false;
                            result=interop.Run(history,history.Count()==target?guided.get():nullptr);
                            ValidatePacket(result,history.Count()!=target);
                        }
                        std::string prefix="w"+std::to_string(width)+"-seed"+std::to_string(seed)+"-spp"+std::to_string(target);
                        SavePacket(out,prefix,result,cfg.width,cfg.height);
                        auto plain=interop.Run(history,color.get());ValidatePacket(plain,false);
                        Require(memcmp(result.source.data(),plain.source.data(),plain.source.size()*128)==0,"filter altered quality history");
                        // 仅颜色版本只额外保存output，避免重复五个完全相同的输入平面。
                        std::ofstream file(out/(prefix+"-coloronly.pfm"),std::ios::binary);file<<"PF\n"<<cfg.width<<' '<<cfg.height<<"\n-1.0\n";
                        for(int y=int(cfg.height)-1;y>=0;--y)for(UINT x=0;x<cfg.width;++x)file.write(reinterpret_cast<const char*>(&plain.packet[4*plain.source.size()+size_t(y)*cfg.width+x]),12);
                        Require(bool(file),"quality output write");quality<<cfg.width<<','<<cfg.height<<','<<seed<<','<<target<<','<<rays(result)<<','<<prefix<<'\n';
                    }quality.flush();std::cout<<"quality "<<width<<" seed="<<seed<<" 4/16/64/256 PASS\n"<<std::flush;
                }
                cfg.seed=73;InteropResult reference;
                for(unsigned batch=0;batch<32;++batch){interop.BeginFrame();record(32,batch==0);reference=interop.Run(history);ValidatePacket(reference,true);}
                SavePacket(out,"reference-w"+std::to_string(width),reference,cfg.width,cfg.height);
                memoryRow(std::to_string(width)+"-quality-two-filters",reference.allocationBytes);
                std::cout<<"reference "<<width<<" 1024spp rays="<<rays(reference)<<'\n'<<std::flush;
            }
            Require(times&&quality,"benchmark CSV write");
        }else{
            if(interactive){cfg.width=384;cfg.height=192;}
            ComPtr<IDXGIFactory6> factory;Check(CreateDXGIFactory2(DXGI_CREATE_FACTORY_DEBUG,IID_PPV_ARGS(&factory)),"final window factory");
            WindowDisplay display(factory.Get(),c.device.Get(),c.queue.Get(),shaders,true,L"PT.10 | N raw/color/guides | +/- EV | WASD pan | R reset | Esc");
            std::unique_ptr<PathInterop> interop;
            std::unique_ptr<PathConsumer> guided,color;
            auto rebuild=[&]{
                // 调用处上一Run已等末尾Fence，消费者先释放；不能在滤波器仍引用旧映射时销毁interop。
                guided.reset();color.reset();interop.reset();
                interop=std::make_unique<PathInterop>(c,cfg.width,cfg.height,shaders/"pack.dxil");
                guided=MakeOidnConsumer(interop->Device(),interop->Stream(),interop->Pointer(),cfg.width,cfg.height,true);
                color=MakeOidnConsumer(interop->Device(),interop->Stream(),interop->Pointer(),cfg.width,cfg.height,false);
            };rebuild();
            std::ofstream log(out/"window.csv");log<<"stage,width,height,internal_width,internal_height,spp,generation,consumer,ev,max_byte_error,render_ms,pack_ms,handoff_ms,display_copy_ms,readback_ms\n";
            unsigned frames=0;
            auto show=[&](const char* name,unsigned kind,float ev,bool capture){
                Require(display.pump()&&!display.suspended(),"window unavailable during verification");
                FinalRect rect{0,0,cfg.width,cfg.height};auto controls=display.constants(rect,ev,cfg.width,cfg.height,16);
                PathConsumer* consumer=kind==0?nullptr:kind==1?color.get():guided.get();
                auto result=interop->Run(history,consumer,[&](ID3D12GraphicsCommandList* list,ID3D12Resource* shared){
                    // 回接列表在queue.Wait(done)之后执行；根SRV直接指向output平面，没有CPU图像上传。
                    display.record(list,shared,controls,D3D12_RESOURCE_STATE_COMMON,4ull*cfg.width*cfg.height*16);
                },[&]{display.present();});
                ValidatePacket(result,kind==0);
                Require(display.verify_rgb([&](size_t i){auto p=result.packet[4*result.source.size()+i];return std::array<float,3>{p.x,p.y,p.z};},controls,
                    capture?out/(std::string(name)+".ppm"):std::filesystem::path{}),"denoised display RGB mismatch");
                log<<name<<','<<display.width()<<','<<display.height()<<','<<cfg.width<<','<<cfg.height<<','<<history.Count()<<','<<history.Generation()<<','<<kind<<','<<ev<<','<<display.max_byte_error();
                for(double ms:result.gpuMilliseconds)log<<','<<ms;log<<'\n';++frames;return result;
            };
            interop->BeginFrame();record(32);
            auto original=show("raw",0,0,!interactive);auto unchanged=[&](const InteropResult& r){Require(r.source.size()==original.source.size()&&memcmp(r.source.data(),original.source.data(),r.source.size()*128)==0,"postprocess/output resize altered history");};
            if(interactive){
                unsigned kind=2;float ev=0;double x=0,y=0;
                while(display.pump()){
                    if(display.take_key(VK_ESCAPE))break;
                    if(display.suspended()){MsgWaitForMultipleObjectsEx(0,nullptr,16,QS_ALLINPUT,MWMO_INPUTAVAILABLE);continue;}
                    display.apply_resize();if(display.take_key('N'))kind=(kind+1)%3;
                    if(display.take_key(VK_OEM_PLUS)||display.take_key(VK_ADD))ev=std::min(16.f,ev+.5f);
                    if(display.take_key(VK_OEM_MINUS)||display.take_key(VK_SUBTRACT))ev=std::max(-16.f,ev-.5f);
                    bool moved=false;if(display.take_key('A')){x-=.2;moved=true;}if(display.take_key('D')){x+=.2;moved=true;}
                    if(display.take_key('W')){y+=.2;moved=true;}if(display.take_key('S')){y-=.2;moved=true;}
                    if(moved)SetPathCamera(cfg,{x,3.8+y,15},{x,1.7+y,0});
                    interop->BeginFrame();record(1,display.take_key('R'));show("interactive",kind,ev,false);
                }
            }else{
                unchanged(show("guided",2,0,true));unchanged(show("coloronly",1,0,true));unchanged(show("exposure",2,1,true));
                for(auto size:{std::pair<UINT,UINT>{641,359},{321,481}}){display.request_client_size(size.first,size.second);Require(display.pump()&&display.apply_resize(),"window resize missing");unchanged(show(size.first==641?"odd-window":"portrait-window",2,0,true));}
                display.minimize();Require(display.pump()&&display.suspended(),"minimize missing");auto submitted=c.submitted;
                for(unsigned tick=0;tick<3;++tick){Require(!display.apply_resize(),"minimized resize");Require(display.pump(),"closed minimized window");}
                Require(c.submitted==submitted&&history.Count()==32,"minimize submitted work");
                display.restore();Require(display.pump()&&!display.suspended(),"restore missing");display.apply_resize();unchanged(show("restored",2,0,true));
                SetPathCamera(cfg,{1,3.8,15},{1,1.7,0});interop->BeginFrame();Require(record(4),"camera reset missing");auto moved=show("camera",2,0,true);
                Require(history.Count()==4&&history.Generation()==2,"camera reset count/generation");
                // 与干净一次4spp独立同步Dispatch比较，确认相机改变后没有旧32spp混入。
                auto bytes=PackPathConfig(cfg,lights);auto fresh=DispatchMaterialBuffer(c,bindings,gpu,frame,bytes.data(),bytes.size(),cfg.width,cfg.height,moved.source.size()*sizeof(PathPixel),shaders/"path.dxil");
                for(size_t i=0;i<moved.source.size();++i){PathPixel p;memcpy(&p,fresh.data()+i*sizeof(p),sizeof(p));for(unsigned k=0;k<4;++k)Require(RelativeDifference(p.radiance[k],moved.source[i].value.radiance[k])<2e-5,"camera old history residual");}
                cfg.width=127;cfg.height=65;rebuild();interop->BeginFrame();Require(record(4),"internal resize missing");show("internal-resize",2,0,true);
                Require(history.Count()==4&&history.Generation()==3,"internal resize metadata");
                interop->BeginFrame();record(4,true);show("manual-reset",2,0,true);Require(history.Generation()==4,"manual reset metadata");
                Require(frames==10,"final window stage count");
            }
            bool finished=display.finish(frames);if(!interactive)Require(finished,"window final verification");
            memoryRow("window-two-filters",interop->AllocationBytes());
            Require(bool(log),"window CSV write");
        }
        Require(c.CheckDebug()==0,"final D3D validation");Require(bool(memory),"memory CSV write");
        std::cout<<"PT10 FINAL "<<mode<<" PASS validation="<<c.validationEnabled<<" fence="<<c.submitted<<'/'<<c.fence->GetCompletedValue()<<'\n';
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}
    CoUninitialize();return 0;
}
