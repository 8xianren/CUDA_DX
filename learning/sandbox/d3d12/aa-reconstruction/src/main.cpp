#include "scene.h"
#include "post_chain.h"
#include "sdk_upscalers.h"
#include <fstream>
#include <iostream>
#include <iomanip>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <numeric>

using namespace aa;
static void Require(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
// 默认RGBA16F承载线性HDR；oracle另用RGBA32F以隔离half量化误差。
// Texture值对象持有ComPtr，销毁前调用者必须已等待最后一次GPU访问结束。
static Texture Color(UploadContext& c,UINT w,UINT h,DXGI_FORMAT f=DXGI_FORMAT_R16G16B16A16_FLOAT){return MakeTexture(c,w,h,f,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS|D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);}
static void Copy(UploadContext& c,Texture& src,Texture& dst){src.To(c,D3D12_RESOURCE_STATE_COPY_SOURCE);dst.To(c,D3D12_RESOURCE_STATE_COPY_DEST);c.list->CopyResource(dst.resource.Get(),src.resource.Get());}
static double Diff(const std::vector<float>& a,const std::vector<float>& b){Require(a.size()==b.size(),"different image extents");double m=0;for(size_t i=0;i<a.size();++i)if(i%4!=3)m=std::max(m,std::abs(double(a[i])-b[i]));return m;}
static void Finite(const std::vector<float>& v){for(float f:v)Require(std::isfinite(f),"nonfinite GPU output");}
static std::vector<float> LoadFloats(const fs::path& p){std::ifstream f(p,std::ios::binary|std::ios::ate);Require(bool(f),"missing oracle float file");auto size=f.tellg();std::vector<float> v(size_t(size)/4);f.seekg(0);f.read(reinterpret_cast<char*>(v.data()),size);Require(bool(f),"bad float file");return v;}
static void Save(const fs::path& dir,const std::string& name,const std::vector<float>& v,UINT w,UINT h,bool raw=true){SavePpm(dir/(name+".ppm"),v,w,h);if(raw)SaveFloat(dir/(name+".f32"),v);}
static PostConstants Constants(UINT iw,UINT ih,UINT ow,UINT oh){PostConstants p;p.inputWidth=iw;p.inputHeight=ih;p.outputWidth=ow;p.outputHeight=oh;return p;}

static void F1(UploadContext& c,Scene& scene,const fs::path& out){
    // 1×copy、4×clip resolve、4×A2C resolve共享尺寸、几何与时刻。
    // Flip交换链只有单采样BackBuffer；Resolve只合并同尺寸颜色样本，不负责缩放。
    fs::create_directories(out);Window window(c,640,360);std::vector<std::vector<float>> images;
    for(int mode=0;mode<3;++mode){auto target=scene.Create(window.width,window.height,mode?4:1,DXGI_FORMAT_R8G8B8A8_UNORM);SceneFrame f;f.time=f.previousTime=.25f;f.a2c=mode==2;scene.Render(target,f);
        auto& back=window.Back();if(mode){target.color.To(c,D3D12_RESOURCE_STATE_RESOLVE_SOURCE);back.To(c,D3D12_RESOURCE_STATE_RESOLVE_DEST);c.list->ResolveSubresource(back.resource.Get(),0,target.color.resource.Get(),0,back.format);}
        else Copy(c,target.color,back);
        auto pixels=ReadTexture(c,back);SavePpm(out/(mode==0?"noaa.ppm":mode==1?"msaa4.ppm":"a2c4.ppm"),pixels,back.width,back.height,false);images.push_back(std::move(pixels));window.Present();
    }
    size_t changed=0,a2c=0;for(size_t i=0;i<images[0].size();i+=4){changed+=images[0][i]!=images[1][i];a2c+=images[1][i]!=images[2][i];}
    Require(changed>50&&a2c>50,"MSAA and A2C must measurably alter coverage");
    std::ofstream f(out/"summary.json");f<<"{\"pass\":true,\"samples\":[1,4,4],\"msaa_changed_pixels\":"<<changed<<",\"a2c_changed_pixels\":"<<a2c<<",\"swapchain_samples\":1,\"direct_resolve_to_backbuffer\":true,\"presents\":"<<window.presents<<"}";
}
static void F2(UploadContext& c,Scene& scene,PostChain& post,const fs::path& out){
    // ping/pong不与输入alias，先验证恒等映射，再分别验证亮度加权与EV=1倍增。
    // Resize会释放旧BackBuffer引用并等待Fence，随后本地目标按新尺寸重建。
    fs::create_directories(out);Window window(c,640,360);double identityMax=0,grayMax=0,exposureMax=0;
    for(int resize=0;resize<2;++resize){if(resize)window.Resize(512,288);auto t=scene.Create(window.width,window.height);scene.Render(t,{});c.SubmitWait();auto source=ReadTexture(c,t.color);auto ping=Color(c,t.color.width,t.color.height),pong=Color(c,t.color.width,t.color.height);
        post.BeginFrame();post.Display(t.color,ping,0);auto identity=ReadTexture(c,ping);identityMax=std::max(identityMax,Diff(source,identity));
        post.BeginFrame();post.Display(ping,pong,1);auto gray=ReadTexture(c,pong);for(size_t i=0;i<gray.size();i+=4){double expected=.2126*source[i]+.7152*source[i+1]+.0722*source[i+2];for(int k=0;k<3;++k)grayMax=std::max(grayMax,std::abs(gray[i+k]-expected));}
        post.BeginFrame();post.Display(t.color,ping,2,1.f);auto exposure=ReadTexture(c,ping);for(size_t i=0;i<exposure.size();++i)if(i%4!=3)exposureMax=std::max(exposureMax,std::abs(double(exposure[i])-2*source[i]));
        Save(out,resize?"resized-gray":"gray",gray,t.color.width,t.color.height,false);post.BeginFrame();post.Display(t.color,window.Back());window.Present();
    }
    Require(identityMax<.001&&grayMax<.002&&exposureMax<.002,"fullscreen numerical comparison failed");std::ofstream f(out/"summary.json");f<<"{\"pass\":true,\"identity_max\":"<<identityMax<<",\"gray_max\":"<<grayMax<<",\"exposure_max\":"<<exposureMax<<",\"resize\":[[640,360],[512,288]],\"presents\":"<<window.presents<<"}";
}
static void F4(UploadContext& c,Scene& scene,PostChain& post,const fs::path& out){
    // 从当前像素中心撤销jitter，反求对应world point，再逆当前物体旋转/平移，
    // 用上一帧物体变换投影。这个CPU double路径独立于GPU运动矢量着色器。
    // 只选z=7背景与z=3.4运动物体，避免透明混合guide的一层近似污染已知点检查。
    fs::create_directories(out);std::ofstream report(out/"motion.csv");report<<"case,checked,max_uv_error\n";double totalMax=0;UINT total=0;
    for(int mode=0;mode<4;++mode){auto t=scene.Create(320,180);SceneFrame f;f.time=mode==3?1.2f:mode==2?.35f:0;f.previousTime=mode==3?1.f:mode==2?.30f:0;f.camera=mode==1?.15f:0;f.previousCamera=0;f.jitterX=.25f;f.jitterY=-.25f;scene.Render(t,f);auto md=ReadTexture(c,t.motionDepth);UINT checked=0;double maximum=0;
        for(UINT y=0;y<180;++y)for(UINT x=0;x<320;++x){size_t at=(size_t(y)*320+x)*4;float z=md[at+2];if(std::abs(z-7)>1e-4f&&std::abs(z-3.4f)>1e-4f)continue;
            double u=(x+.5-f.jitterX)/320.,v=(y+.5-f.jitterY)/180.;double scale=1/std::tan(DirectX::XM_PIDIV4*.5);double wx=(u-.5)*2*z/scale*320/180+f.camera,wy=(.5-v)*2*z/scale;double px=wx,py=wy;
            if(z<4){double angle=f.time*.9,previous=f.previousTime*.9,cx=1.35*std::sin(f.time*1.7),prevx=1.35*std::sin(f.previousTime*1.7);double xx=wx-cx,yy=wy+.08;double lx=std::cos(angle)*xx+std::sin(angle)*yy,ly=-std::sin(angle)*xx+std::cos(angle)*yy;px=std::cos(previous)*lx-std::sin(previous)*ly+prevx;py=std::sin(previous)*lx+std::cos(previous)*ly-.08;}
            auto previous=Scene::PointUV(float(px),float(py),z,f.previousCamera,320,180);maximum=std::max(maximum,std::max(std::abs(double(md[at])-(previous[0]-u)),std::abs(double(md[at+1])-(previous[1]-v))));++checked;
        }
        Require(checked>1000&&maximum<2e-5,"motion projection CPU/GPU mismatch");totalMax=std::max(totalMax,maximum);total+=checked;report<<mode<<","<<checked<<","<<maximum<<"\n";
        auto visual=Color(c,320,180),diag=Color(c,320,180,DXGI_FORMAT_R32G32B32A32_FLOAT);post.BeginFrame();post.Dispatch("MotionCS",Constants(320,180,320,180),t.color,t.color,t.motionDepth,t.linearDepth,t.reactive,visual,diag);auto image=ReadTexture(c,visual);SavePpm(out/("motion-"+std::to_string(mode)+".ppm"),image,320,180,false);SaveFloat(out/("motion-"+std::to_string(mode)+".f32"),md);
    }
    std::ofstream f(out/"gpu-summary.json");f<<"{\"pass\":true,\"checked_points\":"<<total<<",\"max_uv_error\":"<<totalMax<<",\"direction\":\"previous-current\",\"includes_jitter\":false}";
}
static void Oracle(UploadContext& c,PostChain& post,const fs::path& root){
    // constants.bin严格匹配64B PostConstants；五张RGBA32F输入由独立Python参考生成。
    // 先上传、Fence，再执行同一实际HLSL；CPU比较另一步运行，不用GPU输出反推期望值。
    UINT count=0;for(auto& item:fs::directory_iterator(root)){if(!item.is_directory())continue;auto p=item.path();if(!fs::exists(p/"constants.bin"))continue;PostConstants constants;std::ifstream f(p/"constants.bin",std::ios::binary);f.read(reinterpret_cast<char*>(&constants),sizeof(constants));Require(bool(f),"invalid oracle constants");std::string entry;std::ifstream(p/"entry.txt")>>entry;
        std::array<Texture,5> inputs;const char* names[]={"current","history","motion_depth","previous_depth","reactive"};for(UINT i=0;i<5;++i){inputs[i]=MakeTexture(c,constants.inputWidth,constants.inputHeight,DXGI_FORMAT_R32G32B32A32_FLOAT,D3D12_RESOURCE_FLAG_NONE);UploadFloat(c,inputs[i],LoadFloats(p/(std::string(names[i])+".f32")));}
        auto output=Color(c,constants.outputWidth,constants.outputHeight,DXGI_FORMAT_R32G32B32A32_FLOAT),diag=Color(c,constants.outputWidth,constants.outputHeight,DXGI_FORMAT_R32G32B32A32_FLOAT);post.BeginFrame();post.Dispatch(entry,constants,inputs[0],inputs[1],inputs[2],inputs[3],inputs[4],output,diag);SaveFloat(p/"output.f32",ReadTexture(c,output));SaveFloat(p/"diagnostic.f32",ReadTexture(c,diag));++count;
    }Require(count>=16,"not all oracle cases ran");std::cout<<"oracle_gpu_cases="<<count<<"\n";
}
static void F6(UploadContext& c,Scene& scene,PostChain& post,const fs::path& out){
    fs::create_directories(out);std::ofstream csv(out/"scaling.csv");csv<<"method,render_width,render_height,output_width,output_height,resource_bytes,gpu_ms\n";std::vector<float> uiReference;UINT checks=0;
    for(float scale:{.5f,2.f/3,.75f,1.f})for(const std::string method:{"BilinearCS","BicubicCS","NisCS"}){
        UINT w=UINT(640*scale),h=UINT(360*scale);auto t=scene.Create(w,h);SceneFrame f;f.time=f.previousTime=.25f;f.lodBias=std::log2(scale);f.outputAspect=640.f/360;scene.Render(t,f);c.SubmitWait();auto output=Color(c,640,360),diag=Color(c,640,360,DXGI_FORMAT_R32G32B32A32_FLOAT),display=Color(c,640,360,DXGI_FORMAT_R8G8B8A8_UNORM);Timer timer(c);post.BeginFrame();timer.Begin(c);
        if(method=="NisCS")post.Nis(t.color,output);else post.Dispatch(method,Constants(w,h,640,360),t.color,t.color,t.motionDepth,t.linearDepth,t.reactive,output,diag);timer.End(c);c.SubmitWait();double ms=timer.Milliseconds();post.BeginFrame();post.Display(output,display,3,0,true,21);auto pixels=ReadTexture(c,display);Finite(pixels);
        if(uiReference.empty())uiReference=pixels;for(UINT y=8;y<30;++y)for(UINT x=8;x<120;++x)for(UINT k=0;k<3;++k){auto i=(size_t(y)*640+x)*4+k;Require(pixels[i]==uiReference[i],"UI must stay at output resolution");++checks;}
        std::vector<D3D12_RESOURCE_DESC> descriptions;for(Texture* r:{&t.color,&t.motionDepth,&t.linearDepth,&t.velocity,&t.reactive,&t.depth,&output,&diag,&display})descriptions.push_back(r->resource->GetDesc());auto allocation=c.device->GetResourceAllocationInfo(0,UINT(descriptions.size()),descriptions.data());csv<<method<<","<<w<<","<<h<<",640,360,"<<allocation.SizeInBytes<<","<<ms<<"\n";SavePpm(out/(method+"-"+std::to_string(w)+".ppm"),pixels,640,360,false);
    }
    std::ofstream(out/"summary.json")<<"{\"pass\":true,\"scale_range\":[0.5,1.0],\"methods\":[\"bilinear\",\"bicubic\",\"official-NIS\"],\"ui_channel_checks\":"<<checks<<"}";
}
// F3/F5/F7/F8/F10都经过同一帧循环与同一场景，区别只在重建模块；不让各SDK偷偷换场景。
static void Sequence(UploadContext& c,Scene& scene,PostChain& post,const fs::path& lesson,const fs::path& out,const std::string& method,UINT frames,bool capture,UINT ow=640,UINT oh=360){
    // context属于本次Sequence；同一进程不跨方法共享SDK历史。
    // 初始化失败可走显式空间fallback，正式验收拒绝该标签下的fallback成绩。
    fs::create_directories(out);UINT w=ow,h=oh;bool sdk=method.rfind("fsr",0)==0||method.rfind("xess",0)==0;bool reference=method=="reference",taa=method.rfind("taa",0)==0;
    SdkUpscaler upscaler;std::string provider="none";bool fallback=false;
    if(sdk){auto quality=method.find("native")!=std::string::npos?SdkQuality::Native:method.find("balanced")!=std::string::npos?SdkQuality::Balanced:method.find("performance")!=std::string::npos?SdkQuality::Performance:SdkQuality::Quality;bool ok=upscaler.Initialize(c.device.Get(),method.rfind("fsr",0)==0?SdkKind::Fsr:SdkKind::XeSS,quality,ow,oh,ow,oh,lesson/(method=="fsr-unavailable"?"build/missing-sdk-test":"build/deps"));
        if(ok){w=upscaler.RecommendedWidth();h=upscaler.RecommendedHeight();provider=upscaler.Provider();std::cout<<"SDK ready "<<provider<<" input="<<w<<"x"<<h<<std::endl;}
        else {std::cout<<"SDK fallback: "<<upscaler.Status()<<std::endl;sdk=false;fallback=true;w=ow/2;h=oh/2;provider="bilinear fallback";}
    }
    else if(reference){w=ow*4;h=oh*4;}else if(method=="bilinear"||method=="bicubic"||method=="nis"){w=ow/2;h=oh/2;}
    auto target=scene.Create(w,h,method=="msaa4"?4:1);auto resolved=Color(c,w,h);std::array<Texture,2> history{Color(c,ow,oh),Color(c,ow,oh)};auto diag=Color(c,ow,oh,DXGI_FORMAT_R32G32B32A32_FLOAT);auto previousDepth=MakeTexture(c,w,h,DXGI_FORMAT_R32_FLOAT,D3D12_RESOURCE_FLAG_NONE);Timer totalTimer(c),postTimer(c);HistoryValidity validity;Float2 previousJitter{};
    // TAA内部历史保留当帧jittered格点，供下一帧按jprev-jcur查询。
    // 展示/评分必须回到稳定格点：另一个纹理接收uv+jcur采样，绝不覆盖history。
    // 只有TAA创建此资源；本帧Fence结束后才能复用，额外pass包含在重建计时内。
    Texture stableOutput;if(taa)stableOutput=Color(c,ow,oh);UINT phaseCount=taa?8:0;
    std::ofstream csv(out/"frames.csv");csv<<"frame,render_width,render_height,output_width,output_height,reset,gpu_frame_ms,gpu_reconstruction_ms,mean_rgb,history_accepted,depth_rejected,clamped_pixels\n";double sumMs=0,sumPost=0;UINT acceptedTotal=0,depthTotal=0;bool finite=true;
    for(UINT frame=0;frame<frames;++frame){
        // DRS只改变预留最大范围内的render尺寸；SDK输出和宿主history仍是ow×oh。
        // 替换资源前等待旧提交；HistoryValidity比较尺寸后让该帧reset。
        if(method=="fsr-dynamic"&&(frame==4||frame==8||frame==12)){c.SubmitWait();w=frame==4?ow/2:frame==8?ow*3/4:ow;h=frame==4?oh/2:frame==8?oh*3/4:oh;target=scene.Create(w,h);previousDepth=MakeTexture(c,w,h,DXGI_FORMAT_R32_FLOAT,D3D12_RESOURCE_FLAG_NONE);}
        bool cut=frame==60;float time=frame/60.f,camera=frame>=60?.5f:0.f;FrameIdentity id{w,h,ow,oh,DirectX::XM_PIDIV4,1,cut,false};auto reason=validity.Begin(id);bool reset=reason!=ResetReason::None;
        // F10统一alpha clip策略以隔离样本数差异；A2C的独立对照留在F1。
        phaseCount=sdk?upscaler.JitterPhaseCount(w,ow):taa?8:0;
        auto jitter=(taa||sdk)?HaltonJitterPixels(frame,phaseCount):Float2{};SceneFrame sf;sf.time=time;sf.previousTime=reset?time:float(frame-1)/60;sf.camera=camera;sf.previousCamera=reset?camera:(frame-1>=60?.5f:0);sf.jitterX=jitter.x;sf.jitterY=jitter.y;sf.a2c=false;sf.outputAspect=float(ow)/oh;sf.lodBias=reference?0:std::log2(float(w)/ow);
        post.BeginFrame();totalTimer.Begin(c);scene.Render(target,sf);Texture* source=&target.color;
        if(target.color.samples>1){target.color.To(c,D3D12_RESOURCE_STATE_RESOLVE_SOURCE);resolved.To(c,D3D12_RESOURCE_STATE_RESOLVE_DEST);c.list->ResolveSubresource(resolved.resource.Get(),0,target.color.resource.Get(),0,resolved.format);source=&resolved;}
        // 帧0写A读B但history无效；帧1写B读A，以此交替。
        // Camera Cut把previous变换也设为current，避免大motion带入新历史；
        // 未初始化B不会被TaaCS采样，因为有效性拒绝发生在history读取之前。
        auto& result=history[frame%2];auto& previous=history[(frame+1)%2];PostConstants pc=Constants(w,h,ow,oh);pc.jitterUV=JitterUV(jitter,w,h);pc.previousJitterUV=previousJitter;pc.frameIndex=frame;if(!reset)pc.flags|=HistoryValid;
        if(method=="taa-no-reprojection")pc.flags&=~Reproject;if(method=="taa-no-rejection")pc.flags&=~RejectDepth;if(method=="taa-no-clamp")pc.flags&=~ClampHistory;
        // 重建计时不含场景/Resolve；总计时从场景开始。
        // SDK接收D32的R32视图、render像素motion，与教学TAA的线性viewZ/UV不同。
        postTimer.Begin(c);
        if(sdk){target.color.To(c,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);target.depth.To(c,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);target.velocity.To(c,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);target.reactive.To(c,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);result.To(c,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);SdkFrame f;f.commands=c.list.Get();f.color=target.color.resource.Get();f.depth=target.depth.resource.Get();f.motion=target.velocity.resource.Get();f.reactive=target.reactive.resource.Get();f.output=result.resource.Get();f.renderWidth=w;f.renderHeight=h;f.jitterX=jitter.x;f.jitterY=jitter.y;f.verticalFovRadians=DirectX::XM_PIDIV4;f.reset=reset;if(!upscaler.Dispatch(f))throw std::runtime_error("SDK dispatch: "+upscaler.Status());}
        else if(method=="nis")post.Nis(*source,result);
        else {std::string entry=taa?"TaaCS":reference?"ReferenceCS":method=="fxaa"?"FxaaCS":method=="bicubic"?"BicubicCS":"BilinearCS";
            // MSAA的guide没有Resolve为普通SRV，空间复制只读颜色，因此绑定普通source作未使用槽。
            auto& md=target.color.samples>1?*source:target.motionDepth;auto& react=target.color.samples>1?*source:target.reactive;
            post.Dispatch(entry,pc,*source,previous,md,previousDepth,react,result,diag);
        }
        Texture* finalResult=&result;
        if(taa){post.Dispatch("UnjitterCS",pc,result,previous,target.motionDepth,previousDepth,target.reactive,stableOutput,diag);finalResult=&stableOutput;}
        postTimer.End(c);totalTimer.End(c);c.SubmitWait();double frameMs=totalTimer.Milliseconds(),postMs=postTimer.Milliseconds();sumMs+=frameMs;sumPost+=postMs;
        double mean=0;UINT accepted=0,rejected=0,clamped=0;
        if(capture){auto pixels=ReadTexture(c,*finalResult);Finite(pixels);for(size_t i=0;i<pixels.size();++i)if(i%4!=3)mean+=pixels[i];mean/=ow*oh*3;char name[32];sprintf_s(name,"frame-%03u",frame);SaveFloat(out/(std::string(name)+".f32"),pixels);if(frame%30==0||frame==59||frame+1==frames)SavePpm(out/(std::string(name)+".ppm"),pixels,ow,oh);
            if(method=="noaa")SaveFloat(out/(std::string(name)+"-guide.f32"),ReadTexture(c,target.motionDepth));
            if(taa){auto diagnostics=ReadTexture(c,diag);for(size_t i=0;i<diagnostics.size();i+=4){accepted+=diagnostics[i]>.5;rejected+=diagnostics[i+3]==3;clamped+=diagnostics[i+1]>1e-5;}if(reset)Require(accepted==0,"history must be invalid after reset");if(frame==59||frame==60)SaveFloat(out/(std::string(name)+"-diagnostic.f32"),diagnostics);}
        }
        // 深度历史只在本帧所有读取结束后覆盖；Fence完成才把CPU语义历史标为有效。
        // 此复制在计时范围外。benchmark报告明确不是完整游戏帧时间。
        if(target.color.samples==1){Copy(c,target.linearDepth,previousDepth);c.SubmitWait();}validity.Commit(id);previousJitter=pc.jitterUV;acceptedTotal+=accepted;depthTotal+=rejected;
        csv<<frame<<","<<w<<","<<h<<","<<ow<<","<<oh<<","<<unsigned(reason)<<","<<frameMs<<","<<postMs<<","<<mean<<","<<accepted<<","<<rejected<<","<<clamped<<"\n";
    }
    c.SubmitWait();upscaler.Shutdown();std::ofstream f(out/"summary.json");f<<"{\"pass\":true,\"method\":\""<<method<<"\",\"frames\":"<<frames<<",\"render_width\":"<<w<<",\"render_height\":"<<h<<",\"output_width\":"<<ow<<",\"output_height\":"<<oh<<",\"provider\":\""<<provider<<"\",\"fallback\":"<<(fallback?"true":"false")<<",\"debug_validation\":"<<(c.validationEnabled?"true":"false")<<",\"offscreen_no_present\":true,\"gpu_frame_ms_mean\":"<<sumMs/frames<<",\"gpu_reconstruction_ms_mean\":"<<sumPost/frames<<",\"history_accepted_total\":"<<acceptedTotal<<",\"depth_rejected_total\":"<<depthTotal<<",\"jitter_phase_count\":"<<phaseCount<<",\"projection_aspect\":"<<float(ow)/oh<<",\"stable_output_grid\":true,\"capture\":"<<(capture?"true":"false")<<"}";
}
int main(int argc,char** argv){try{
    // exe在本课build/Release，默认路径相对exe推导，允许从C:/Windows启动。
    wchar_t module[32768];GetModuleFileNameW(nullptr,module,32768);fs::path lesson=fs::path(module).parent_path().parent_path().parent_path();std::string mode=argc>1?argv[1]:"suite",method=argc>2?argv[2]:"taa";UINT frames=argc>3?UINT(std::stoul(argv[3])):120;bool benchmark=mode=="bench";UploadContext c(!benchmark);Scene scene(c,lesson/"build/shaders");PostChain post(c,lesson/"build/shaders");
    if(mode=="suite"){F1(c,scene,lesson/"results/f1");F2(c,scene,post,lesson/"results/f2");F4(c,scene,post,lesson/"results/f4");F6(c,scene,post,lesson/"results/f6");}
    else if(mode=="oracle")Oracle(c,post,lesson/"results/f5/oracle-input");
    else if(mode=="sdk-resize")Sequence(c,scene,post,lesson,lesson/"results/f7/resize-dispatch","fsr-quality",8,true,800,450);
    else if(mode=="sequence"||benchmark)Sequence(c,scene,post,lesson,lesson/(benchmark?"results/f10/benchmark":"results/f10/sequences")/method,method,frames,!benchmark);
    else throw std::runtime_error("mode must be suite/oracle/sequence/bench");
    auto debug=c.CheckDebug();Require(debug==0,"D3D validation failed");std::cout<<"F run passed mode="<<mode<<" method="<<method<<"\n";return 0;
}catch(const std::exception& e){std::cerr<<"F FAILED: "<<e.what()<<"\n";return 1;}}
