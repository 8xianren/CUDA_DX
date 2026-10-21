#include "raster.h"
#include "external.h"
#include "vertex_update.h"
#include <d3dcompiler.h>
#include <cstring>
#include <iostream>

static ComPtr<ID3DBlob> Compile(const std::filesystem::path& path,const char* entry,const char* profile){
    ComPtr<ID3DBlob> b,e;auto hr=D3DCompileFromFile(path.c_str(),nullptr,D3D_COMPILE_STANDARD_FILE_INCLUDE,
        entry,profile,D3DCOMPILE_ENABLE_STRICTNESS,0,&b,&e);
    if(e)std::cerr<<static_cast<const char*>(e->GetBufferPointer());Check(hr,"compile raster");return b;
}
Raster::Raster(UploadContext& c,const std::filesystem::path& shader,unsigned width,unsigned height){
    camera.width=width;camera.height=height;
    // root SRV是GPU虚拟地址，不是descriptor table。结构化buffer的80B stride由shader类型给出。
    D3D12_ROOT_PARAMETER p[4]{};
    p[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;p[0].Descriptor={0,0};
    p[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;p[1].Descriptor={0,0};
    p[2].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;p[2].Constants={1,0,1};
    p[3].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;p[3].Constants={2,0,1};
    D3D12_ROOT_SIGNATURE_DESC d{4,p,0,nullptr,D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT};
    ComPtr<ID3DBlob> blob,error;Check(D3D12SerializeRootSignature(&d,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&error),"serialize root");
    Check(c.device->CreateRootSignature(0,blob->GetBufferPointer(),blob->GetBufferSize(),IID_PPV_ARGS(&root)),"root signature");
    auto vs=Compile(shader,"VS","vs_5_1"),ps=Compile(shader,"PS","ps_5_1");
    D3D12_INPUT_ELEMENT_DESC input{"POSITION",0,DXGI_FORMAT_R32G32B32_FLOAT,0,0,D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,0};
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pd{};pd.pRootSignature=root.Get();
    pd.VS={vs->GetBufferPointer(),vs->GetBufferSize()};pd.PS={ps->GetBufferPointer(),ps->GetBufferSize()};
    pd.InputLayout={&input,1};pd.SampleMask=UINT_MAX;pd.SampleDesc.Count=1;
    pd.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;pd.NumRenderTargets=1;
    pd.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;
    pd.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;pd.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;pd.RasterizerState.DepthClipEnable=TRUE;
    pd.DepthStencilState.DepthFunc=D3D12_COMPARISON_FUNC_ALWAYS;
    // 平面测试使用提交次序覆盖；CPU参考采用相同覆盖规则，不假装已解决通用深度排序。
    auto& blend=pd.BlendState.RenderTarget[0];blend.SrcBlend=blend.SrcBlendAlpha=D3D12_BLEND_ONE;
    blend.DestBlend=blend.DestBlendAlpha=D3D12_BLEND_ZERO;blend.BlendOp=blend.BlendOpAlpha=D3D12_BLEND_OP_ADD;
    blend.LogicOp=D3D12_LOGIC_OP_NOOP;blend.RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
    Check(c.device->CreateGraphicsPipelineState(&pd,IID_PPV_ARGS(&pso)),"raster PSO");
    uint8_t cameraBytes[256]{};memcpy(cameraBytes,camera.viewProjection.m.data(),64);
    cameraBuffer=InstanceUpload(c,cameraBytes,sizeof(cameraBytes));
    D3D12_RESOURCE_DESC td{};td.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;td.Width=camera.width;td.Height=camera.height;
    td.DepthOrArraySize=td.MipLevels=1;td.SampleDesc.Count=1;td.Format=pd.RTVFormats[0];td.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    target=MakeResource(c,td,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);
    c.device->GetCopyableFootprints(&td,0,1,0,&footprint,nullptr,nullptr,&copyBytes);
    D3D12_DESCRIPTOR_HEAP_DESC hd{};hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;hd.NumDescriptors=1;
    Check(c.device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&rtv)),"RTV heap");
    c.device->CreateRenderTargetView(target.Get(),nullptr,rtv->GetCPUDescriptorHandleForHeapStart());
}
FrameCommands Raster::Record(UploadContext& c,const GpuScene& gpu,const CpuScene& cpu,ID3D12Resource* objects,uint64_t bytes,ID3D12Resource* dynamicVertices,const RenderSettings& settings){
    FrameCommands f;
    Check(c.device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&f.allocator)),"frame allocator");
    Check(c.device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,f.allocator.Get(),pso.Get(),IID_PPV_ARGS(&f.list)),"frame list");
    if(settings.capture){
        f.pixels=MakeResource(c,BufferDesc(copyBytes),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
        f.instances=MakeResource(c,BufferDesc(bytes),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    }
    auto* l=f.list.Get();
    if(settings.timestamps)l->EndQuery(settings.timestamps,D3D12_QUERY_TYPE_TIMESTAMP,settings.queryBase);
    // COMMON是本课约定的跨API交接状态；Barrier不代替CUDA external fence。
    Barrier(l,objects,D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    if(dynamicVertices){
        Barrier(l,dynamicVertices,D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER);
        if(settings.capture)f.vertices=MakeResource(c,BufferDesc(dynamicVertices->GetDesc().Width),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    }
    auto handle=rtv->GetCPUDescriptorHandleForHeapStart();const float clear[4]{};
    l->ClearRenderTargetView(handle,clear,0,nullptr);l->OMSetRenderTargets(1,&handle,FALSE,nullptr);
    D3D12_VIEWPORT viewport{0,0,float(camera.width),float(camera.height),0,1};D3D12_RECT scissor{0,0,LONG(camera.width),LONG(camera.height)};
    l->RSSetViewports(1,&viewport);l->RSSetScissorRects(1,&scissor);l->SetGraphicsRootSignature(root.Get());
    l->SetGraphicsRoot32BitConstant(3,settings.pixelIterations,0);
    l->SetGraphicsRootConstantBufferView(0,cameraBuffer->GetGPUVirtualAddress());
    l->SetGraphicsRootShaderResourceView(1,objects->GetGPUVirtualAddress());
    l->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);l->IASetVertexBuffers(0,1,&gpu.vb);l->IASetIndexBuffer(&gpu.ib);
    for(UINT i=0;i<cpu.instances.size();++i){
        l->SetGraphicsRoot32BitConstant(2,i,0);const auto& mesh=gpu.meshes.at(cpu.instances[i].meshIndex);
        // 动态mesh0是紧密局部副本，BaseVertex=0；其他mesh继续使用静态全局VB和原BaseVertex。
        bool dynamic=dynamicVertices && cpu.instances[i].meshIndex==0;
        D3D12_VERTEX_BUFFER_VIEW view=dynamic?D3D12_VERTEX_BUFFER_VIEW{
            dynamicVertices->GetGPUVirtualAddress()+VertexGuard,mesh.vertexCount*VertexStride,VertexStride}:gpu.vb;
        l->IASetVertexBuffers(0,1,&view);
        l->DrawIndexedInstanced(mesh.indexCount,1,mesh.firstIndex,dynamic?0:INT(mesh.firstVertex),0);
    }
    if(settings.capture && dynamicVertices){
        Barrier(l,dynamicVertices,D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER,D3D12_RESOURCE_STATE_COPY_SOURCE);
        l->CopyBufferRegion(f.vertices.Get(),0,dynamicVertices,0,dynamicVertices->GetDesc().Width);
        Barrier(l,dynamicVertices,D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_COMMON);
    }
    if(settings.capture){
    Barrier(l,objects,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_SOURCE);
    l->CopyBufferRegion(f.instances.Get(),0,objects,0,bytes);
    Barrier(l,objects,D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_COMMON);
    Barrier(l,target.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION src{};src.pResource=target.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    D3D12_TEXTURE_COPY_LOCATION dst{};dst.pResource=f.pixels.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;
    l->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
    Barrier(l,target.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_RENDER_TARGET);
    } else {
        Barrier(l,objects,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COMMON);
        if(dynamicVertices)Barrier(l,dynamicVertices,D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER,D3D12_RESOURCE_STATE_COMMON);
    }
    if(settings.timestamps){
        l->EndQuery(settings.timestamps,D3D12_QUERY_TYPE_TIMESTAMP,settings.queryBase+1);
        l->ResolveQueryData(settings.timestamps,D3D12_QUERY_TYPE_TIMESTAMP,settings.queryBase,2,
            settings.timestampReadback,UINT64(settings.queryBase)*sizeof(uint64_t));
    }
    Check(l->Close(),"frame close");return f;
}
std::vector<float> Raster::ReadPixels(FrameCommands& f)const{
    std::vector<float> out(size_t(camera.width)*camera.height*4);void* p=nullptr;
    D3D12_RANGE read{0,SIZE_T(copyBytes)},noWrite{0,0};Check(f.pixels->Map(0,&read,&p),"pixel readback");
    for(UINT y=0;y<camera.height;++y)memcpy(out.data()+size_t(y)*camera.width*4,
        static_cast<const uint8_t*>(p)+footprint.Offset+y*footprint.Footprint.RowPitch,size_t(camera.width)*16);
    f.pixels->Unmap(0,&noWrite);return out;
}
