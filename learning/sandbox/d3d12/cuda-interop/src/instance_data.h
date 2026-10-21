#pragma once
#include <cuda_runtime.h>
#include <cstddef>

// E.1 的跨 API 二进制契约：每实例 80B；矩阵按行保存，作用于列向量。
// 不使用 CUDA float3/引擎矩阵隐式布局；HLSL 显式 row_major，color 偏移64B。
// color.w 暂作精确帧号审计，RGB 是实际显示颜色。本课没有透明混合。
struct SharedInstance { float world[16]; float color[4]; };
static_assert(sizeof(SharedInstance)==80 && offsetof(SharedInstance,color)==64);
cudaError_t UpdateInstances(SharedInstance* output,const SharedInstance* base,
                           unsigned count,unsigned frame,cudaStream_t stream);
