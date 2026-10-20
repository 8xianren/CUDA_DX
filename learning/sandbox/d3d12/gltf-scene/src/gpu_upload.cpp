#include "gpu_upload.h"
#include <d3d12sdklayers.h>
#include <wincodec.h>
#include <iostream>
#include <stdexcept>
#include <cstring>
#include <limits>
void Check(HRESULT hr,const char* operation) {
    if(FAILED(hr)) throw std::runtime_error(std::string(operation)+" HRESULT="+std::to_string(uint32_t(hr)));
}
UploadContext::UploadContext() {
    ComPtr<ID3D12Debug> debug;Check(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)),"debug layer");debug->EnableDebugLayer();
    ComPtr<ID3D12Debug1> debug1;Check(debug.As(&debug1),"debug1");debug1->SetEnableGPUBasedValidation(TRUE);
    ComPtr<IDXGIFactory6> factory;Check(CreateDXGIFactory2(DXGI_CREATE_FACTORY_DEBUG,IID_PPV_ARGS(&factory)),"factory");
    for(UINT i=0;;++i) {
        ComPtr<IDXGIAdapter1> adapter;
        if(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter))==DXGI_ERROR_NOT_FOUND) break;
        DXGI_ADAPTER_DESC1 desc{};Check(adapter->GetDesc1(&desc),"adapter desc");
        if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE) continue;
        if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_12_1,IID_PPV_ARGS(&device)))) {
            std::wcout<<L"adapter="<<desc.Description<<L"\n";break;
        }
    }
    if(!device) throw std::runtime_error("hardware D3D12 device unavailable");
    D3D12_FEATURE_DATA_D3D12_OPTIONS5 options{};Check(device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS5,&options,sizeof(options)),"DXR feature");
    if(options.RaytracingTier==D3D12_RAYTRACING_TIER_NOT_SUPPORTED) throw std::runtime_error("DXR unavailable");
    Check(device.As(&info),"info queue");
    D3D12_COMMAND_QUEUE_DESC q{};q.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;
    Check(device->CreateCommandQueue(&q,IID_PPV_ARGS(&queue)),"queue");
    Check(device->CreateCommandAllocator(q.Type,IID_PPV_ARGS(&allocator)),"allocator");
    Check(device->CreateCommandList(0,q.Type,allocator.Get(),nullptr,IID_PPV_ARGS(&list)),"list");
    Check(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)),"fence");
}
void UploadContext::SubmitWait() {
    Check(list->Close(),"close list");
    ID3D12CommandList* lists[]={list.Get()};queue->ExecuteCommandLists(1,lists);
    Check(queue->Signal(fence.Get(),++submitted),"queue signal");
    HANDLE event=CreateEventW(nullptr,FALSE,FALSE,nullptr);
    if(!event) throw std::runtime_error("CreateEvent failed");
    HRESULT hr=fence->SetEventOnCompletion(submitted,event);
    if(FAILED(hr)){CloseHandle(event);Check(hr,"fence event");}
    // 有界等待，超时是失败，不能继续Map读回或复用仍被GPU引用的allocator。
    DWORD wait=WaitForSingleObject(event,30000);CloseHandle(event);
    if(wait!=WAIT_OBJECT_0) throw std::runtime_error("GPU wait timeout/failure");
    if(fence->GetCompletedValue()==UINT64_MAX) Check(device->GetDeviceRemovedReason(),"device removed");
    Check(allocator->Reset(),"reset allocator");Check(list->Reset(allocator.Get(),nullptr),"reset list");
}
unsigned UploadContext::CheckDebug() {
    unsigned bad=0;
    for(UINT64 i=0;i<info->GetNumStoredMessages();++i) {
        SIZE_T n=0;Check(info->GetMessage(i,nullptr,&n),"debug size");std::vector<uint8_t> bytes(n);
        auto* msg=reinterpret_cast<D3D12_MESSAGE*>(bytes.data());Check(info->GetMessage(i,msg,&n),"debug message");
        if(msg->Severity<=D3D12_MESSAGE_SEVERITY_WARNING) {++bad;std::cerr<<msg->pDescription<<"\n";}
    }
    std::cout<<"debug_warning_error="<<bad<<" fence="<<fence->GetCompletedValue()<<"/"<<submitted<<"\n";return bad;
}
D3D12_RESOURCE_DESC BufferDesc(uint64_t bytes) {
    D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;d.Width=bytes;
    d.Height=1;d.DepthOrArraySize=1;d.MipLevels=1;d.SampleDesc.Count=1;d.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;return d;
}
ComPtr<ID3D12Resource> MakeResource(UploadContext& c,const D3D12_RESOURCE_DESC& d,D3D12_HEAP_TYPE type,D3D12_RESOURCE_STATES state) {
    D3D12_HEAP_PROPERTIES h{};h.Type=type;h.CreationNodeMask=h.VisibleNodeMask=1;
    ComPtr<ID3D12Resource> r;
    // 当前运行时普通Default Buffer以COMMON创建，再显式转换；AS保持专用初始状态。
    const bool commonBuffer=type==D3D12_HEAP_TYPE_DEFAULT && d.Dimension==D3D12_RESOURCE_DIMENSION_BUFFER
        && state!=D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE;
    D3D12_CLEAR_VALUE clear{};clear.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;clear.Color[3]=1;
    const auto* clearPtr=(d.Flags&D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET)?&clear:nullptr;
    Check(c.device->CreateCommittedResource(&h,D3D12_HEAP_FLAG_NONE,&d,commonBuffer?D3D12_RESOURCE_STATE_COMMON:state,clearPtr,IID_PPV_ARGS(&r)),"CreateCommittedResource");
    if(commonBuffer && state!=D3D12_RESOURCE_STATE_COMMON) Transition(c,r.Get(),D3D12_RESOURCE_STATE_COMMON,state);
    return r;
}
void Transition(UploadContext& c,ID3D12Resource* r,D3D12_RESOURCE_STATES before,D3D12_RESOURCE_STATES after) {
    D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;b.Transition={r,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,before,after};
    c.list->ResourceBarrier(1,&b);
}
Pixels DecodeImage(const CpuImage& image) {
    // Windows Imaging Component负责PNG/JPEG解码；原始编码字节不能作为RGBA texture上传。
    if(image.encodedBytes.empty() || image.encodedBytes.size()>MAXDWORD) throw std::runtime_error("encoded image size invalid");
    ComPtr<IWICImagingFactory> factory;Check(CoCreateInstance(CLSID_WICImagingFactory,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&factory)),"WIC factory");
    ComPtr<IWICStream> stream;Check(factory->CreateStream(&stream),"WIC stream");
    Check(stream->InitializeFromMemory(const_cast<BYTE*>(image.encodedBytes.data()),DWORD(image.encodedBytes.size())),"WIC memory");
    ComPtr<IWICBitmapDecoder> decoder;Check(factory->CreateDecoderFromStream(stream.Get(),nullptr,WICDecodeMetadataCacheOnLoad,&decoder),"WIC decoder");
    ComPtr<IWICBitmapFrameDecode> frame;Check(decoder->GetFrame(0,&frame),"WIC frame0");
    Pixels p;Check(frame->GetSize(&p.width,&p.height),"WIC size");
    const uint64_t size=uint64_t(p.width)*p.height*4;
    if(!p.width||!p.height||p.width>16384||p.height>16384||size>256ull*1024*1024) throw std::runtime_error("decoded image exceeds D.1 limit");
    ComPtr<IWICFormatConverter> converter;Check(factory->CreateFormatConverter(&converter),"WIC converter");
    // 非预乘RGBA8：保留编码数值，不在此做sRGB→linear；由用途对应的SRV解释。
    Check(converter->Initialize(frame.Get(),GUID_WICPixelFormat32bppRGBA,WICBitmapDitherTypeNone,nullptr,0,WICBitmapPaletteTypeCustom),"WIC RGBA");
    p.rgba.resize(size);Check(converter->CopyPixels(nullptr,p.width*4,UINT(size),p.rgba.data()),"WIC pixels");return p;
}
static ComPtr<ID3D12Resource> UploadBuffer(UploadContext& c,GpuScene& out,const void* data,UINT64 size,D3D12_RESOURCE_STATES finalState) {
    auto dest=MakeResource(c,BufferDesc(size),D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);
    auto src=MakeResource(c,BufferDesc(size),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
    void* mapped=nullptr;D3D12_RANGE noRead{0,0};Check(src->Map(0,&noRead,&mapped),"upload Map");
    memcpy(mapped,data,size);D3D12_RANGE written{0,SIZE_T(size)};src->Unmap(0,&written);
    c.list->CopyBufferRegion(dest.Get(),0,src.Get(),0,size);
    Transition(c,dest.Get(),D3D12_RESOURCE_STATE_COPY_DEST,finalState);out.staging.push_back(src);return dest;
}
GpuScene UploadScene(UploadContext& c,const CpuScene& source) {
    GpuScene out;
    for(const auto& mesh:source.meshes) {
        const auto v=out.referenceVertices.size(),i=out.referenceIndices.size();
        if((v+mesh.vertices.size())*sizeof(Vertex)>UINT_MAX||(i+mesh.indices.size())*4>UINT_MAX) throw std::runtime_error("D.1 buffer view too large");
        out.meshes.push_back({UINT(v),UINT(mesh.vertices.size()),UINT(i),UINT(mesh.indices.size()),mesh.materialIndex});
        out.referenceVertices.insert(out.referenceVertices.end(),mesh.vertices.begin(),mesh.vertices.end());
        // 索引保持mesh局部值；DrawIndexed使用BaseVertexLocation，BLAS使用偏移后的顶点地址。
        out.referenceIndices.insert(out.referenceIndices.end(),mesh.indices.begin(),mesh.indices.end());
    }
    constexpr auto vs=D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER|D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    constexpr auto is=D3D12_RESOURCE_STATE_INDEX_BUFFER|D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    out.vertices=UploadBuffer(c,out,out.referenceVertices.data(),out.referenceVertices.size()*sizeof(Vertex),vs);
    out.indices=UploadBuffer(c,out,out.referenceIndices.data(),out.referenceIndices.size()*4,is);
    out.vb={out.vertices->GetGPUVirtualAddress(),UINT(out.referenceVertices.size()*sizeof(Vertex)),sizeof(Vertex)};
    out.ib={out.indices->GetGPUVirtualAddress(),UINT(out.referenceIndices.size()*4),DXGI_FORMAT_R32_UINT};
    std::vector<Pixels> decoded;
    for(const auto& image:source.materialAssets.images) decoded.push_back(DecodeImage(image));
    // 缺失可选槽使用已知白像素；这是基础色预览的乘法单位元，不代表法线贴图默认值。
    const UINT fallback=UINT(decoded.size());decoded.push_back({1,1,{255,255,255,255}});
    D3D12_DESCRIPTOR_HEAP_DESC hd{};hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    hd.NumDescriptors=UINT(decoded.size()*2);hd.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    Check(c.device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&out.descriptors)),"SRV heap");
    out.descriptorStride=c.device->GetDescriptorHandleIncrementSize(hd.Type);
    for(UINT n=0;n<decoded.size();++n) {
        GpuImage img;img.reference=std::move(decoded[n]);
        D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;d.Width=img.reference.width;d.Height=img.reference.height;
        d.DepthOrArraySize=1;d.MipLevels=1;d.Format=DXGI_FORMAT_R8G8B8A8_TYPELESS;d.SampleDesc.Count=1;
        img.texture=MakeResource(c,d,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);
        UINT rows=0;UINT64 rowBytes=0;
        c.device->GetCopyableFootprints(&d,0,1,0,&img.footprint,&rows,&rowBytes,&img.copyBytes);
        auto staging=MakeResource(c,BufferDesc(img.copyBytes),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
        uint8_t* data=nullptr;D3D12_RANGE noRead{0,0};Check(staging->Map(0,&noRead,reinterpret_cast<void**>(&data)),"image Map");
        memset(data,0,SIZE_T(img.copyBytes));
        // RowPitch可能大于width*4；逐行跳到目标pitch，绝不能紧密memcpy整个像素数组。
        for(UINT y=0;y<rows;++y) memcpy(data+img.footprint.Offset+y*img.footprint.Footprint.RowPitch,img.reference.rgba.data()+y*rowBytes,SIZE_T(rowBytes));
        staging->Unmap(0,nullptr);
        D3D12_TEXTURE_COPY_LOCATION src{};src.pResource=staging.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;src.PlacedFootprint=img.footprint;
        D3D12_TEXTURE_COPY_LOCATION dst{};dst.pResource=img.texture.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;dst.SubresourceIndex=0;
        c.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
        Transition(c,img.texture.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE|D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        out.staging.push_back(staging);
        for(UINT s=0;s<2;++s) {
            D3D12_SHADER_RESOURCE_VIEW_DESC view{};view.Format=s?DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:DXGI_FORMAT_R8G8B8A8_UNORM;
            view.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;view.Texture2D.MipLevels=1;
            auto h=out.descriptors->GetCPUDescriptorHandleForHeapStart();h.ptr+=(n*2+s)*out.descriptorStride;
            c.device->CreateShaderResourceView(img.texture.Get(),&view,h);
        }
        std::cout<<"image="<<n<<" dimensions="<<d.Width<<"x"<<d.Height<<" rowBytes="<<rowBytes<<" pitch="<<img.footprint.Footprint.RowPitch<<" copyBytes="<<img.copyBytes<<"\n";
        out.images.push_back(std::move(img));
    }
    for(const auto& material:source.materialAssets.materials) {
        GpuMaterial m;m.factor=material.baseColor;
        for(UINT slot=0;slot<5;++slot) {
            const auto& b=material.textures[slot];
            // 非基础色缺失槽保留UINT_MAX，后续材质shader自行按语义取默认值。
            m.srv[slot]=b.image<0?(slot==0?fallback*2+1:UINT_MAX):UINT(b.image)*2+UINT(b.srgbRGB);
        }
        out.materials.push_back(m);
    }
    for(const auto& mesh:out.meshes) {
        D3D12_RAYTRACING_GEOMETRY_DESC g{};g.Type=D3D12_RAYTRACING_GEOMETRY_TYPE_TRIANGLES;
        // 不强制OPAQUE，避免未来接入MASK后跳过AnyHit；D.1只构建不发射射线。
        g.Flags=D3D12_RAYTRACING_GEOMETRY_FLAG_NONE;
        g.Triangles.VertexBuffer={out.vb.BufferLocation+UINT64(mesh.firstVertex)*sizeof(Vertex),sizeof(Vertex)};
        g.Triangles.VertexFormat=DXGI_FORMAT_R32G32B32_FLOAT;g.Triangles.VertexCount=mesh.vertexCount;
        g.Triangles.IndexBuffer=out.ib.BufferLocation+UINT64(mesh.firstIndex)*4;
        g.Triangles.IndexFormat=DXGI_FORMAT_R32_UINT;g.Triangles.IndexCount=mesh.indexCount;
        out.geometry.push_back(g);
    }
    return out;
}
void VerifyCopiesAndBuildBlas(UploadContext& c,GpuScene& scene) {
    // 与上传在同一命令列表录制，barrier定义复制写→读回/AS读取依赖。
    std::vector<ComPtr<ID3D12Resource>> reads,asResources;
    ID3D12Resource* buffers[]={scene.vertices.Get(),scene.indices.Get()};
    const D3D12_RESOURCE_STATES states[]={
        D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER|D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
        D3D12_RESOURCE_STATE_INDEX_BUFFER|D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE};
    for(int i=0;i<2;++i) {
        auto desc=buffers[i]->GetDesc();auto r=MakeResource(c,desc,D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
        Transition(c,buffers[i],states[i],D3D12_RESOURCE_STATE_COPY_SOURCE);
        c.list->CopyBufferRegion(r.Get(),0,buffers[i],0,desc.Width);
        Transition(c,buffers[i],D3D12_RESOURCE_STATE_COPY_SOURCE,states[i]);reads.push_back(r);
    }
    constexpr auto textureState=D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE|D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    for(auto& img:scene.images) {
        auto r=MakeResource(c,BufferDesc(img.copyBytes),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
        Transition(c,img.texture.Get(),textureState,D3D12_RESOURCE_STATE_COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION src{};src.pResource=img.texture.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        D3D12_TEXTURE_COPY_LOCATION dst{};dst.pResource=r.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=img.footprint;
        c.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);Transition(c,img.texture.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,textureState);reads.push_back(r);
    }
    for(const auto& geometry:scene.geometry) {
        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS input{};input.Type=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
        input.Flags=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
        input.DescsLayout=D3D12_ELEMENTS_LAYOUT_ARRAY;input.NumDescs=1;input.pGeometryDescs=&geometry;
        D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO sizes{};c.device->GetRaytracingAccelerationStructurePrebuildInfo(&input,&sizes);
        if(!sizes.ResultDataMaxSizeInBytes||!sizes.ScratchDataSizeInBytes) throw std::runtime_error("BLAS size zero");
        auto d=BufferDesc(sizes.ResultDataMaxSizeInBytes);d.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        auto result=MakeResource(c,d,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE);
        d.Width=sizes.ScratchDataSizeInBytes;
        auto scratch=MakeResource(c,d,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC build{};build.Inputs=input;
        build.DestAccelerationStructureData=result->GetGPUVirtualAddress();build.ScratchAccelerationStructureData=scratch->GetGPUVirtualAddress();
        c.list->BuildRaytracingAccelerationStructure(&build,0,nullptr);
        D3D12_RESOURCE_BARRIER barrier{};barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_UAV;barrier.UAV.pResource=result.Get();c.list->ResourceBarrier(1,&barrier);
        asResources.push_back(result);asResources.push_back(scratch);
    }
    c.SubmitWait(); // 所有staging、scratch、AS和readback保持存活到这里。
    const void* refs[]={scene.referenceVertices.data(),scene.referenceIndices.data()};
    for(int i=0;i<2;++i) {
        const SIZE_T n=SIZE_T(reads[i]->GetDesc().Width);void* data=nullptr;D3D12_RANGE range{0,n};Check(reads[i]->Map(0,&range,&data),"read buffer");
        bool equal=memcmp(data,refs[i],n)==0;D3D12_RANGE noWrite{0,0};reads[i]->Unmap(0,&noWrite);
        if(!equal) throw std::runtime_error("GPU buffer mismatch");
    }
    for(size_t i=0;i<scene.images.size();++i) {
        const auto& img=scene.images[i];uint8_t* data=nullptr;D3D12_RANGE range{0,SIZE_T(img.copyBytes)};
        Check(reads[i+2]->Map(0,&range,reinterpret_cast<void**>(&data)),"read texture");
        bool equal=true;size_t rowBytes=img.reference.width*4;
        for(UINT y=0;y<img.reference.height;++y) equal&=memcmp(data+img.footprint.Offset+y*img.footprint.Footprint.RowPitch,img.reference.rgba.data()+y*rowBytes,rowBytes)==0;
        D3D12_RANGE noWrite{0,0};reads[i+2]->Unmap(0,&noWrite);if(!equal) throw std::runtime_error("GPU texture mismatch");
    }
    scene.staging.clear(); // Fence已完成，现在可以释放上传页；GPU的Default资源仍然存活。
    std::cout<<"PASS buffer_readback texture_readback BLAS_build="<<scene.geometry.size()<<" upload_retired_after_fence\n";
}
