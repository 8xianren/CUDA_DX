#include "shared_texture.h"
#include <stdexcept>

namespace neural {
SharedTexture::SharedTexture(UploadContext& c,UINT w,UINT h,bool rgba):pixelBytes(rgba?16:4){
    if(!w||!h||w>8192||h>8192)throw std::runtime_error("invalid shared texture extent");
    texture.width=w;texture.height=h;
    texture.format=rgba?DXGI_FORMAT_R32G32B32A32_FLOAT:DXGI_FORMAT_R32_FLOAT;
    D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    d.Width=w;d.Height=h;d.DepthOrArraySize=d.MipLevels=d.SampleDesc.Count=1;
    d.Format=texture.format;d.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    D3D12_HEAP_PROPERTIES hp{};hp.Type=D3D12_HEAP_TYPE_DEFAULT;hp.CreationNodeMask=hp.VisibleNodeMask=1;
    allocationBytes=c.device->GetResourceAllocationInfo(0,1,&d).SizeInBytes;
    D3D12_CLEAR_VALUE clear{};clear.Format=d.Format;
    if(rgba)clear.Color[3]=1;else clear.Color[0]=10;
    Check(c.device->CreateCommittedResource(&hp,D3D12_HEAP_FLAG_SHARED,&d,
          D3D12_RESOURCE_STATE_COMMON,&clear,IID_PPV_ARGS(&texture.resource)),"G shared texture");
    HANDLE handle=nullptr;
    Check(c.device->CreateSharedHandle(texture.resource.Get(),nullptr,GENERIC_ALL,nullptr,&handle),"G texture HANDLE");
    cudaExternalMemoryHandleDesc e{};e.type=cudaExternalMemoryHandleTypeD3D12Resource;
    e.handle.win32.handle=handle;e.size=allocationBytes;e.flags=cudaExternalMemoryDedicated;
    auto imported=cudaImportExternalMemory(&memory,&e);
    // CUDA 的 Win32 HANDLE 导入不接管原 HANDLE。成功与失败路径都需要 CloseHandle。
    CloseHandle(handle);CudaCheck(imported,"G import texture");
    try {
        cudaExternalMemoryMipmappedArrayDesc a{};
        a.formatDesc=rgba?cudaCreateChannelDesc<float4>():cudaCreateChannelDesc<float>();
        a.extent=make_cudaExtent(w,h,0);a.numLevels=1;
        // 底层资源有 ALLOW_RENDER_TARGET，因此映射声明 ColorAttachment。
        // CUDA 用 array copy 写，不必创建 surface object，格式/尺寸仍必须逐项匹配。
        a.flags=cudaArrayColorAttachment;
        CudaCheck(cudaExternalMemoryGetMappedMipmappedArray(&mip,memory,&a),"G map texture array");
        CudaCheck(cudaGetMipmappedArrayLevel(&array,mip,0),"G get mip zero");
    } catch(...) {
        if(mip)cudaFreeMipmappedArray(mip);
        cudaDestroyExternalMemory(memory);throw;
    }
}
SharedTexture::~SharedTexture(){if(mip)cudaFreeMipmappedArray(mip);if(memory)cudaDestroyExternalMemory(memory);}
void SharedTexture::CopyFrom(const void* source,cudaStream_t stream){
    // 宽度/源 pitch 单位为字节；高度单位为行。array 内部平铺由驱动处理。
    // 调用前必须已在同一 stream WaitCuda(ready)，调用后 SignalCuda(done)。
    auto pitch=texture.width*pixelBytes;
    CudaCheck(cudaMemcpy2DToArrayAsync(array,0,0,source,pitch,pitch,texture.height,cudaMemcpyDeviceToDevice,stream),"G copy to array");
}
void SharedTexture::CopyTo(void* destination,cudaStream_t stream){
    auto pitch=texture.width*pixelBytes;
    CudaCheck(cudaMemcpy2DFromArrayAsync(destination,pitch,array,0,0,pitch,texture.height,cudaMemcpyDeviceToDevice,stream),"G copy from array");
}
}
