#include "path_interop.h"
#include <OpenImageDenoise/oidn.h>
namespace {
class OidnConsumer final : public PathConsumer {
    OIDNDevice device_=nullptr;OIDNBuffer buffer_=nullptr;OIDNFilter filter_=nullptr;
    void Release(){if(filter_)oidnReleaseFilter(filter_);if(buffer_)oidnReleaseBuffer(buffer_);if(device_)oidnReleaseDevice(device_);}
public:
    OidnConsumer(int ordinal,cudaStream_t stream,float4* pointer,UINT width,UINT height,bool guides){
        try{
            // 显式绑定LUID匹配的CUDA ordinal和同一非默认stream；不能用DEFAULT设备让库自行选择CPU。
            device_=oidnNewCUDADevice(&ordinal,&stream,1);CheckCompleted();Require(device_!=nullptr,"OIDN CUDA device missing");
            oidnCommitDevice(device_);CheckCompleted();
            const size_t plane=size_t(width)*height*sizeof(float4);
            buffer_=oidnNewSharedBuffer(device_,pointer,6*plane);CheckCompleted();
            filter_=oidnNewFilter(device_,"RT");CheckCompleted();
            auto bind=[&](const char* name,unsigned index){
                // FLOAT3只读取RGB/XYZ，实际相邻像素仍相隔16B，行跨度width*16，无CPU拷贝。
                oidnSetFilterImage(filter_,name,buffer_,OIDN_FORMAT_FLOAT3,width,height,index*plane,sizeof(float4),size_t(width)*sizeof(float4));};
            bind("color",0);if(guides){bind("albedo",1);bind("normal",2);}bind("output",4);
            oidnSetFilterBool(filter_,"hdr",true);oidnSetFilterBool(filter_,"srgb",false);
            // AA主样本数量有限，轮廓处的guides仍有采样噪声；不能谎称cleanAux=true。
            oidnSetFilterBool(filter_,"cleanAux",false);
            oidnCommitFilter(filter_);CheckCompleted();
        }catch(...){Release();throw;}
    }
    ~OidnConsumer(){Release();} // 必须在Run结束且PathInterop尚存活时析构。
    void Enqueue() override{oidnExecuteFilterAsync(filter_);CheckCompleted();}
    void CheckCompleted() override{const char* message=nullptr;auto error=oidnGetDeviceError(device_,&message);
        if(error!=OIDN_ERROR_NONE)throw std::runtime_error(std::string("OIDN: ")+(message?message:"unspecified error"));}
};
}
std::unique_ptr<PathConsumer> MakeOidnConsumer(int device,cudaStream_t stream,float4* packet,UINT width,UINT height,bool guides){
    return std::make_unique<OidnConsumer>(device,stream,packet,width,height,guides);
}
