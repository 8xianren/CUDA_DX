#include "skin_gpu.h"
#include <stdexcept>
#include <string>
namespace character {
void CheckCuda(cudaError_t e,const char* where){if(e!=cudaSuccess)throw std::runtime_error(std::string(where)+": "+cudaGetErrorString(e));}
// 一个线程处理一个顶点：只读取绑定网格和骨骼palette，不从上一帧变形结果继续变形。
// 否则误差和变换会逐帧累积；UV和颜色完整复制，只有位置/法线更新。
__global__ void SkinKernel(const Vertex* bind,const GpuInfluence* influences,const SkinMatrix* matrices,Vertex* out,unsigned count){
    unsigned i=blockIdx.x*blockDim.x+threadIdx.x;if(i>=count)return;
    Vertex v=bind[i];float p[3]{},n[3]{};
    for(unsigned k=0;k<4;++k){float w=influences[i].weight[k];if(w==0)continue;
        const auto& m=matrices[influences[i].joint[k]];
        for(unsigned r=0;r<3;++r){p[r]+=w*(m.position[r*4]*v.position[0]+m.position[r*4+1]*v.position[1]+m.position[r*4+2]*v.position[2]+m.position[r*4+3]);
            n[r]+=w*(m.normal[r*4]*v.normal[0]+m.normal[r*4+1]*v.normal[1]+m.normal[r*4+2]*v.normal[2]);}
    }
    float inv=rsqrtf(n[0]*n[0]+n[1]*n[1]+n[2]*n[2]);
    for(unsigned r=0;r<3;++r){v.position[r]=p[r];v.normal[r]=n[r]*inv;}out[i]=v;
}
SkinDevice::SkinDevice(const Vertex* v,const GpuInfluence* w,unsigned n,unsigned j):vertices(n),joints(j){
    if(!v||!w||!n||!j)throw std::runtime_error("empty skin buffer");
    for(unsigned i=0;i<n;++i)for(unsigned k=0;k<4;++k)if(w[i].weight[k]!=0&&w[i].joint[k]>=j)throw std::runtime_error("skin joint out of bounds");
    try{
        CheckCuda(cudaMalloc(&bind,n*sizeof(Vertex)),"allocate bind vertices");
        CheckCuda(cudaMalloc(&output,n*sizeof(Vertex)),"allocate skinned vertices");
        CheckCuda(cudaMalloc(&influence,n*sizeof(GpuInfluence)),"allocate influences");
        CheckCuda(cudaMalloc(&matrices,j*sizeof(SkinMatrix)),"allocate palette");
        CheckCuda(cudaMemcpy(bind,v,n*sizeof(Vertex),cudaMemcpyHostToDevice),"upload bind vertices");
        CheckCuda(cudaMemcpy(influence,w,n*sizeof(GpuInfluence),cudaMemcpyHostToDevice),"upload influences");
        // 初始化复制使用默认流；显式完成后才允许后续nonblocking stream读取。
        CheckCuda(cudaDeviceSynchronize(),"finish skin initialization");
    }catch(...){cudaFree(bind);cudaFree(output);cudaFree(influence);cudaFree(matrices);throw;}
}
SkinDevice::~SkinDevice(){cudaFree(bind);cudaFree(output);cudaFree(influence);cudaFree(matrices);}
void SkinDevice::Record(const SkinMatrix* palette,cudaStream_t stream,Vertex* externalOutput){
    CheckCuda(cudaMemcpyAsync(matrices,palette,joints*sizeof(SkinMatrix),cudaMemcpyHostToDevice,stream),"upload skin palette");
    SkinKernel<<<(vertices+127)/128,128,0,stream>>>(bind,influence,matrices,externalOutput?externalOutput:output,vertices);
    CheckCuda(cudaGetLastError(),"launch skin kernel");
}
}
