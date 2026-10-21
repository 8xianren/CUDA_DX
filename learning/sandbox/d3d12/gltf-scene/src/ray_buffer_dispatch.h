#pragma once
#include "gpu_instances.h"
// PT.6/PT.7共用同步调度：t0 TLAS，t1对象表，t2只读配置，u0输出buffer。
// shader约定RayGen/Miss/ClosestHit、16B payload、嵌套深度1。输出布局由课程调用者保证。
// data由本函数复制到UPLOAD，返回前等Fence；frame及其BLAS必须由调用者保持存活。
std::vector<uint8_t> DispatchRayBuffer(UploadContext&,const InstanceFrame&,
    const void* data,size_t configBytes,UINT width,UINT height,size_t outputBytes,const std::filesystem::path& dxil);
