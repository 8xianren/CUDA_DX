#include "graphics.h"
#include "passes.h"
#include "window.h"
#include <fstream>
#include <iostream>
#include <iomanip>
#include <chrono>
#include <cmath>
#include <algorithm>
#include <cstring>

namespace fs=std::filesystem;
using namespace neural;
struct Stream {
    cudaStream_t value=nullptr;
    Stream(){CudaCheck(cudaStreamCreateWithFlags(&value,cudaStreamNonBlocking),"G stream");}
    ~Stream(){cudaStreamSynchronize(value);cudaStreamDestroy(value);}
};
struct DeviceFrame {
    cudaStream_t stream;float4* rgba=nullptr;float *depth=nullptr,*meshZ=nullptr,*meshRay=nullptr;
    DeviceFrame(int w,int h,cudaStream_t s):stream(s){
        size_t n=size_t(w)*h;
        try{CudaCheck(cudaMalloc(&rgba,n*16),"G color allocation");CudaCheck(cudaMalloc(&depth,n*4),"G depth allocation");
            CudaCheck(cudaMalloc(&meshZ,n*4),"G mesh Z allocation");CudaCheck(cudaMalloc(&meshRay,n*4),"G ray depth allocation");}
        catch(...){cudaFree(rgba);cudaFree(depth);cudaFree(meshZ);cudaFree(meshRay);throw;}
    }
    ~DeviceFrame(){cudaStreamSynchronize(stream);cudaFree(rgba);cudaFree(depth);cudaFree(meshZ);cudaFree(meshRay);}
};
static void Require(bool ok,const char* what){if(!ok)throw std::runtime_error(what);}

