#include "vertex_update.h"

__global__ void Deform(unsigned char* allocation,const unsigned char* base,unsigned n,unsigned frame){
    unsigned i=blockIdx.x*blockDim.x+threadIdx.x;if(i>=n)return;
    // 字节寻址先乘stride，再解释为position；不能把48B AoS错当连续float3数组。
    const float* p=reinterpret_cast<const float*>(base+i*VertexStride);
    float* q=reinterpret_cast<float*>(allocation+VertexGuard+i*VertexStride);
    float a=float(int(frame%9)-4)*0.0625f;
    // 从静止位置计算平面形变(x+a*y, y+a*x², z)。当前网格z=0，保持平面法线方向。
    // 仅写前三个float，其余36B沿用初始化内容；真实非平面蒙皮须更新normal/tangent。
    q[0]=p[0]+a*p[1];q[1]=p[1]+a*p[0]*p[0];q[2]=p[2];
}
cudaError_t UpdateVertices(void* allocation,const void* base,unsigned count,unsigned frame,cudaStream_t stream){
    if(!allocation||!base||!count)return cudaErrorInvalidValue;
    Deform<<<(count+127)/128,128,0,stream>>>(static_cast<unsigned char*>(allocation),static_cast<const unsigned char*>(base),count,frame);
    return cudaGetLastError();
}
