#pragma once
#include "gpu_upload.h"
// 仅在初始化或最终GPU排空之后使用：取静态VB/IB/全部材质图像的真实GPU字节。
// 纹理剔除RowPitch padding，避免把未定义的拷贝填充区当成内容差异。
std::vector<uint8_t> SnapshotStatic(UploadContext& c,const GpuScene& gpu);
