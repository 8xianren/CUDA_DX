#include <cuda_runtime.h>
constexpr int TILE = 32;

__global__ void transposeConflict(float* out, const float* in, int w, int h) {
    __shared__ float tile[TILE][TILE];
    int x = blockIdx.x*TILE + threadIdx.x, y = blockIdx.y*TILE + threadIdx.y;
    if (x<w && y<h) tile[threadIdx.y][threadIdx.x] = in[y*w+x];
    __syncthreads();
    int tx = blockIdx.y*TILE + threadIdx.x, ty = blockIdx.x*TILE + threadIdx.y;
    if (tx<h && ty<w) out[ty*h+tx] = tile[threadIdx.x][threadIdx.y];
}
__global__ void transposePadded(float* out, const float* in, int w, int h) {
    __shared__ float tile[TILE][TILE+1];
    int x = blockIdx.x*TILE + threadIdx.x, y = blockIdx.y*TILE + threadIdx.y;
    if (x<w && y<h) tile[threadIdx.y][threadIdx.x] = in[y*w+x];
    __syncthreads();
    int tx = blockIdx.y*TILE + threadIdx.x, ty = blockIdx.x*TILE + threadIdx.y;
    if (tx<h && ty<w) out[ty*h+tx] = tile[threadIdx.x][threadIdx.y];
}

int main() {
    const int W=2048, H=2048; size_t bytes=(size_t)W*H*sizeof(float);
    float *in,*out; cudaMalloc(&in,bytes); cudaMalloc(&out,bytes); cudaMemset(in,0,bytes);
    dim3 block(TILE,TILE), grid(W/TILE,H/TILE);
    transposeConflict<<<grid,block>>>(out,in,W,H);   // 第 1 个 kernel
    transposePadded  <<<grid,block>>>(out,in,W,H);   // 第 2 个 kernel
    cudaDeviceSynchronize();
    cudaFree(in); cudaFree(out);
    return 0;
}
