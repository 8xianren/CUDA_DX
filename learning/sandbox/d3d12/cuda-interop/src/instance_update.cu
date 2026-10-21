#include "instance_data.h"

// 每线程独占一个实例，读取只上传一次的基准，禁止逐帧 += 造成累计漂移。
// 世界平移 T(d)*M：仿射 M 的最后一行为(0,0,0,1)，因此只改第3/7元素。
// 用可精确表示的二进制步长让同步错误与三角函数舍入误差分开。
__global__ void Update(SharedInstance* out,const SharedInstance* base,unsigned n,unsigned frame) {
    unsigned i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i>=n)return;
    SharedInstance v=base[i];
    float phase=float(int(frame%9)-4)*0.125f;
    v.world[3]+=phase*((i&1)?-1.f:1.f);
    v.world[7]+=float(int((frame+i)%5)-2)*0.0625f;
    v.color[0]=float(i+1)/8.f;
    v.color[1]=float(frame%8+1)/8.f;
    v.color[2]=float(8-i)/8.f;
    v.color[3]=float(frame+1);
    out[i]=v;
}
cudaError_t UpdateInstances(SharedInstance* out,const SharedInstance* base,unsigned n,unsigned f,cudaStream_t s) {
    if(!out||!base||!n)return cudaErrorInvalidValue;
    Update<<<(n+127)/128,128,0,s>>>(out,base,n,f);
    // 这里只检查launch错误；异步执行错误在最后的stream同步处检查。
    return cudaGetLastError();
}
