#include <cuda_runtime.h>
#include <stdexcept>
namespace neural {
__global__ void DepthToRayKernel(const float* z,float* ray,int width,int height){
    int x=blockIdx.x*blockDim.x+threadIdx.x,y=blockIdx.y*blockDim.y+threadIdx.y;
    if(x>=width||y>=height)return;
    // 归一化相机射线d=(sx,sy,1)/length，viewZ=t*d.z，所以t=z/d.z。
    // 同一个世界几何深度不能把Z值原封不动传给ray marcher，否则边缘会提前截断。
    float tanHalf=.46630765815f;
    float sx=(2*(x+.5f)/width-1)*(float(width)/height)*tanHalf;
    float sy=(1-2*(y+.5f)/height)*tanHalf;
    int i=y*width+x;ray[i]=z[i]*sqrtf(sx*sx+sy*sy+1);
}
void MeshDepthToRay(const float* z,float* ray,int width,int height,cudaStream_t s){
    DepthToRayKernel<<<dim3((width+15)/16,(height+15)/16),dim3(16,16),0,s>>>(z,ray,width,height);
    auto error=cudaGetLastError();if(error!=cudaSuccess)throw std::runtime_error(cudaGetErrorString(error));
}
__device__ float Decode(float value){return value<=.04045f?value/12.92f:powf((value+.055f)/1.055f,2.4f);}
__global__ void DecodeKernel(float4* color,int n){
    int i=blockIdx.x*blockDim.x+threadIdx.x;if(i>=n)return;
    float4 p=color[i];
    // 非线性解码必须先解除预乘，随后重新乘alpha，避免把低alpha误当成暗材质。
    if(p.w>1e-8f){p.x=Decode(p.x/p.w)*p.w;p.y=Decode(p.y/p.w)*p.w;p.z=Decode(p.z/p.w)*p.w;}
    color[i]=p;
}
void DecodeAppearance(float4* color,int count,cudaStream_t stream){
    DecodeKernel<<<(count+255)/256,256,0,stream>>>(color,count);
    auto error=cudaGetLastError();if(error!=cudaSuccess)throw std::runtime_error(cudaGetErrorString(error));
}
__global__ void RayToZKernel(float* depth,int width,int height){
    int x=blockIdx.x*blockDim.x+threadIdx.x,y=blockIdx.y*blockDim.y+threadIdx.y;
    if(x>=width||y>=height)return;
    float sx=(2*(x+.5f)/width-1)*(float(width)/height)*.46630765815f;
    float sy=(1-2*(y+.5f)/height)*.46630765815f;
    depth[y*width+x]/=sqrtf(sx*sx+sy*sy+1);
}
void RayDepthToCameraZ(float* depth,int width,int height,cudaStream_t stream){
    // 与GS/NeRF统一单位为camera-Z；统计意义仍是体的alpha中值，不是硬表面。
    RayToZKernel<<<dim3((width+15)/16,(height+15)/16),dim3(16,16),0,stream>>>(depth,width,height);
    auto error=cudaGetLastError();if(error!=cudaSuccess)throw std::runtime_error(cudaGetErrorString(error));
}
}
