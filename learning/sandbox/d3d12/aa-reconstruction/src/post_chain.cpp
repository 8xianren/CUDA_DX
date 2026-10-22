#include "post_chain.h"
#include "NIS_Config.h"
#include <cstring>
#include <stdexcept>
namespace aa {
PostChain::PostChain(UploadContext& context,const fs::path& path):c(context),shaders(path){
    // 每次dispatch分配8+2个独立descriptor；同一提交内改写之前的shader-visible槽会竞态。
    descriptors=Heap(c,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,2048,true);rtv=Heap(c,D3D12_DESCRIPTOR_HEAP_TYPE_RTV,1);
    D3D12_DESCRIPTOR_RANGE ranges[]={{D3D12_DESCRIPTOR_RANGE_TYPE_SRV,8,0,0,0},{D3D12_DESCRIPTOR_RANGE_TYPE_UAV,2,0,0,0}};
    D3D12_ROOT_PARAMETER rp[3]{};rp[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;rp[0].Constants={0,0,32};
    for(int i=0;i<2;++i){rp[i+1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;rp[i+1].DescriptorTable={1,&ranges[i]};}
    D3D12_STATIC_SAMPLER_DESC sm{};sm.Filter=D3D12_FILTER_MIN_MAG_MIP_LINEAR;sm.AddressU=sm.AddressV=sm.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP;sm.MaxLOD=D3D12_FLOAT32_MAX;
    D3D12_ROOT_SIGNATURE_DESC rd{3,rp,1,&sm,D3D12_ROOT_SIGNATURE_FLAG_NONE};computeRoot=Root(c,rd);
    rp[0].Constants.Num32BitValues=4;rd.NumParameters=2;displayRoot=Root(c,rd);
    for(int k=0;k<2;++k){coefficients[k]=MakeTexture(c,2,64,DXGI_FORMAT_R32G32B32A32_FLOAT,D3D12_RESOURCE_FLAG_NONE);std::vector<float> values(512);memcpy(values.data(),k?coef_usm:coef_scale,512*sizeof(float));UploadFloat(c,coefficients[k],values);}
}
ID3D12PipelineState* PostChain::Compute(const std::string& entry){if(!compute.count(entry)){auto bytes=Shader(shaders/(entry+".dxil"));D3D12_COMPUTE_PIPELINE_STATE_DESC d{};d.pRootSignature=computeRoot.Get();d.CS={bytes.data(),bytes.size()};Check(c.device->CreateComputePipelineState(&d,IID_PPV_ARGS(&compute[entry])),"F compute PSO");}return compute[entry].Get();}
void PostChain::Dispatch(const std::string& entry,const PostConstants& constants,Texture& current,Texture& history,Texture& motion,Texture& depth,Texture& reactive,Texture& out,Texture& diag){
    if(cursor+10>2048)throw std::runtime_error("post descriptor slots exhausted; submit before reuse");
    Texture* inputs[]={&current,&history,&motion,&depth,&reactive};
    for(UINT i=0;i<8;++i){auto& t=*inputs[i<5?i:0];if(t.resource==out.resource||t.resource==diag.resource)throw std::runtime_error("post input/output feedback forbidden");t.To(c,ReadState);Srv(c,t,descriptors.Get(),cursor+i);}
    out.To(c,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);diag.To(c,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);Uav(c,out,descriptors.Get(),cursor+8);Uav(c,diag,descriptors.Get(),cursor+9);
    c.list->SetComputeRootSignature(computeRoot.Get());c.list->SetPipelineState(Compute(entry));ID3D12DescriptorHeap* heaps[]={descriptors.Get()};c.list->SetDescriptorHeaps(1,heaps);
    c.list->SetComputeRoot32BitConstants(0,16,&constants,0);c.list->SetComputeRootDescriptorTable(1,Gpu(c,descriptors.Get(),cursor));c.list->SetComputeRootDescriptorTable(2,Gpu(c,descriptors.Get(),cursor+8));
    c.list->Dispatch((constants.outputWidth+7)/8,(constants.outputHeight+7)/8,1);cursor+=10;
    D3D12_RESOURCE_BARRIER b[2]{};for(int i=0;i<2;++i){b[i].Type=D3D12_RESOURCE_BARRIER_TYPE_UAV;b[i].UAV.pResource=i?diag.resource.Get():out.resource.Get();}c.list->ResourceBarrier(2,b);
}
void PostChain::Nis(Texture& input,Texture& output){
    NISConfig cfg{};if(!NVScalerUpdateConfig(cfg,0.f,0,0,input.width,input.height,input.width,input.height,0,0,output.width,output.height,output.width,output.height,NISHDRMode::Linear))throw std::runtime_error("NIS scale outside 0.5..1");
    if(cursor+10>2048)throw std::runtime_error("NIS slots exhausted");input.To(c,ReadState);output.To(c,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    for(UINT i=0;i<8;++i){auto& t=i==1?coefficients[0]:i==2?coefficients[1]:input;Srv(c,t,descriptors.Get(),cursor+i);}Uav(c,output,descriptors.Get(),cursor+8);Uav(c,output,descriptors.Get(),cursor+9);
    c.list->SetComputeRootSignature(computeRoot.Get());c.list->SetPipelineState(Compute("NisCS"));ID3D12DescriptorHeap* heaps[]={descriptors.Get()};c.list->SetDescriptorHeaps(1,heaps);c.list->SetComputeRoot32BitConstants(0,28,&cfg,0);c.list->SetComputeRootDescriptorTable(1,Gpu(c,descriptors.Get(),cursor));c.list->SetComputeRootDescriptorTable(2,Gpu(c,descriptors.Get(),cursor+8));c.list->Dispatch((output.width+31)/32,(output.height+23)/24,1);cursor+=10;D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_UAV;b.UAV.pResource=output.resource.Get();c.list->ResourceBarrier(1,&b);
}
void PostChain::Display(Texture& input,Texture& output,UINT mode,float exposure,bool ui,UINT frame){
    if(input.resource==output.resource)throw std::runtime_error("display feedback forbidden");
    if(!display.count(output.format)){auto vs=Shader(shaders/"display_vs.dxil"),ps=Shader(shaders/"display_ps.dxil");D3D12_GRAPHICS_PIPELINE_STATE_DESC d{};d.pRootSignature=displayRoot.Get();d.VS={vs.data(),vs.size()};d.PS={ps.data(),ps.size()};d.BlendState.RenderTarget[0].RenderTargetWriteMask=15;d.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;d.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;d.RasterizerState.DepthClipEnable=TRUE;d.SampleMask=UINT_MAX;d.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;d.NumRenderTargets=1;d.RTVFormats[0]=output.format;d.SampleDesc.Count=1;Check(c.device->CreateGraphicsPipelineState(&d,IID_PPV_ARGS(&display[output.format])),"F fullscreen PSO");}
    input.To(c,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);output.To(c,D3D12_RESOURCE_STATE_RENDER_TARGET);Srv(c,input,descriptors.Get(),cursor);for(UINT i=1;i<8;++i)Srv(c,input,descriptors.Get(),cursor+i);
    c.device->CreateRenderTargetView(output.resource.Get(),nullptr,Cpu(c,rtv.Get()));auto h=Cpu(c,rtv.Get());c.list->OMSetRenderTargets(1,&h,FALSE,nullptr);Viewport(c,output.width,output.height);c.list->SetGraphicsRootSignature(displayRoot.Get());c.list->SetPipelineState(display[output.format].Get());ID3D12DescriptorHeap* heaps[]={descriptors.Get()};c.list->SetDescriptorHeaps(1,heaps);struct{UINT mode;float exposure;UINT ui,frame;}args{mode,exposure,UINT(ui),frame};c.list->SetGraphicsRoot32BitConstants(0,4,&args,0);c.list->SetGraphicsRootDescriptorTable(1,Gpu(c,descriptors.Get(),cursor));cursor+=8;c.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);c.list->DrawInstanced(3,1,0,0);
}
}
