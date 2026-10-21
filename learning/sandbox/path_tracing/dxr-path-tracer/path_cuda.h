#pragma once
#include <cuda_runtime.h>
// 返回启动阶段错误；异步执行错误由调用者在整个交接结束后检查。
// copy=true为透传参考模块；false只验收外部降噪器已经写入的output。
cudaError_t AuditPacket(float4* packet,unsigned pixels,unsigned count,unsigned generation,
    unsigned stamp,bool copy,cudaStream_t stream);
