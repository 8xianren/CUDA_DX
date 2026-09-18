#include <cstdio>
#include <cuda_runtime.h>

#define CK(x) do{ cudaError_t e=(x); if(e){printf("err %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(e));return 1;} }while(0)

// 用纹理对象在“非整数坐标”采样:硬件自动双线性插值
__global__ void sampleLinear(cudaTextureObject_t tex, float* out, const float2* coords, int m) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < m) out[i] = tex2D<float>(tex, coords[i].x, coords[i].y);  // 一条指令:寻址+插值+缓存
}

// 手写双线性插值(在普通 global memory 上),用来对照硬件结果
__global__ void sampleManual(const float* img, int W, int H, float* out, const float2* coords, int m) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= m) return;
    // 纹理坐标约定:采样点 (x,y) 对应纹素中心在 (col+0.5, row+0.5)
    float x = coords[i].x - 0.5f, y = coords[i].y - 0.5f;
    int x0 = (int)floorf(x), y0 = (int)floorf(y);
    float fx = x - x0, fy = y - y0;
    auto at = [&](int c, int r){ c = max(0, min(W-1, c)); r = max(0, min(H-1, r)); return img[r*W+c]; }; // clamp
    float v00 = at(x0,y0), v10 = at(x0+1,y0), v01 = at(x0,y0+1), v11 = at(x0+1,y0+1);
    out[i] = (1-fx)*(1-fy)*v00 + fx*(1-fy)*v10 + (1-fx)*fy*v01 + fx*fy*v11;
}

int main() {
    const int W = 4, H = 4;
    float h_img[H*W] = {
         0, 10, 20, 30,
        40, 50, 60, 70,
        80, 90,100,110,
       120,130,140,150 };

    // 1) 建 cudaArray(纹理专用的、按 2D 空间局部性排布的存储)并拷入
    cudaChannelFormatDesc ch = cudaCreateChannelDesc<float>();
    cudaArray_t arr;
    CK(cudaMallocArray(&arr, &ch, W, H));
    CK(cudaMemcpy2DToArray(arr, 0, 0, h_img, W*sizeof(float), W*sizeof(float), H, cudaMemcpyHostToDevice));

    // 2) 资源描述 + 纹理描述(过滤模式/寻址模式/坐标归一化)
    cudaResourceDesc resd{}; resd.resType = cudaResourceTypeArray; resd.res.array.array = arr;
    cudaTextureDesc texd{};
    texd.addressMode[0] = cudaAddressModeClamp;   // 越界 x:钳到边缘
    texd.addressMode[1] = cudaAddressModeClamp;   // 越界 y:钳到边缘
    texd.filterMode     = cudaFilterModeLinear;   // 硬件双线性插值
    texd.normalizedCoords = 0;                    // 用像素坐标(非 0~1)
    texd.readMode = cudaReadModeElementType;
    cudaTextureObject_t tex = 0;
    CK(cudaCreateTextureObject(&tex, &resd, &texd, nullptr));

    // 3) 采样点:整数中心 + 两纹素正中间 + 越界
    float2 h_c[] = { {0.5f,0.5f}, {1.5f,0.5f}, {1.0f,0.5f}, {1.5f,1.5f}, {-2.0f,0.5f} };
    const int M = sizeof(h_c)/sizeof(h_c[0]);
    float2* d_c; CK(cudaMalloc(&d_c, sizeof(h_c))); CK(cudaMemcpy(d_c, h_c, sizeof(h_c), cudaMemcpyHostToDevice));
    float* d_img; CK(cudaMalloc(&d_img, sizeof(h_img))); CK(cudaMemcpy(d_img, h_img, sizeof(h_img), cudaMemcpyHostToDevice));
    float *d_o1, *d_o2; CK(cudaMalloc(&d_o1, M*sizeof(float))); CK(cudaMalloc(&d_o2, M*sizeof(float)));

    sampleLinear<<<1, M>>>(tex, d_o1, d_c, M);
    sampleManual<<<1, M>>>(d_img, W, H, d_o2, d_c, M);
    CK(cudaDeviceSynchronize());

    float o1[M], o2[M];
    CK(cudaMemcpy(o1, d_o1, sizeof(o1), cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(o2, d_o2, sizeof(o2), cudaMemcpyDeviceToHost));

    const char* note[] = {"texel(0,0) center", "texel(1,0) center", "midpoint of (0,0)&(1,0)", "center of 4 texels", "x out-of-range (clamp)"};
    printf("coord(x,y)          HW tex2D   manual     note\n");
    for (int i = 0; i < M; ++i)
        printf("(%5.1f,%4.1f)      %8.2f   %8.2f   %s\n", h_c[i].x, h_c[i].y, o1[i], o2[i], note[i]);

    cudaDestroyTextureObject(tex); cudaFreeArray(arr);
    return 0;
}
