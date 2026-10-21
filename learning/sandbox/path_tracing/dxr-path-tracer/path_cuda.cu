#include "path_cuda.h"
__device__ bool finite3(float4 v){return isfinite(v.x)&&isfinite(v.y)&&isfinite(v.z);}
__global__ void Audit(float4* p,unsigned n,unsigned count,unsigned generation,unsigned stamp,bool copy){
    unsigned i=blockIdx.x*blockDim.x+threadIdx.x;if(i>=n)return;
    // 一线程拥有一个像素，六平面同索引。只写output和audit，不修改原始HDR/特征。
    float4 c=p[i],a=p[n+i],v=p[2*n+i],d=p[3*n+i];
    uint4 meta=reinterpret_cast<uint4*>(p)[5*n+i];unsigned error=meta.z;
    if(meta.x!=count||meta.y!=generation||meta.w!=0)error|=2;
    if(!finite3(c)||c.x<0||c.y<0||c.z<0||c.w!=1)error|=4;
    if(!finite3(a)||a.x<0||a.y<0||a.z<0||a.x>1.00001f||a.y>1.00001f||a.z>1.00001f||!isfinite(a.w)||a.w<0||a.w>1.00001f)error|=8;
    if(!finite3(v)||v.x*v.x+v.y*v.y+v.z*v.z>1.0001f||v.w!=0)error|=16;
    if(!finite3(d)||d.x<0||d.y!=a.w||d.z!=0||d.w!=0)error|=32;
    if(copy)p[4*n+i]=c;
    float4 result=p[4*n+i];if(!finite3(result)||result.x<0||result.y<0||result.z<0||result.w!=1)error|=64;
    // stamp由每次交接生成；CPU读回据此确认访问的是本轮CUDA写回，而非旧缓冲。
    meta.z=error;meta.w=stamp;reinterpret_cast<uint4*>(p)[5*n+i]=meta;
}
cudaError_t AuditPacket(float4* packet,unsigned pixels,unsigned count,unsigned generation,unsigned stamp,bool copy,cudaStream_t stream){
    Audit<<<(pixels+127)/128,128,0,stream>>>(packet,pixels,count,generation,stamp,copy);
    return cudaGetLastError();
}
