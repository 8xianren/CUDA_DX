#include "render/dxr/renderer.h"
#include "render/cuda/skin_gpu.h"
#include "external.h"
#include "path_history.h"
#include "energy_lut.h"
#include "window_display.h"
#include "render/dxr/temporal.h"
#include <chrono>
#include <memory>
#include <dxgi1_4.h>

namespace character {
struct DxrRenderer::Impl {
    const Rig& rig;CpuScene scene;RenderSettings settings;RendererStats stats;
    UploadContext context;GpuScene gpu;std::vector<AccelerationBuffers> blases;
    std::unique_ptr<ExternalBuffer> shared;std::unique_ptr<ExternalFence> ready,consumed;
    std::vector<std::unique_ptr<SkinDevice>> skins;cudaStream_t stream=nullptr;
    MaterialBindings bindings;std::unique_ptr<PathHistory> history;
    std::unique_ptr<WindowDisplay> display;
    std::unique_ptr<TemporalFilter> temporal;std::filesystem::path shaderDirectory;
    bool lastTemporal=false;float lastLightScale=0;uint64_t lastLightRevision=0;
    bool lastSky=false,lastSmooth=false;float lastSkyIntensity=0;
    ComPtr<ID3D12QueryHeap> timestamps;ComPtr<ID3D12Resource> timestampReadback;UINT64 timestampFrequency=0;
    cudaEvent_t cudaStart=nullptr,cudaEnd=nullptr;ComPtr<IDXGIAdapter3> adapter;
    uint64_t frame=0;std::vector<PathLight> lights;PathConfig config;
    Impl(const Rig& r,CpuScene s,const RenderSettings& set,const std::filesystem::path& shaders,const std::filesystem::path& energy):rig(r),scene(std::move(s)),settings(set),context(set.validation){
        shaderDirectory=shaders;SelectMatchingCudaDevice(context.device.Get());CheckCuda(cudaStreamCreateWithFlags(&stream,cudaStreamNonBlocking),"renderer skin stream");
        CheckCuda(cudaEventCreate(&cudaStart),"skin start event");CheckCuda(cudaEventCreate(&cudaEnd),"skin end event");
        D3D12_QUERY_HEAP_DESC query{};query.Type=D3D12_QUERY_HEAP_TYPE_TIMESTAMP;query.Count=5;Check(context.device->CreateQueryHeap(&query,IID_PPV_ARGS(&timestamps)),"timestamp heap");
        timestampReadback=MakeResource(context,BufferDesc(5*sizeof(UINT64)),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);Check(context.queue->GetTimestampFrequency(&timestampFrequency),"timestamp frequency");
        ComPtr<IDXGIFactory6> memoryFactory;Check(CreateDXGIFactory2(0,IID_PPV_ARGS(&memoryFactory)),"memory factory");ComPtr<IDXGIAdapter1> baseAdapter;
        Check(memoryFactory->EnumAdapterByLuid(context.device->GetAdapterLuid(),IID_PPV_ARGS(&baseAdapter)),"memory adapter");Check(baseAdapter.As(&adapter),"adapter memory interface");
        gpu=UploadScene(context,scene);context.SubmitWait();gpu.staging.clear();
        shared=std::make_unique<ExternalBuffer>(context,gpu.referenceVertices.size()*sizeof(Vertex));
        // 初始静态和绑定顶点只复制一次。CUDA后续只写角色范围，环境资源不重新上传。
        Barrier(context.list.Get(),gpu.vertices.Get(),D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER|D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_SOURCE);
        Barrier(context.list.Get(),shared->resource.Get(),D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_COPY_DEST);
        context.list->CopyBufferRegion(shared->resource.Get(),0,gpu.vertices.Get(),0,shared->logicalBytes);
        Barrier(context.list.Get(),shared->resource.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_COMMON);context.SubmitWait();
        gpu.vertices=shared->resource;gpu.vb.BufferLocation=gpu.vertices->GetGPUVirtualAddress();
        for(size_t i=0;i<gpu.geometry.size();++i)gpu.geometry[i].Triangles.VertexBuffer.StartAddress=gpu.vb.BufferLocation+gpu.meshes[i].firstVertex*sizeof(Vertex);
        ready=std::make_unique<ExternalFence>(context);consumed=std::make_unique<ExternalFence>(context);
        for(const auto& skin:rig.skins){std::vector<GpuInfluence> inf(skin.influence.size());for(size_t i=0;i<inf.size();++i){std::copy_n(skin.influence[i].joint,4,inf[i].joint);std::copy_n(skin.influence[i].weight,4,inf[i].weight);}
            skins.push_back(std::make_unique<SkinDevice>(rig.scene.meshes[skin.mesh].vertices.data(),inf.data(),unsigned(inf.size()),unsigned(skin.joints.size())));}
        Barrier(context.list.Get(),gpu.vertices.Get(),D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        for(size_t i=0;i<gpu.geometry.size();++i){bool dynamic=false;for(const auto& skin:rig.skins)dynamic|=skin.mesh==i;
            D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS input{};input.Type=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;input.DescsLayout=D3D12_ELEMENTS_LAYOUT_ARRAY;input.NumDescs=1;input.pGeometryDescs=&gpu.geometry[i];
            input.Flags=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;if(dynamic)input.Flags|=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_ALLOW_UPDATE;
            blases.push_back(BuildAcceleration(context,input));
            // 更新scratch可能比初建大；分别查询，不沿用只够初建的大小。
            if(dynamic){D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO size{};context.device->GetRaytracingAccelerationStructurePrebuildInfo(&input,&size);
                if(size.UpdateScratchDataSizeInBytes>blases.back().scratch->GetDesc().Width){context.SubmitWait();auto desc=BufferDesc(size.UpdateScratchDataSizeInBytes);desc.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;blases.back().scratch=MakeResource(context,desc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);}}
        }
        Barrier(context.list.Get(),gpu.vertices.Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COMMON);
        bindings=PreparePbrBindings(context,scene,gpu);auto table=pbr_energy::Load(energy);bindings.energy=InstanceUpload(context,table.data.data(),table.data.size()*sizeof(float));
        context.SubmitWait();history=std::make_unique<PathHistory>(context,shaders/"path.dxil",shaders/"accumulate.dxil");
        config.width=set.width;config.height=set.height;config.environmentIntensity=0;config.lightScale=1;config.maxScatters=4;config.flags=1;
        lights=MakePathLights(scene,WorldTriangles(scene),config,true);
        if(settings.window){ComPtr<IDXGIFactory6> factory;Check(CreateDXGIFactory2(settings.validation?DXGI_CREATE_FACTORY_DEBUG:0,IID_PPV_ARGS(&factory)),"display factory");
            display=std::make_unique<WindowDisplay>(factory.Get(),context.device.Get(),context.queue.Get(),shaders,true,
                L"H Demo | WASD/QE camera | RMB look | Space pause | N step | R reset | Esc exit",settings.width,settings.height);}
    }
    ~Impl(){if(stream){cudaStreamSynchronize(stream);cudaStreamDestroy(stream);}if(cudaStart)cudaEventDestroy(cudaStart);if(cudaEnd)cudaEventDestroy(cudaEnd);}
    RenderImage Render(const RenderFrame& input,bool rebuild){
        auto start=std::chrono::steady_clock::now();Require(input.palettes.size()==skins.size()&&input.rigWorlds.size()==rig.scene.nodes.size(),"invalid render snapshot");
        consumed->WaitCuda(frame,stream);
        CheckCuda(cudaEventRecord(cudaStart,stream),"start skin timing");
        std::vector<std::vector<SkinMatrix>> palettes(skins.size());
        for(size_t i=0;i<skins.size();++i){const auto& matrices=input.palettes[i];Require(matrices.size()==skins[i]->joints,"palette size mismatch");palettes[i].resize(matrices.size());
            for(size_t j=0;j<matrices.size();++j){std::copy_n(matrices[j].values.data(),16,palettes[i][j].position);auto inv=Inverse(matrices[j]);for(unsigned r=0;r<3;++r)for(unsigned c=0;c<3;++c)palettes[i][j].normal[r*4+c]=inv[c][r];}
            Vertex* target=static_cast<Vertex*>(shared->pointer)+gpu.meshes[rig.skins[i].mesh].firstVertex;skins[i]->Record(palettes[i].data(),stream,target);
        }
        CheckCuda(cudaEventRecord(cudaEnd,stream),"end skin timing");ready->SignalCuda(frame+1,stream);Check(context.queue->Wait(ready->fence.Get(),frame+1),"D3D waits skin");
        context.list->EndQuery(timestamps.Get(),D3D12_QUERY_TYPE_TIMESTAMP,0);
        Barrier(context.list.Get(),gpu.vertices.Get(),D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        for(const auto& skin:rig.skins){D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC build{};
            build.Inputs.Type=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;build.Inputs.DescsLayout=D3D12_ELEMENTS_LAYOUT_ARRAY;build.Inputs.NumDescs=1;build.Inputs.pGeometryDescs=&gpu.geometry[skin.mesh];
            build.Inputs.Flags=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE|D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_ALLOW_UPDATE;
            if(!rebuild)build.Inputs.Flags|=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PERFORM_UPDATE;
            auto& blas=blases[skin.mesh];build.DestAccelerationStructureData=blas.result->GetGPUVirtualAddress();build.SourceAccelerationStructureData=rebuild?0:build.DestAccelerationStructureData;build.ScratchAccelerationStructureData=blas.scratch->GetGPUVirtualAddress();
            context.list->BuildRaytracingAccelerationStructure(&build,0,nullptr);D3D12_RESOURCE_BARRIER barrier{};barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_UAV;barrier.UAV.pResource=blas.result.Get();context.list->ResourceBarrier(1,&barrier);
        }
        for(size_t i=0;i<input.rigWorlds.size();++i)scene.nodes[i].world.m=(input.characterWorld*input.rigWorlds[i]).values;
        auto instances=BuildInstanceFrame(context,scene,gpu,blases,false);
        context.list->EndQuery(timestamps.Get(),D3D12_QUERY_TYPE_TIMESTAMP,1);
        config.spp=input.spp;config.maxScatters=input.maxScatters;config.tanHalfFovY=input.tanHalfFov;config.lightScale=input.lightScale;
        Require(std::isfinite(input.skyIntensity)&&input.skyIntensity>=0,"invalid sky intensity");
        config.flags=1u|(input.skyEnabled?4u:0u)|(input.smoothNormals?8u:0u);config.environmentIntensity=input.skyEnabled?input.skyIntensity:0;
        config.seed=uint32_t(input.sceneRevision); // 动态帧使用不同样本；暂停后revision稳定，继续sampleOffset序列。
        SetPathCamera(config,{input.eye.x,input.eye.y,input.eye.z},{input.eye.x+input.forward.x,input.eye.y+input.forward.y,input.eye.z+input.forward.z});
        history->Record(bindings,gpu,instances,config,lights,input.sceneRevision,input.lightRevision,input.resetHistory);
        context.list->EndQuery(timestamps.Get(),D3D12_QUERY_TYPE_TIMESTAMP,2);
        ID3D12Resource* shown=history->Resource();auto shownState=D3D12_RESOURCE_STATE_UNORDERED_ACCESS;unsigned shownStride=sizeof(PathHistoryPixel);
        ComPtr<ID3D12Resource> colorReadback,guideReadback;
        if(input.temporal){
            if(!temporal)temporal=std::make_unique<TemporalFilter>(context,settings.width,settings.height,shared->logicalBytes,shaderDirectory);
            const bool reset=input.resetHistory||!lastTemporal||input.lightScale!=lastLightScale||input.lightRevision!=lastLightRevision||input.skyEnabled!=lastSky||input.skyIntensity!=lastSkyIntensity||input.smoothNormals!=lastSmooth;
            shown=temporal->Record(bindings,gpu,instances,config,history->Resource(),reset);shownState=D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;shownStride=16;
            if(settings.readback){auto copy=[&](ID3D12Resource* source){auto read=MakeResource(context,BufferDesc(source->GetDesc().Width),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
                Transition(context,source,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_SOURCE);context.list->CopyBufferRegion(read.Get(),0,source,0,source->GetDesc().Width);Transition(context,source,D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);return read;};
                colorReadback=copy(temporal->CurrentColor());guideReadback=copy(temporal->CurrentGuide());}
        }
        lastTemporal=input.temporal;lastLightScale=input.lightScale;lastLightRevision=input.lightRevision;
        lastSky=input.skyEnabled;lastSkyIntensity=input.skyIntensity;lastSmooth=input.smoothNormals;
        context.list->EndQuery(timestamps.Get(),D3D12_QUERY_TYPE_TIMESTAMP,3);
        Barrier(context.list.Get(),gpu.vertices.Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COMMON);
        // 单帧同步基线：本地Fence覆盖DXR及consumed signal，CPU参考图像只用于当前验收。
        if(display){struct Rect{unsigned x,y,w,h;};auto constants=display->constants(Rect{0,0,settings.width,settings.height},input.exposure,settings.width,settings.height,shownStride);display->record(context.list.Get(),shown,constants,shownState);}
        context.list->EndQuery(timestamps.Get(),D3D12_QUERY_TYPE_TIMESTAMP,4);context.list->ResolveQueryData(timestamps.Get(),D3D12_QUERY_TYPE_TIMESTAMP,0,5,timestampReadback.Get(),0);
        auto submitted=[&]{if(display)display->present();Check(context.queue->Signal(consumed->fence.Get(),frame+1),"D3D consumed signal");};
        std::vector<PathHistoryPixel> pixels;
        if(settings.readback)pixels=history->Readback(submitted);else history->Flush(submitted);
        RenderImage image;image.width=settings.width;image.height=settings.height;image.samples=history->Count();image.generation=history->Generation();
        for(const auto& pixel:pixels){Require(pixel.value.errors[0]==0&&pixel.value.errors[1]==0,"path tracer invalid result");std::array<float,4> color{};std::copy_n(pixel.value.radiance,4,color.data());image.color.push_back(color);}
        if(colorReadback){image.temporalColor.resize(size_t(settings.width)*settings.height);image.motionGuides.resize(image.temporalColor.size());
            auto read=[&](ID3D12Resource* source,void* target){void* mapped=nullptr;D3D12_RANGE range{0,size_t(source->GetDesc().Width)},noWrite{0,0};Check(source->Map(0,&range,&mapped),"temporal readback");memcpy(target,mapped,range.End);source->Unmap(0,&noWrite);};
            read(colorReadback.Get(),image.temporalColor.data());read(guideReadback.Get(),image.motionGuides.data());}
        if(temporal)temporal->RetireAfterFence();
        UINT64* times=nullptr;D3D12_RANGE timestampRange{0,5*sizeof(UINT64)},noWrite{0,0};Check(timestampReadback->Map(0,&timestampRange,reinterpret_cast<void**>(&times)),"read GPU timings");
        stats.asMilliseconds=double(times[1]-times[0])*1000/timestampFrequency;stats.pathMilliseconds=double(times[2]-times[1])*1000/timestampFrequency;
        stats.temporalMilliseconds=double(times[3]-times[2])*1000/timestampFrequency;stats.displayMilliseconds=double(times[4]-times[3])*1000/timestampFrequency;timestampReadback->Unmap(0,&noWrite);
        float cudaMs=0;CheckCuda(cudaEventElapsedTime(&cudaMs,cudaStart,cudaEnd),"skin elapsed");stats.cudaMilliseconds=cudaMs;
        DXGI_QUERY_VIDEO_MEMORY_INFO memory{};Check(adapter->QueryVideoMemoryInfo(0,DXGI_MEMORY_SEGMENT_GROUP_LOCAL,&memory),"local memory");stats.localMemoryBytes=memory.CurrentUsage;
        ++frame;stats.frameNumber=frame;stats.accumulatedSamples=image.samples;stats.frameMilliseconds=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();return image;
    }
};
DxrRenderer::DxrRenderer(const Rig& rig,CpuScene scene,const RenderSettings& settings,const std::filesystem::path& shaders,const std::filesystem::path& energy):impl_(std::make_unique<Impl>(rig,std::move(scene),settings,shaders,energy)){}
DxrRenderer::~DxrRenderer()=default;
RenderImage DxrRenderer::Render(const RenderFrame& frame,bool rebuild){return impl_->Render(frame,rebuild);}
unsigned DxrRenderer::DebugErrors(){return impl_->context.CheckDebug();}
const RendererStats& DxrRenderer::Stats()const{return impl_->stats;}
void* DxrRenderer::NativeWindow()const{return impl_->display?impl_->display->native_handle():nullptr;}
bool DxrRenderer::PumpWindow(){return impl_->display&&impl_->display->pump();}
bool DxrRenderer::Suspended()const{return impl_->display&&impl_->display->suspended();}
void DxrRenderer::ApplyWindowResize(){if(impl_->display)impl_->display->apply_resize();}
}