int main(int argc,char** argv){try{
    fs::path root=fs::current_path(),asset;bool interactive=false,nerf=true,validation=true;
    for(int i=1;i<argc;++i){std::string a=argv[i];if(a=="--root"&&i+1<argc)root=argv[++i];
        else if(a=="--asset"&&i+1<argc)asset=argv[++i];else if(a=="--interactive")interactive=true;
        else if(a=="--without-nerf")nerf=false;else if(a=="--performance")validation=false;else throw std::runtime_error("unknown argument");}
    auto out=root/"results/g10"/(asset.empty()?(validation?"validation":"performance"):"reference-asset");fs::create_directories(out);
    UploadContext context(validation);SelectMatchingCudaDevice(context.device.Get());Stream stream;
    ExternalFence ready(context),done(context);Graphics graphics(context,root/"build/shaders");
    Window window(context,640,360);
    auto load0=std::chrono::steady_clock::now();VolumePass volume;auto load1=std::chrono::steady_clock::now();
    GaussianPass gaussian(asset);auto load2=std::chrono::steady_clock::now();NerfPass network(root/"results/g5");
    double volumeLoadMs=std::chrono::duration<double,std::milli>(load1-load0).count();
    double gaussianLoadMs=std::chrono::duration<double,std::milli>(load2-load1).count();
    RadiancePass* passes[]={nullptr,&volume,&gaussian,&network};
    const char* names[]={"mesh","volume","gaussian","nerf_cached"};
    std::ofstream csv(out/"frames.csv");csv<<"frame,mode,width,height,ready_value,done_value,cuda_pass_ms,representation_bytes,shared_allocation_bytes,composite_max_error,mesh_depth_max_error\n";
    uint64_t frameNumber=0;double maximum=0,depthError=0,rayError=0,volumeError=0;unsigned checked=0,volumeChecked=0;int mode=0,phase=0;
    auto makeResources=[&](UINT w,UINT h){window.Resize(w,h);};
    // resize后的资源集合在内层作用域构造；出作用域前排空CUDA和D3D队列，
    // 因而旧mip映射、纹理及descriptor不可能被下一尺寸沿用。
    bool running=true;
    while(running){
        UINT w=phase%2?320:640,h=phase%2?240:360;makeResources(w,h);
        SharedTexture sharedColor(context,w,h,true),sharedZ(context,w,h,false);
        auto mesh=aa::MakeTexture(context,w,h,DXGI_FORMAT_R32G32B32A32_FLOAT,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
        auto zbuffer=aa::MakeTexture(context,w,h,DXGI_FORMAT_R32_TYPELESS,D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL);
        auto composite=aa::MakeTexture(context,w,h,DXGI_FORMAT_R32G32B32A32_FLOAT,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
        DeviceFrame device(w,h,stream.value);unsigned localFrames=0;
        while(running){
            if(interactive){running=window.Pump();if(!running)break;
                for(int key=0;key<(nerf?4:3);++key)if(GetAsyncKeyState('1'+key)&1)mode=key;
                if(GetAsyncKeyState('R')&1)break;
            } else mode=int(localFrames%(nerf?4:3));
            window.Title(L"G1-G10 | "+std::wstring(names[mode],names[mode]+std::strlen(names[mode]))+L" | 1-4 switch, R resize");
            ++frameNumber;
            graphics.Mesh(mesh,sharedZ.texture,zbuffer);
            sharedZ.texture.To(context,D3D12_RESOURCE_STATE_COMMON);sharedColor.texture.To(context,D3D12_RESOURCE_STATE_COMMON);
            // ready只由D3D队列递增；done只由CUDA递增。两条单生产者时间线避免
            // 在同一Fence上交叉Signal较大值导致“较小值已完成”的错误推断。
            context.SubmitWait([&]{Check(context.queue->Signal(ready.fence.Get(),frameNumber),"G ready signal");});
            ready.WaitCuda(frameNumber,stream.value);sharedZ.CopyTo(device.meshZ,stream.value);
            MeshDepthToRay(device.meshZ,device.meshRay,w,h,stream.value);
            cudaEvent_t begin,end;CudaCheck(cudaEventCreate(&begin),"G event begin");CudaCheck(cudaEventCreate(&end),"G event end");
            CudaCheck(cudaEventRecord(begin,stream.value),"G begin record");
            Frame frame{int(w),int(h),device.rgba,device.depth,device.meshZ,device.meshRay,stream.value};
            if(passes[mode])passes[mode]->Render(frame);else CudaCheck(cudaMemsetAsync(device.rgba,0,size_t(w)*h*16,stream.value),"G transparent clear");
            CudaCheck(cudaEventRecord(end,stream.value),"G end record");sharedColor.CopyFrom(device.rgba,stream.value);
            done.SignalCuda(frameNumber,stream.value);Check(context.queue->Wait(done.fence.Get(),frameNumber),"G consumer wait");
            // GPU队列Wait之后才能将COMMON转SRV并消费CUDA写入；CPU语句顺序本身
            // 不构成跨API同步。此教学调度每帧等待，未宣称多帧重叠吞吐。
            graphics.Composite(sharedColor.texture,mesh,composite,mode!=0,false);context.SubmitWait();
            float ms=0;CudaCheck(cudaEventElapsedTime(&ms,begin,end),"G elapsed");cudaEventDestroy(begin);cudaEventDestroy(end);
            double error=0,zError=0;
            if(!interactive&&validation){
                auto actual=aa::ReadTexture(context,composite),r=aa::ReadTexture(context,sharedColor.texture),m=aa::ReadTexture(context,mesh);
                std::vector<float> z(size_t(w)*h),ray(z.size()),cpuRay(z.size());
                CudaCheck(cudaMemcpy(z.data(),device.meshZ,z.size()*4,cudaMemcpyDeviceToHost),"G meshZ read");
                CudaCheck(cudaMemcpy(ray.data(),device.meshRay,ray.size()*4,cudaMemcpyDeviceToHost),"G meshRay read");
                float focal=h/(2*std::tan(25.f*3.14159265359f/180));
                for(UINT y=0;y<h;++y)for(UINT x=0;x<w;++x){size_t p=size_t(y)*w+x;
                    float wx=(x+.5f-w*.5f)*2.35f/focal,wy=(h*.5f-y-.5f)*2.35f/focal;
                    float expectedZ=(std::abs(wx)<.18f&&std::abs(wy)<.8f)?2.35f:4.5f;
                    zError=std::max(zError,double(std::abs(z[p]-expectedZ)));
                    double dx=(x+.5-double(w)/2)/focal,dy=(double(h)/2-y-.5)/focal;
                    cpuRay[p]=float(expectedZ*std::sqrt(1+dx*dx+dy*dy));
                    rayError=std::max(rayError,double(std::abs(ray[p]-cpuRay[p])));
                    for(int k=0;k<3;++k){float expected=mode?r[p*4+k]+(1-r[p*4+3])*m[p*4+k]:m[p*4+k];
                        Require(std::isfinite(actual[p*4+k]),"nonfinite composite");error=std::max(error,double(std::abs(actual[p*4+k]-expected)));}
                }
                Require(error<2e-6&&zError<1e-5&&rayError<3e-6,"G depth or composite oracle mismatch");++checked;
                if(mode==1){
                    // 独立CPU参考同时验证GPU数组采样与真实网格截断，不用GPU颜色自身推导真值。
                    auto field=volume::MakeSphereField(128);volume::Camera camera;camera.tanHalfFovY=std::tan(25.f*3.14159265359f/180);
                    volume::RenderOptions options;options.width=w;options.height=h;options.step=1.f/128;options.skipEmpty=true;
                    auto reference=volume::RenderCpu(&field,camera,options,nullptr,cpuRay.data());
                    for(size_t i=0;i<reference.size();++i){float values[]={reference[i].x,reference[i].y,reference[i].z,reference[i].w};
                        for(int k=0;k<4;++k)volumeError=std::max(volumeError,double(std::abs(r[i*4+k]-values[k])));}
                    Require(volumeError<5e-4,"G independent volume occlusion oracle mismatch");++volumeChecked;
                }
                aa::SaveFloat(out/(std::string(names[mode])+"-"+std::to_string(w)+".f32"),actual);
                aa::SavePpm(out/(std::string(names[mode])+"-"+std::to_string(w)+".ppm"),actual,w,h);
            }
            maximum=std::max(maximum,error);depthError=std::max(depthError,zError);
            csv<<frameNumber<<","<<names[mode]<<","<<w<<","<<h<<","<<frameNumber<<","<<frameNumber<<","<<ms<<","<<(passes[mode]?passes[mode]->RepresentationBytes():0)
               <<","<<sharedColor.allocationBytes+sharedZ.allocationBytes<<","<<error<<","<<zError<<"\n";
            graphics.Composite(sharedColor.texture,mesh,window.Back(),mode!=0,true);window.Present();
            ++localFrames;if(!interactive&&localFrames==(nerf?4u:3u)*(validation?1u:12u))break;
        }
        CudaCheck(cudaStreamSynchronize(stream.value),"G drain stream");context.SubmitWait();
        if(!interactive&&phase==1)running=false;++phase;
    }
    unsigned debug=context.CheckDebug();Require(debug==0,"D3D debug errors");
    std::ofstream(out/"summary.json")<<"{\"pass\":true,\"frames\":"<<frameNumber<<",\"oracle_cases\":"<<checked<<",\"composite_max\":"<<maximum
        <<",\"mesh_depth_max\":"<<depthError<<",\"debug_messages\":"<<debug<<",\"validation_enabled\":"<<(validation?"true":"false")
        <<",\"nerf_enabled\":"<<(nerf?"true":"false")<<",\"resize_generations\":"<<phase<<",\"ready_completed\":"<<ready.fence->GetCompletedValue()
        <<",\"done_completed\":"<<done.fence->GetCompletedValue()<<",\"gaussian_count\":"<<gaussian.last.gaussianCount
        <<",\"gaussian_visible\":"<<gaussian.last.visibleCount<<",\"gaussian_references\":"<<gaussian.last.references
        <<",\"gaussian_persistent_bytes\":"<<gaussian.last.persistentBytes<<",\"gaussian_scratch_bytes\":"<<gaussian.last.scratchBytes
        <<",\"ray_distance_max_error\":"<<rayError<<",\"volume_occlusion_max_error\":"<<volumeError<<",\"volume_oracle_cases\":"<<volumeChecked
        <<",\"volume_construct_ms\":"<<volumeLoadMs<<",\"gaussian_load_and_upload_ms\":"<<gaussianLoadMs<<"}";
    std::cout<<"G10 PASS frames="<<frameNumber<<" composite_max="<<maximum<<" depth_max="<<depthError<<"\n";return 0;
}catch(const std::exception& e){std::cerr<<"G10 FAIL "<<e.what()<<"\n";return 1;}}
