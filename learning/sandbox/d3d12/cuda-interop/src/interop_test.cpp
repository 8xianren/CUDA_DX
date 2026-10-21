#include "external.h"
#include "validate.h"
#include "vertex_update.h"
#include "static_audit.h"
#include <memory>
#include <cstring>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <cstdlib>
#include <cmath>

namespace {
struct CudaState {
    cudaStream_t stream=nullptr;SharedInstance* base=nullptr;void* baseVertices=nullptr;
    ~CudaState(){if(baseVertices)cudaFree(baseVertices);if(base)cudaFree(base);if(stream)cudaStreamDestroy(stream);}
};
}
int main(int argc,char** argv){
    bool inFlight=false;
    try{
        if(argc<4||argc>5)throw std::runtime_error("usage: interop_test model.gltf shader.hlsl outputDirectory [e2|e2-stale]");
        std::string mode=argc==5?argv[4]:"e1";
        if(mode!="e1"&&mode!="e2"&&mode!="e2-stale")throw std::runtime_error("unknown lesson mode");
        bool dynamic=mode!="e1",injectStale=mode=="e2-stale";
        std::filesystem::path out=argv[3];std::filesystem::create_directories(out);
        auto cpu=LoadCpuScene(argv[1]);
        if(cpu.instances.size()!=4)throw std::runtime_error("E.1 audit requires C.4 four-instance TRS asset");
        UploadContext c;SelectMatchingCudaDevice(c.device.Get());auto gpu=UploadScene(c,cpu);
        Raster raster(c,argv[2]);
        // 静态资产上传的CPU等待不属于帧内交接，单独计数。staging保留到上传完成。
        c.SubmitWait();gpu.staging.clear();
        auto staticBefore=dynamic?SnapshotStatic(c,gpu):std::vector<uint8_t>{};
        auto originalVB=gpu.vertices.Get(),originalIB=gpu.indices.Get();auto originalHeap=gpu.descriptors.Get();
        std::vector<ID3D12Resource*> originalImages;for(const auto& i:gpu.images)originalImages.push_back(i.texture.Get());
        CudaState cuda;CudaCheck(cudaStreamCreateWithFlags(&cuda.stream,cudaStreamNonBlocking),"stream");
        const auto bytes=cpu.instances.size()*sizeof(SharedInstance);
        std::vector<SharedInstance> base(cpu.instances.size());
        for(size_t i=0;i<base.size();++i)memcpy(base[i].world,cpu.nodes.at(cpu.instances[i].nodeIndex).world.m.data(),64);
        CudaCheck(cudaMalloc(reinterpret_cast<void**>(&cuda.base),bytes),"base allocation");
        CudaCheck(cudaMemcpy(cuda.base,base.data(),bytes,cudaMemcpyHostToDevice),"one-time base upload");
        // nonblocking流不依赖legacy默认流，显式完成一次初始化，之后不再每帧上传。
        CudaCheck(cudaDeviceSynchronize(),"initial upload drain");
        ExternalBuffer shared(c,bytes);
        std::unique_ptr<ExternalBuffer> dynamicVB;
        std::vector<uint8_t> initialVertices;
        if(dynamic){
            static_assert(sizeof(Vertex)==VertexStride);
            const auto& vertices=cpu.meshes.at(0).vertices;
            if(vertices.empty())throw std::runtime_error("empty dynamic mesh");
            for(const auto& v:vertices)if(v.position[2]!=0)throw std::runtime_error("E.2 planar audit requires z=0");
            // 仅复制mesh0；左右哨兵不在VB视图内，kernel不得触碰。原始VB完全不导入CUDA。
            auto vertexBytes=vertices.size()*sizeof(Vertex);initialVertices.assign(vertexBytes+2*VertexGuard,0xa5);
            memcpy(initialVertices.data()+VertexGuard,vertices.data(),vertexBytes);
            dynamicVB=std::make_unique<ExternalBuffer>(c,initialVertices.size());
            CudaCheck(cudaMalloc(&cuda.baseVertices,vertexBytes),"base vertices allocation");
            CudaCheck(cudaMemcpy(cuda.baseVertices,vertices.data(),vertexBytes,cudaMemcpyHostToDevice),"base vertices upload");
            CudaCheck(cudaMemcpy(dynamicVB->pointer,initialVertices.data(),initialVertices.size(),cudaMemcpyHostToDevice),"dynamic cache initialize");
            CudaCheck(cudaDeviceSynchronize(),"dynamic initialize drain");
        }
        // ready只有CUDA写，consumed只有D3D队列写。单写者时间线避免Fence值倒退。
        ExternalFence ready(c),consumed(c);
        constexpr unsigned frameCount=24;
        std::vector<FrameCommands> frames;frames.reserve(frameCount);
        for(unsigned f=0;f<frameCount;++f)frames.push_back(raster.Record(c,gpu,cpu,shared.resource.Get(),bytes,dynamic?dynamicVB->resource.Get():nullptr));
        std::ofstream trace(out/"fences.csv");trace<<"frame,slot,cuda_wait_consumed,cuda_signal_ready,d3d_wait_ready,d3d_signal_consumed\n";
        // 从这里到最后drain，不调用任何CPU等待/Map/allocator Reset。
        // 生产者signal先入队，再安排消费者wait；完整依赖图是无环的链。
        inFlight=true;
        try {
        for(unsigned f=0;f<frameCount;++f){
            if(f)consumed.WaitCuda(f,cuda.stream);
            CudaCheck(UpdateInstances(static_cast<SharedInstance*>(shared.pointer),cuda.base,unsigned(base.size()),f,cuda.stream),"instance kernel");
            // 同一stream里两个kernel都完成后才signal，Fence覆盖实例表和动态VB这一组资源。
            // 负对照安全地产生旧帧形状，模拟消费者拿到旧缓存；不执行未定义的数据竞争。
            if(dynamic)CudaCheck(UpdateVertices(dynamicVB->pointer,cuda.baseVertices,unsigned(cpu.meshes[0].vertices.size()),
                injectStale&&f==7?f-1:f,cuda.stream),"vertex kernel");
            ready.SignalCuda(f+1,cuda.stream);
            Check(c.queue->Wait(ready.fence.Get(),f+1),"D3D GPU wait ready");
            ID3D12CommandList* lists[]={frames[f].list.Get()};c.queue->ExecuteCommandLists(1,lists);
            Check(c.queue->Signal(consumed.fence.Get(),f+1),"D3D signal consumed");
            trace<<f<<",0,"<<f<<','<<f+1<<','<<f+1<<','<<f+1<<'\n';
        }
        DrainFence(consumed.fence.Get(),frameCount);
        CudaCheck(cudaStreamSynchronize(cuda.stream),"final CUDA asynchronous error check");inFlight=false;
        } catch(const std::exception& e) {
            // 未完成交接时不能栈展开释放被GPU引用的资源，也不能等待一个永远不会signal的Fence。
            // 此教学进程明确失败退出；生产引擎应进入设备丢失/重建流程。
            std::cerr<<"in-flight failure: "<<e.what()<<std::endl;std::_Exit(2);
        }
        uint64_t fields=0,pixelChecks=0,edges=0,covered=0,mismatch=0,staleRejected=0;
        uint64_t vertexBytesChecked=0,vertexBad=0,injectedVertexBad=0,injectedPixelBad=0;float maxError=0;
        for(unsigned f=0;f<frameCount;++f){
            auto deformed=cpu;
            if(dynamic){
                // 独立CPU double算式产生参考；只允许mesh0每个顶点的position三个float变化。
                double a=double(int(f%9)-4)/16;
                for(auto& v:deformed.meshes[0].vertices){double x=v.position[0],y=v.position[1];
                    v.position[0]=float(x+a*y);v.position[1]=float(y+a*x*x);}
                auto expectedBytes=initialVertices;
                for(size_t i=0;i<deformed.meshes[0].vertices.size();++i)
                    memcpy(expectedBytes.data()+VertexGuard+i*VertexStride,deformed.meshes[0].vertices[i].position,12);
                void* data=nullptr;D3D12_RANGE read{0,expectedBytes.size()},noWrite{0,0};
                Check(frames[f].vertices->Map(0,&read,&data),"dynamic vertex snapshot");
                uint64_t bad=0;for(size_t i=0;i<expectedBytes.size();++i){++vertexBytesChecked;
                    if(static_cast<const uint8_t*>(data)[i]!=expectedBytes[i])++bad;}
                frames[f].vertices->Unmap(0,&noWrite);
                if(injectStale&&f==7)injectedVertexBad=bad;else vertexBad+=bad;
            }
            auto expected=Expected(cpu,f);std::vector<SharedInstance> actual(base.size());void* p=nullptr;
            D3D12_RANGE range{0,bytes},noWrite{0,0};Check(frames[f].instances->Map(0,&range,&p),"instance readback");
            memcpy(actual.data(),p,bytes);frames[f].instances->Unmap(0,&noWrite);
            for(size_t i=0;i<actual.size();++i){
                // memcpy到float数组避免跨结构体成员的指针算术未定义行为。
                float a[20],e[20];memcpy(a,&actual[i],80);memcpy(e,&expected[i],80);
                for(unsigned k=0;k<20;++k){float error=std::abs(a[k]-e[k]);maxError=std::max(maxError,error);++fields;
                    if(!std::isfinite(a[k])||error>1e-6f)++mismatch;}
            }
            auto pixels=raster.ReadPixels(frames[f]);auto audit=AuditPixels(deformed,raster.camera,expected,pixels);
            pixelChecks+=audit.checked;edges+=audit.edges;covered+=audit.covered;
            if(injectStale&&f==7)injectedPixelBad=audit.mismatch;else mismatch+=audit.mismatch;
            if(!audit.covered)throw std::runtime_error("empty image cannot validate shader consumption");
            // 安全负对照：同一已完成图像按上一帧契约审计，必须拒绝；不真的制造GPU数据竞争。
            if(f && AuditPixels(cpu,raster.camera,Expected(cpu,f-1),pixels).mismatch>0)++staleRejected;
            if(f==0||f==frameCount-1)SaveImage(out/("frame-"+std::to_string(f)+".bmp"),raster.camera.width,raster.camera.height,pixels);
        }
        auto staticAfter=dynamic?SnapshotStatic(c,gpu):std::vector<uint8_t>{};
        bool identities=originalVB==gpu.vertices.Get()&&originalIB==gpu.indices.Get()&&originalHeap==gpu.descriptors.Get();
        for(size_t i=0;i<originalImages.size();++i)identities=identities&&originalImages[i]==gpu.images[i].texture.Get();
        bool staticUnchanged=identities&&staticBefore==staticAfter;
        auto debug=c.CheckDebug();
        auto rv=ready.fence->GetCompletedValue(),cv=consumed.fence->GetCompletedValue();
        bool pass=!mismatch&&!vertexBad&&!debug&&staticUnchanged&&staleRejected==frameCount-1&&rv==frameCount&&cv==frameCount
            &&(!injectStale||(injectedVertexBad>0&&injectedPixelBad>0));
        std::ofstream json(out/"summary.json");
        json<<"{\n  \"mode\": \""<<mode<<"\",\n  \"pass\": "<<(pass?"true":"false")<<",\n  \"frames\": "<<frameCount
            <<",\n  \"instances\": "<<base.size()<<",\n  \"shared_logical_bytes\": "<<bytes<<",\n  \"allocation_bytes\": "<<shared.allocationBytes
            <<",\n  \"cpu_middle_wait_calls\": 0,\n  \"d3d_initial_drains\": "<<(dynamic?2:1)<<",\n  \"cuda_initial_drains\": "<<(dynamic?2:1)
            <<",\n  \"final_d3d_drains\": "<<(dynamic?2:1)<<",\n  \"final_cuda_error_checks\": 1"
            <<",\n  \"dynamic_vertex_bytes_checked\": "<<vertexBytesChecked<<",\n  \"unexpected_vertex_byte_mismatches\": "<<vertexBad
            <<",\n  \"injected_stale_vertex_byte_mismatches\": "<<injectedVertexBad<<",\n  \"injected_stale_pixel_mismatches\": "<<injectedPixelBad
            <<",\n  \"static_snapshot_bytes\": "<<staticBefore.size()<<",\n  \"static_unchanged\": "<<(staticUnchanged?"true":"false")
            <<",\n  \"checked_fields\": "<<fields<<",\n  \"max_field_error\": "<<maxError<<",\n  \"checked_pixels\": "<<pixelChecks
            <<",\n  \"excluded_edge_pixels\": "<<edges<<",\n  \"covered_pixels\": "<<covered<<",\n  \"mismatches\": "<<mismatch
            <<",\n  \"stale_frames_rejected\": "<<staleRejected<<",\n  \"debug_warnings_errors\": "<<debug
            <<",\n  \"ready_fence\": "<<rv<<",\n  \"consumed_fence\": "<<cv<<"\n}\n";
        std::cout<<"frames="<<frameCount<<" fields="<<fields<<" pixels="<<pixelChecks<<" edges="<<edges<<" covered="<<covered
            <<" mismatches="<<mismatch<<" max_error="<<maxError<<" stale_rejected="<<staleRejected
            <<" ready="<<rv<<" consumed="<<cv<<" cpu_middle_wait_calls=0\n"
            <<"mode="<<mode<<" vertex_bytes="<<vertexBytesChecked<<" vertex_bad="<<vertexBad<<" static_bytes="<<staticBefore.size()
            <<" static_unchanged="<<staticUnchanged<<" injected_vertex_bad="<<injectedVertexBad<<" injected_pixel_bad="<<injectedPixelBad
            <<'\n'<<(pass?"PASS":"FAIL")<<'\n';return pass?0:1;
    }catch(const std::exception& e){
        std::cerr<<"FAIL: "<<e.what()<<'\n';
        if(inFlight)std::_Exit(2);return 1;
    }
}
