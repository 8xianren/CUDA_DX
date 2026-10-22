#include "graphics.h"
#include <cmath>
namespace neural {
namespace {
struct Constants{float aspect,tanHalfFov;UINT foreground,encode;};
D3D12_GRAPHICS_PIPELINE_STATE_DESC Base(ID3D12RootSignature* root){
    D3D12_GRAPHICS_PIPELINE_STATE_DESC d{};d.pRootSignature=root;
    d.BlendState.RenderTarget[0].RenderTargetWriteMask=15;
    d.BlendState.RenderTarget[1].RenderTargetWriteMask=15;
    d.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;d.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;
    d.RasterizerState.DepthClipEnable=TRUE;d.SampleMask=UINT_MAX;
    d.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;d.SampleDesc.Count=1;return d;
}
}
Graphics::Graphics(UploadContext& context,const std::filesystem::path& shaders):c(context),path(shaders){
    D3D12_DESCRIPTOR_RANGE range{D3D12_DESCRIPTOR_RANGE_TYPE_SRV,2,0,0,0};
    D3D12_ROOT_PARAMETER params[2]{};params[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    params[0].Constants={0,0,4};params[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    params[1].DescriptorTable={1,&range};D3D12_ROOT_SIGNATURE_DESC rd{2,params,0,nullptr,D3D12_ROOT_SIGNATURE_FLAG_NONE};
    root=aa::Root(c,rd);srv=aa::Heap(c,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,2,true);
    rtv=aa::Heap(c,D3D12_DESCRIPTOR_HEAP_TYPE_RTV,3);dsv=aa::Heap(c,D3D12_DESCRIPTOR_HEAP_TYPE_DSV,1);
    auto vs=aa::Shader(path/"MeshVS.dxil"),ps=aa::Shader(path/"MeshPS.dxil");auto d=Base(root.Get());
    d.VS={vs.data(),vs.size()};d.PS={ps.data(),ps.size()};d.NumRenderTargets=2;
    d.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;d.RTVFormats[1]=DXGI_FORMAT_R32_FLOAT;
    d.DepthStencilState.DepthEnable=TRUE;d.DepthStencilState.DepthWriteMask=D3D12_DEPTH_WRITE_MASK_ALL;
    d.DepthStencilState.DepthFunc=D3D12_COMPARISON_FUNC_LESS;d.DSVFormat=DXGI_FORMAT_D32_FLOAT;
    // 独立 BlendState 才允许两个 MRT 使用不同 write mask/格式（R32 只写R）。
    d.BlendState.IndependentBlendEnable=TRUE;d.BlendState.RenderTarget[1].RenderTargetWriteMask=1;
    Check(c.device->CreateGraphicsPipelineState(&d,IID_PPV_ARGS(&meshPso)),"G mesh PSO");
}
void Graphics::Mesh(aa::Texture& color,aa::Texture& z,aa::Texture& depth,bool front){
    color.To(c,D3D12_RESOURCE_STATE_RENDER_TARGET);z.To(c,D3D12_RESOURCE_STATE_RENDER_TARGET);
    depth.To(c,D3D12_RESOURCE_STATE_DEPTH_WRITE);
    c.device->CreateRenderTargetView(color.resource.Get(),nullptr,aa::Cpu(c,rtv.Get(),0));
    c.device->CreateRenderTargetView(z.resource.Get(),nullptr,aa::Cpu(c,rtv.Get(),1));
    D3D12_DEPTH_STENCIL_VIEW_DESC dd{};dd.Format=DXGI_FORMAT_D32_FLOAT;dd.ViewDimension=D3D12_DSV_DIMENSION_TEXTURE2D;
    c.device->CreateDepthStencilView(depth.resource.Get(),&dd,aa::Cpu(c,dsv.Get()));
    auto rh=aa::Cpu(c,rtv.Get()),dh=aa::Cpu(c,dsv.Get());
    const float clear[4]={0,0,0,1},farColor[4]={10,0,0,0};
    c.list->ClearRenderTargetView(rh,clear,0,nullptr);c.list->ClearRenderTargetView(aa::Cpu(c,rtv.Get(),1),farColor,0,nullptr);
    c.list->ClearDepthStencilView(dh,D3D12_CLEAR_FLAG_DEPTH,1,0,0,nullptr);
    c.list->OMSetRenderTargets(2,&rh,TRUE,&dh);aa::Viewport(c,color.width,color.height);
    c.list->SetGraphicsRootSignature(root.Get());c.list->SetPipelineState(meshPso.Get());
    Constants constants{float(color.width)/color.height,std::tan(25.f*3.14159265359f/180),UINT(front),0};
    c.list->SetGraphicsRoot32BitConstants(0,4,&constants,0);
    c.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    c.list->DrawInstanced(front?12:6,1,0,0);
}
void Graphics::Composite(aa::Texture& radiance,aa::Texture& mesh,aa::Texture& target,bool useRadiance,bool encode){
    // 每次调用前上一提交已完成，因此可安全覆写两个descriptor槽。多帧引擎须分帧槽。
    if(!compositePso.count(target.format)){
        auto vs=aa::Shader(path/"FullVS.dxil"),ps=aa::Shader(path/"CompositePS.dxil");auto d=Base(root.Get());
        d.VS={vs.data(),vs.size()};d.PS={ps.data(),ps.size()};d.NumRenderTargets=1;d.RTVFormats[0]=target.format;
        Check(c.device->CreateGraphicsPipelineState(&d,IID_PPV_ARGS(&compositePso[target.format])),"G composite PSO");
    }
    radiance.To(c,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);mesh.To(c,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    target.To(c,D3D12_RESOURCE_STATE_RENDER_TARGET);aa::Srv(c,radiance,srv.Get(),0);aa::Srv(c,mesh,srv.Get(),1);
    c.device->CreateRenderTargetView(target.resource.Get(),nullptr,aa::Cpu(c,rtv.Get(),2));auto h=aa::Cpu(c,rtv.Get(),2);
    c.list->OMSetRenderTargets(1,&h,FALSE,nullptr);aa::Viewport(c,target.width,target.height);
    c.list->SetGraphicsRootSignature(root.Get());c.list->SetPipelineState(compositePso[target.format].Get());
    ID3D12DescriptorHeap* heaps[]={srv.Get()};c.list->SetDescriptorHeaps(1,heaps);
    Constants constants{float(target.width)/target.height,std::tan(25.f*3.14159265359f/180),UINT(useRadiance),UINT(encode)};
    c.list->SetGraphicsRoot32BitConstants(0,4,&constants,0);c.list->SetGraphicsRootDescriptorTable(1,aa::Gpu(c,srv.Get()));
    c.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);c.list->DrawInstanced(3,1,0,0);
}
}
