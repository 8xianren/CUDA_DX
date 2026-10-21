#include "workload.h"
__global__ void Simulate(float* out,unsigned n,unsigned steps,unsigned frame){
    unsigned i=blockIdx.x*blockDim.x+threadIdx.x;if(i>=n)return;
    float x=float((i+frame)%1024)/1024.f;
    // 每步是固定工作量的可重复递推；使用显式fmaf使CPU参考具有相同舍入契约。
    for(unsigned k=0;k<steps;++k){x=fmaf(x,1.0001f,0.00001f);x=x-floorf(x);}
    out[i]=x;
}
cudaError_t SimulationWork(float* out,unsigned n,unsigned steps,unsigned frame,cudaStream_t stream){
    if(!out||!n)return cudaErrorInvalidValue;
    Simulate<<<(n+127)/128,128,0,stream>>>(out,n,steps,frame);return cudaGetLastError();
}
