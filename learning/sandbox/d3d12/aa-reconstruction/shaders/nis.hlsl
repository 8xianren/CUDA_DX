// F.6：实际调用锁定的 NVIDIA Image Scaling SDK，而非用普通锐化冒充 NIS。
// 下载与 SHA-256 校验：../fetch_nis.py；原文件自带 MIT 许可，不修改原算法。
// 输入输出为线性 HDR，host 的 NVScalerUpdateConfig 必须同样使用 NISHDRMode::Linear。
// t0 HDR 输入；t1/t2 官方 coef_scale/coef_usm，2×64 RGBA32F；u0 输出；s0 linear clamp。
// b0 为官方 NISConfig 前 112 字节 = 28 DWORD（或 256 字节对齐 CBV），不是 PostConstants。
// 每组 128 线程计算 32×24 个输出像素：Dispatch(ceil(W/32),ceil(H/24),1)。
#define NIS_SCALER 1
#define NIS_HDR_MODE 1
#define NIS_BLOCK_WIDTH 32
#define NIS_BLOCK_HEIGHT 24
#define NIS_THREAD_GROUP_SIZE 128
#define NIS_USE_HALF_PRECISION 0
#define NIS_VIEWPORT_SUPPORT 1
#include "../external/nis/NIS/NIS_Main.hlsl"
