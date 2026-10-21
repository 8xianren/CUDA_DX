#include "static_audit.h"
#include <cstring>
std::vector<uint8_t> SnapshotStatic(UploadContext& c,const GpuScene& gpu){
    std::vector<ComPtr<ID3D12Resource>> reads;
    ID3D12Resource* resources[]={gpu.vertices.Get(),gpu.indices.Get()};
    D3D12_RESOURCE_STATES states[]={D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER|D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
        D3D12_RESOURCE_STATE_INDEX_BUFFER|D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE};
    for(unsigned i=0;i<2;++i){
        auto r=MakeResource(c,BufferDesc(resources[i]->GetDesc().Width),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
        Transition(c,resources[i],states[i],D3D12_RESOURCE_STATE_COPY_SOURCE);
        c.list->CopyBufferRegion(r.Get(),0,resources[i],0,resources[i]->GetDesc().Width);
        Transition(c,resources[i],D3D12_RESOURCE_STATE_COPY_SOURCE,states[i]);reads.push_back(r);
    }
    constexpr auto state=D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE|D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    for(const auto& image:gpu.images){
        auto r=MakeResource(c,BufferDesc(image.copyBytes),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
        Transition(c,image.texture.Get(),state,D3D12_RESOURCE_STATE_COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION src{};src.pResource=image.texture.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        D3D12_TEXTURE_COPY_LOCATION dst{};dst.pResource=r.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=image.footprint;
        c.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
        Transition(c,image.texture.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,state);reads.push_back(r);
    }
    c.SubmitWait();std::vector<uint8_t> out;
    for(size_t i=0;i<reads.size();++i){
        void* p=nullptr;D3D12_RANGE range{0,SIZE_T(reads[i]->GetDesc().Width)},noWrite{0,0};
        Check(reads[i]->Map(0,&range,&p),"static snapshot Map");auto* b=static_cast<uint8_t*>(p);
        if(i<2)out.insert(out.end(),b,b+range.End);
        else{const auto& image=gpu.images[i-2];for(unsigned y=0;y<image.reference.height;++y){
            auto* row=b+image.footprint.Offset+y*image.footprint.Footprint.RowPitch;
            out.insert(out.end(),row,row+image.reference.width*4);}}
        reads[i]->Unmap(0,&noWrite);
    }
    // CPU材质元数据也加入快照；不比较struct padding，字段逐个序列化。
    for(const auto& m:gpu.materials){
        auto* a=reinterpret_cast<const uint8_t*>(m.srv.data());out.insert(out.end(),a,a+sizeof(m.srv));
        auto* b=reinterpret_cast<const uint8_t*>(m.factor.data());out.insert(out.end(),b,b+sizeof(m.factor));
    }
    return out;
}
