#ifndef PATH_PIXEL_HLSLI
#define PATH_PIXEL_HLSLI
// 与PathPixel的112字节步长一致；radiance.w为亮度平方均值，不是alpha。
// 后续累积只合并radiance和计数；albedo/normal/position保留本代第一个主样本。
struct Pixel {float4 radiance,albedo,normal,position;uint4 events,errors,ends;};
// 每像素额外16字节：样本数、历史代号、两个保留字段。uint计数不被float舍入。
struct HistoryPixel {Pixel value;uint4 meta;};
#endif
