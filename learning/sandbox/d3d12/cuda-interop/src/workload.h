#pragma once
#include <cuda_runtime.h>
// 可控独立标量更新，用于改变生产者工作量。输出保存且批次后核对，禁止空转计时。
cudaError_t SimulationWork(float* output,unsigned count,unsigned steps,unsigned frame,cudaStream_t stream);
