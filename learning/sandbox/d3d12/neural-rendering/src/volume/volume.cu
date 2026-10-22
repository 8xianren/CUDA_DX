#include "volume_math.cuh"
#include <math_constants.h>
#include <algorithm>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>

namespace neural::volume {
namespace {
void Check(cudaError_t e,const char* what) {
    if(e!=cudaSuccess) throw std::runtime_error(std::string(what)+": "+cudaGetErrorString(e));
}
// 一个线程一个像素，没有共享写入/块同步；16x8 block 的x方向相邻线程写相邻float4。
// 3D纹理的内部排布由CUDA array管理，不把它误当可寻址的线性float*。
__global__ void VolumeRayMarch(cudaTextureObject_t tex,const unsigned char* occupancy,int bricks,
    float4* output,Camera camera,RenderOptions o,float* depth,const float* meshDistance,PixelStats* stats) {
    const int x=blockIdx.x*blockDim.x+threadIdx.x, y=blockIdx.y*blockDim.y+threadIdx.y;
    if(x>=o.width || y>=o.height) return;
    const unsigned index=y*o.width+x;
    const float3 dir=detail::Direction(camera,o,x,y);
    float begin,end,T=1,representativeDepth=CUDART_INF_F; float3 C{}; PixelStats s{};
    if(detail::Box(camera.origin,dir,begin,end)) {
        if(meshDistance) end=fminf(end,fmaxf(0,meshDistance[index]));
        s.hit=end>begin;
        unsigned k=0;
        const float fraction=o.jitter?detail::Jitter(index,o.seed):.5f;
        while(begin+k*o.step<end) {
            const float t=begin+k*o.step, dt=fminf(o.step,end-t), sampleT=t+fraction*dt;
            const float3 p=detail::Add(camera.origin,detail::Mul(dir,sampleT));
            if(o.skipEmpty) {
                int cell[3]={min(bricks-1,max(0,int((p.x+1)*.5f*bricks))),min(bricks-1,max(0,int((p.y+1)*.5f*bricks))),min(bricks-1,max(0,int((p.z+1)*.5f*bricks)))};
                if(occupancy[(cell[2]*bricks+cell[1])*bricks+cell[0]]==0) {
                    // occupancy 含一体素插值halo：空cell内每个三线性采样严格为零。
                    // 找到沿射线离开cell的最近边界，然后跳到原采样格上的下一点；
                    // 不重置采样相位，所以skip和no-skip的非零样本一致。
                    const float pp[3]={p.x,p.y,p.z}, dd[3]={dir.x,dir.y,dir.z};
                    float distance=CUDART_INF_F;
                    for(int a=0;a<3;++a) if(fabsf(dd[a])>1e-10f) {
                        float boundary=-1+2.0f*(cell[a]+(dd[a]>0?1:0))/bricks;
                        distance=fminf(distance,fmaxf(0,(boundary-pp[a])/dd[a]));
                    }
                    const float nextSample=sampleT+distance;
                    const unsigned next=max(k+1,unsigned(fmaxf(0,ceilf((nextSample-begin)/o.step-fraction))));
                    // 统计跳过的真实区间数量，最后不足一步的区间也算一个。
                    const unsigned maxSteps=unsigned(ceilf((end-begin)/o.step));
                    s.skipped+=min(next,maxSteps)-k; k=next; continue;
                }
            }
            const float sigma=tex3D<float>(tex,(p.x+1)*.5f,(p.y+1)*.5f,(p.z+1)*.5f);
            detail::Accumulate(sigma,dt,detail::Color(p),T,C);
            ++s.samples; ++k;
            if(!isfinite(representativeDepth) && 1-T>=.5f) representativeDepth=sampleT;
            if(T<o.termination) {s.terminated=1;break;}
        }
    }
    output[index]={C.x,C.y,C.z,1-T};
    if(depth) depth[index]=representativeDepth;
    if(stats) stats[index]=s;
}
} // namespace

struct Volume::Impl {
    cudaArray_t array=nullptr;
    cudaTextureObject_t texture=0;
    unsigned char* occupancy=nullptr;
    int resolution=0,bricks=0;
    ~Impl() {
        // 调用者须先等待最后一次Render；销毁先texture后array，避免悬空视图。
        if(texture) cudaDestroyTextureObject(texture);
        if(array) cudaFreeArray(array);
        if(occupancy) cudaFree(occupancy);
    }
};
Volume::Volume(const Field& f) {
    const int n=f.resolution;
    if(n<8 || n>1024 || f.density.size()!=size_t(n)*n*n) throw std::invalid_argument("invalid volume dimensions/layout");
    for(float v:f.density) if(!std::isfinite(v) || v<0) throw std::invalid_argument("density must be finite and nonnegative");
    auto p=std::make_unique<Impl>(); p->resolution=n; p->bricks=(n+7)/8;
    const cudaChannelFormatDesc desc=cudaCreateChannelDesc<float>();
    // extent的width在CUDA array分配/复制时以元素计数；宿主pitch才是字节。
    const cudaExtent extent=make_cudaExtent(n,n,n);
    Check(cudaMalloc3DArray(&p->array,&desc,extent),"cudaMalloc3DArray");
    cudaMemcpy3DParms copy{};
    copy.srcPtr=make_cudaPitchedPtr(const_cast<float*>(f.density.data()),n*sizeof(float),n*sizeof(float),n);
    copy.dstArray=p->array; copy.extent=extent; copy.kind=cudaMemcpyHostToDevice;
    Check(cudaMemcpy3D(&copy),"cudaMemcpy3D density");
    cudaResourceDesc resource{}; resource.resType=cudaResourceTypeArray; resource.res.array.array=p->array;
    cudaTextureDesc sampler{}; sampler.normalizedCoords=1; sampler.filterMode=cudaFilterModeLinear;
    sampler.readMode=cudaReadModeElementType;
    for(int i=0;i<3;++i) sampler.addressMode[i]=cudaAddressModeClamp;
    Check(cudaCreateTextureObject(&p->texture,&resource,&sampler,nullptr),"cudaCreateTextureObject");
    const int b=p->bricks;
    std::vector<unsigned char> grid(size_t(b)*b*b,0);
    for(int bz=0;bz<b;++bz) for(int by=0;by<b;++by) for(int bx=0;bx<b;++bx) {
        // cell边界按等分世界盒建立，分辨率不必能被8整除；一体素halo覆盖线性插值的8邻点。
        int low[3]={int(floor(double(bx)*n/b)) -1,int(floor(double(by)*n/b))-1,int(floor(double(bz)*n/b))-1};
        int high[3]={int(ceil(double(bx+1)*n/b)),int(ceil(double(by+1)*n/b)),int(ceil(double(bz+1)*n/b))};
        bool active=false;
        for(int z=std::max(0,low[2]);z<=std::min(n-1,high[2])&&!active;++z)
        for(int y=std::max(0,low[1]);y<=std::min(n-1,high[1])&&!active;++y)
        for(int x=std::max(0,low[0]);x<=std::min(n-1,high[0]);++x)
            if(f.density[(size_t(z)*n+y)*n+x]>0) {active=true;break;}
        grid[(bz*b+by)*b+bx]=active?1:0;
    }
    Check(cudaMalloc(&p->occupancy,grid.size()),"cudaMalloc occupancy");
    Check(cudaMemcpy(p->occupancy,grid.data(),grid.size(),cudaMemcpyHostToDevice),"cudaMemcpy occupancy");
    impl_=p.release();
}
Volume::~Volume() {delete impl_;}
void Volume::Render(float4* output,const Camera& camera,const RenderOptions& o,cudaStream_t stream,
                    float* depth,const float* mesh,PixelStats* stats) const {
    if(!output || o.width<=0 || o.height<=0 || !(o.step>0) || !std::isfinite(o.step)
        || o.termination<0 || o.termination>=1) throw std::invalid_argument("invalid render arguments");
    // 不在库层执行DeviceSynchronize，保留同stream下ExternalFence/后续copy的顺序关系。
    VolumeRayMarch<<<dim3((o.width+15)/16,(o.height+7)/8),dim3(16,8),0,stream>>>(
        impl_->texture,impl_->occupancy,impl_->bricks,output,camera,o,depth,mesh,stats);
    Check(cudaGetLastError(),"VolumeRayMarch launch");
}
std::uint64_t Volume::StorageBytes() const {
    // 这是有效载荷下界；CUDA array实际分配可能含实现相关对齐，不冒充进程显存峰值。
    return std::uint64_t(impl_->resolution)*impl_->resolution*impl_->resolution*sizeof(float)
        +std::uint64_t(impl_->bricks)*impl_->bricks*impl_->bricks;
}
} // namespace neural::volume
