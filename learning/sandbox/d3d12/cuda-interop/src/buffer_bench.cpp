#include "external.h"
#include "validate.h"
#include "vertex_update.h"
#include "workload.h"
#include <cuda_profiler_api.h>
#include <nvtx3/nvToolsExt.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>

namespace {
using Clock=std::chrono::steady_clock;
double Ms(Clock::time_point a,Clock::time_point b){return std::chrono::duration<double,std::milli>(b-a).count();}
struct Range{bool active=true;explicit Range(const char* s){nvtxRangePushA(s);}
    void End(){if(active){nvtxRangePop();active=false;}}~Range(){End();}};
struct CudaResources {
    cudaStream_t stream=nullptr;SharedInstance* base=nullptr;void* vertices=nullptr;float* simulation=nullptr;
    std::vector<cudaEvent_t> begin,end;
    ~CudaResources(){for(auto e:begin)cudaEventDestroy(e);for(auto e:end)cudaEventDestroy(e);
        if(simulation)cudaFree(simulation);if(vertices)cudaFree(vertices);if(base)cudaFree(base);if(stream)cudaStreamDestroy(stream);}
};
uint64_t Hash(const void* pointer,size_t bytes){
    auto* p=static_cast<const uint8_t*>(pointer);uint64_t h=14695981039346656037ull;
    for(size_t i=0;i<bytes;++i){h^=p[i];h*=1099511628211ull;}return h;
}
void Require(bool condition,const char* message){if(!condition)throw std::runtime_error(message);}
}
int main(int argc,char** argv){
    try {
        if(argc!=7)throw std::runtime_error("usage: buffer_bench model shader output slots cuda-heavy|graphics-heavy|balanced validate|perf|profile");
        std::filesystem::path out=argv[3];std::filesystem::create_directories(out);
        unsigned slots=unsigned(std::stoul(argv[4]));std::string workload=argv[5],mode=argv[6];
        Require(slots>=1&&slots<=3,"slots must be 1..3");Require(mode=="validate"||mode=="perf"||mode=="profile","invalid mode");
        Require(workload=="cuda-heavy"||workload=="graphics-heavy"||workload=="balanced","invalid workload");
        bool validate=mode=="validate",profile=mode=="profile";
        const unsigned frames=validate?24:48,states=16384;
        const unsigned steps=workload=="cuda-heavy"?4096:workload=="graphics-heavy"?64:1024;
        const unsigned pixelSteps=validate?0:workload=="graphics-heavy"?4096:workload=="cuda-heavy"?64:1024;
        const unsigned warmups=validate?0:2,rounds=mode=="perf"?5:1;
        auto scene=LoadCpuScene(argv[1]);Require(scene.instances.size()==4,"four instance fixture required");
        UploadContext c(validate);SelectMatchingCudaDevice(c.device.Get());auto gpu=UploadScene(c,scene);
        Raster raster(c,argv[2],validate?224:1024,validate?256:1024);c.SubmitWait();gpu.staging.clear();
        CudaResources cuda;CudaCheck(cudaStreamCreateWithFlags(&cuda.stream,cudaStreamNonBlocking),"bench stream");
        const size_t objectBytes=scene.instances.size()*sizeof(SharedInstance),vertexBytes=scene.meshes[0].vertices.size()*sizeof(Vertex);
        std::vector<SharedInstance> base(scene.instances.size());
        for(size_t i=0;i<base.size();++i)memcpy(base[i].world,scene.nodes[scene.instances[i].nodeIndex].world.m.data(),64);
        std::vector<uint8_t> initial(vertexBytes+2*VertexGuard,0xa5);memcpy(initial.data()+VertexGuard,scene.meshes[0].vertices.data(),vertexBytes);
        CudaCheck(cudaMalloc(reinterpret_cast<void**>(&cuda.base),objectBytes),"base allocation");
        CudaCheck(cudaMalloc(&cuda.vertices,vertexBytes),"rest vertex allocation");
        CudaCheck(cudaMalloc(reinterpret_cast<void**>(&cuda.simulation),states*sizeof(float)),"simulation allocation");
        CudaCheck(cudaMemcpy(cuda.base,base.data(),objectBytes,cudaMemcpyHostToDevice),"base upload");
        CudaCheck(cudaMemcpy(cuda.vertices,scene.meshes[0].vertices.data(),vertexBytes,cudaMemcpyHostToDevice),"rest upload");
        std::vector<std::unique_ptr<ExternalBuffer>> objects,vertices;
        for(unsigned s=0;s<slots;++s){
            objects.push_back(std::make_unique<ExternalBuffer>(c,objectBytes));vertices.push_back(std::make_unique<ExternalBuffer>(c,initial.size()));
            CudaCheck(cudaMemcpy(vertices.back()->pointer,initial.data(),initial.size(),cudaMemcpyHostToDevice),"cache initialize");
        }
        CudaCheck(cudaDeviceSynchronize(),"initial drain");ExternalFence ready(c),consumed(c);
        // 各帧独立时间戳位置；所有批次最终排空后复用同一组命令列表和查询索引。
        D3D12_QUERY_HEAP_DESC qd{};qd.Type=D3D12_QUERY_HEAP_TYPE_TIMESTAMP;qd.Count=frames*2;
        ComPtr<ID3D12QueryHeap> queries;Check(c.device->CreateQueryHeap(&qd,IID_PPV_ARGS(&queries)),"timestamp heap");
        auto timestamps=MakeResource(c,BufferDesc(frames*2*sizeof(uint64_t)),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
        UINT64 frequency=0;Check(c.queue->GetTimestampFrequency(&frequency),"timestamp frequency");Require(frequency>0,"zero timestamp frequency");
        std::vector<FrameCommands> commands;cuda.begin.resize(frames);cuda.end.resize(frames);
        for(unsigned f=0;f<frames;++f){
            RenderSettings settings;settings.capture=validate;settings.pixelIterations=pixelSteps;
            settings.timestamps=queries.Get();settings.timestampReadback=timestamps.Get();settings.queryBase=f*2;
            commands.push_back(raster.Record(c,gpu,scene,objects[f%slots]->resource.Get(),objectBytes,vertices[f%slots]->resource.Get(),settings));
            CudaCheck(cudaEventCreate(&cuda.begin[f]),"begin event");CudaCheck(cudaEventCreate(&cuda.end[f]),"end event");
        }
        // 单独的最终帧验收不放入性能计时；GPU排空后重新绘制同一帧来保存图像。
        RenderSettings auditSettings;auditSettings.pixelIterations=pixelSteps;
        auto audit=raster.Record(c,gpu,scene,objects[(frames-1)%slots]->resource.Get(),objectBytes,vertices[(frames-1)%slots]->resource.Get(),auditSettings);
        std::ofstream csv(out/"timing.csv");csv<<"round,slots,frames,cuda_steps,pixel_steps,cpu_submit_ms,cpu_final_wait_ms,wall_ms,cuda_sum_ms,d3d_sum_ms,d3d_span_ms\n";
        std::ofstream perFrame(out/"frames.csv");perFrame<<"round,frame,slot,cuda_ms,d3d_begin_tick,d3d_end_tick\n";
        std::ofstream fences(out/"fences.csv");fences<<"batch,frame,slot,wait_consumed,signal_ready,signal_consumed\n";
        uint64_t sequence=0;
        for(unsigned batch=0;batch<warmups+rounds;++batch){
            bool measured=batch>=warmups;if(profile&&measured)CudaCheck(cudaProfilerStart(),"profiler start");
            Range batchRange(measured?"E3 measured batch":"E3 warmup batch");auto begin=Clock::now();
            Clock::time_point submitted,finished;
            try {
                for(unsigned f=0;f<frames;++f){
                    Range frameRange("E3 enqueue frame");uint64_t value=sequence+f+1;
                    // 批次开始时所有槽位已排空；本批第一次使用不等，之后仅等同槽上一帧。
                    uint64_t wait=f>=slots?sequence+f-slots+1:0;
                    if(wait)consumed.WaitCuda(wait,cuda.stream);
                    CudaCheck(cudaEventRecord(cuda.begin[f],cuda.stream),"CUDA begin timestamp");
                    CudaCheck(SimulationWork(cuda.simulation,states,steps,f,cuda.stream),"fixed simulation work");
                    CudaCheck(UpdateInstances(static_cast<SharedInstance*>(objects[f%slots]->pointer),cuda.base,unsigned(base.size()),f,cuda.stream),"instance update");
                    CudaCheck(UpdateVertices(vertices[f%slots]->pointer,cuda.vertices,unsigned(scene.meshes[0].vertices.size()),f,cuda.stream),"vertex update");
                    CudaCheck(cudaEventRecord(cuda.end[f],cuda.stream),"CUDA end timestamp");ready.SignalCuda(value,cuda.stream);
                    Check(c.queue->Wait(ready.fence.Get(),value),"graphics wait");
                    ID3D12CommandList* lists[]={commands[f].list.Get()};c.queue->ExecuteCommandLists(1,lists);
                    Check(c.queue->Signal(consumed.fence.Get(),value),"graphics consumed");
                    // 不在提交热循环写磁盘日志；下方批次完成后输出同一组参数。
                }
                submitted=Clock::now();{Range drain("E3 final CPU drain");DrainFence(consumed.fence.Get(),sequence+frames);
                    CudaCheck(cudaStreamSynchronize(cuda.stream),"CUDA completion check");}finished=Clock::now();
            }catch(const std::exception& e){std::cerr<<"in-flight failure: "<<e.what()<<std::endl;std::_Exit(2);}
            batchRange.End();
            if(profile&&measured)CudaCheck(cudaProfilerStop(),"profiler stop");
            void* p=nullptr;D3D12_RANGE read{0,SIZE_T(frames*16)},noWrite{0,0};Check(timestamps->Map(0,&read,&p),"timestamps Map");
            auto* ticks=static_cast<uint64_t*>(p);double cudaSum=0,d3dSum=0;
            for(unsigned f=0;f<frames;++f){
                float ms=0;CudaCheck(cudaEventElapsedTime(&ms,cuda.begin[f],cuda.end[f]),"CUDA elapsed");cudaSum+=ms;
                Require(ticks[2*f+1]>=ticks[2*f],"reversed D3D timestamps");if(f)Require(ticks[2*f]>=ticks[2*f-1],"D3D queue timestamp order");
                d3dSum+=double(ticks[2*f+1]-ticks[2*f])*1000/double(frequency);
                if(measured)perFrame<<batch-warmups<<','<<f<<','<<f%slots<<','<<ms<<','<<ticks[2*f]<<','<<ticks[2*f+1]<<'\n';
                fences<<batch<<','<<f<<','<<f%slots<<','<<(f>=slots?sequence+f-slots+1:0)<<','<<sequence+f+1<<','<<sequence+f+1<<'\n';
            }
            double span=double(ticks[2*frames-1]-ticks[0])*1000/double(frequency);timestamps->Unmap(0,&noWrite);
            if(measured){csv<<batch-warmups<<','<<slots<<','<<frames<<','<<steps<<','<<pixelSteps<<','<<Ms(begin,submitted)<<','<<Ms(submitted,finished)<<','<<Ms(begin,finished)<<','<<cudaSum<<','<<d3dSum<<','<<span<<'\n';
                std::cout<<"round="<<batch-warmups<<" slots="<<slots<<" wall_ms="<<Ms(begin,finished)<<" cuda_sum_ms="<<cudaSum<<" d3d_sum_ms="<<d3dSum<<'\n';}
            sequence+=frames;
        }
        // 以下全部在测量区间外。验证模式检查每帧；性能模式检查最后帧和所有模拟输出。
        try {
            ID3D12CommandList* auditLists[]={audit.list.Get()};c.queue->ExecuteCommandLists(1,auditLists);
            Check(c.queue->Signal(c.fence.Get(),++c.submitted),"audit signal");DrainFence(c.fence.Get(),c.submitted);
        }catch(const std::exception& e){std::cerr<<"in-flight audit failure: "<<e.what()<<std::endl;std::_Exit(2);}
        uint64_t mismatches=0,pixelsChecked=0,edges=0,bytesChecked=0;
        for(unsigned f=validate?0:frames-1;f<frames;++f){
            auto& record=validate?commands[f]:audit;auto expected=Expected(scene,f);auto shape=scene;
            double a=double(int(f%9)-4)/16;
            for(auto& v:shape.meshes[0].vertices){double x=v.position[0],y=v.position[1];v.position[0]=float(x+a*y);v.position[1]=float(y+a*x*x);}
            auto vertexExpected=initial;memcpy(vertexExpected.data()+VertexGuard,shape.meshes[0].vertices.data(),vertexBytes);
            for(unsigned which=0;which<2;++which){
                auto* resource=which?record.vertices.Get():record.instances.Get();const void* expectedData=which?static_cast<const void*>(vertexExpected.data()):expected.data();
                size_t size=which?vertexExpected.size():objectBytes;void* actual=nullptr;D3D12_RANGE r{0,size},nw{0,0};Check(resource->Map(0,&r,&actual),"audit Map");
                for(size_t i=0;i<size;++i){++bytesChecked;if(static_cast<uint8_t*>(actual)[i]!=static_cast<const uint8_t*>(expectedData)[i])++mismatches;}resource->Unmap(0,&nw);
            }
            auto image=raster.ReadPixels(record);
            if(validate){auto result=AuditPixels(shape,raster.camera,expected,image);mismatches+=result.mismatch;pixelsChecked+=result.checked;edges+=result.edges;Require(result.covered>0,"no covered pixels");}
            else {for(float value:image)if(!std::isfinite(value))++mismatches;}
        }
        std::vector<float> simulation(states);CudaCheck(cudaMemcpy(simulation.data(),cuda.simulation,states*4,cudaMemcpyDeviceToHost),"simulation readback");
        // 所有16384状态验证；公式只依赖i mod1024，CPU计算1024项后逐项检查，并非抽样。
        float reference[1024];for(unsigned i=0;i<1024;++i){float x=float((i+frames-1)%1024)/1024.f;
            for(unsigned k=0;k<steps;++k){x=std::fma(x,1.0001f,0.00001f);x-=std::floor(x);}reference[i]=x;}
        for(unsigned i=0;i<states;++i)if(simulation[i]!=reference[i%1024])++mismatches;
        auto finalImage=raster.ReadPixels(audit);uint64_t imageHash=Hash(finalImage.data(),finalImage.size()*4);
        SaveImage(out/"last-frame.bmp",raster.camera.width,raster.camera.height,finalImage);
        unsigned debug=c.CheckDebug();Require(!mismatches&&!debug,"content or Debug validation failed");
        Require(ready.fence->GetCompletedValue()==sequence&&consumed.fence->GetCompletedValue()==sequence,"final external fence mismatch");
        std::ofstream json(out/"summary.json");json<<"{\n\"pass\":true,\"mode\":\""<<mode<<"\",\"workload\":\""<<workload<<"\",\"slots\":"<<slots
            <<",\"frames\":"<<frames<<",\"warmups\":"<<warmups<<",\"rounds\":"<<rounds<<",\"simulation_states\":"<<states<<",\"cuda_substeps\":"<<steps
            <<",\"pixel_iterations\":"<<pixelSteps<<",\"width\":"<<raster.camera.width<<",\"height\":"<<raster.camera.height
            <<",\"shared_allocation_bytes\":"<<slots*(objects[0]->allocationBytes+vertices[0]->allocationBytes)
            <<",\"timestamp_frequency\":"<<frequency<<",\"cpu_middle_wait_calls\":0,\"present_calls\":0,\"vsync\":\"headless-no-swapchain\""
            <<",\"debug_enabled\":"<<(validate?"true":"false")<<",\"bytes_checked\":"<<bytesChecked<<",\"pixels_checked\":"<<pixelsChecked<<",\"edges_excluded\":"<<edges
            <<",\"simulation_values_checked\":"<<states<<",\"mismatches\":"<<mismatches<<",\"ready\":"<<sequence<<",\"consumed\":"<<sequence
            <<",\"image_hash\":\""<<imageHash<<"\",\"simulation_hash\":\""<<Hash(simulation.data(),states*4)<<"\"\n}\n";
        std::cout<<"PASS slots="<<slots<<" mode="<<mode<<" bytes="<<bytesChecked<<" pixel_checks="<<pixelsChecked<<" simulation_checks="<<states<<" image_hash="<<imageHash<<'\n';return 0;
    }catch(const std::exception& e){std::cerr<<"FAIL: "<<e.what()<<'\n';return 1;}
}
