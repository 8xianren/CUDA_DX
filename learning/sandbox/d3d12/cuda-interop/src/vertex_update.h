#pragma once
#include <cuda_runtime.h>
#include <cstdint>

// E.2不把所有glTF资产共享：仅mesh0的动态副本。buffer首尾各64B哨兵不属于VB。
// 顶点每48B：position[3]偏移0，normal偏移12，uv偏移24，color偏移32。
constexpr unsigned VertexStride=48,VertexGuard=64;
cudaError_t UpdateVertices(void* allocation,const void* base,unsigned count,unsigned frame,cudaStream_t stream);
