#pragma once
#include <cstdint>
#include <cstddef>
// t6 ByteAddressBuffer的128字节头；后面紧接lightCount个64字节三角形灯记录。
// 明确按float4/uint4边界组织，HLSL用byte offset读取，不能直接套cbuffer的另一套packing规则。
struct PathConfig {
    uint32_t width=384,height=192,spp=64,seed=0;
    // flags bit0=RR，bit1=按全部主样本累积降噪特征（不改变光传输算法）。
    uint32_t maxScatters=8,mode=1,rrStart=4,flags=1;
    float eye[3]{0,3.8f,15},tanHalfFovY=.31529879f;
    float forward[3]{},environmentIntensity=.03f;
    float right[3]{},offset=.0001f;
    float up[3]{},lightScale=12;
    // sampleOffset是全局样本起点；分批大小改变不应改变同一编号的随机样本。
    // 旧PT.8调用保持0，仍沿用其逐批换seed的行为。PT.10固定seed并连续推进此偏移。
    uint32_t lightCount=0;float totalArea=0;uint32_t sampleOffset=0,pad1=0;
    float environment[3]{.6f,.75f,1};float pad2=0;
};
struct PathLight {float a[4],b[4],c[4];float area,cdf;uint32_t instance,primitive;};
// radiance.rgb是线性样本均值，w是亮度平方均值；不是颜色平方，也不是空间方差。
// albedo/normal/position只记录首批第一个主样本，w分别是roughness、材质ID+1、实例ID+1。
// flags bit1开启时：albedo.rgb/normal.xyz改为所有主样本的特征均值，albedo.w为命中覆盖率，
// normal.w为(viewDepth*hit)的均值；position仍是首样本诊断，不把平均位置当成真实表面。
// events={全部射线,阴影射线,散射次数,null次数}；errors={非法状态,非有限值,delta次数,透射次数}。
// ends={RR终止,深度截断,单面背面终止,命中发光次数}。每像素自有计数，无跨线程原子竞争。
struct PathPixel {float radiance[4],albedo[4],normal[4],position[4];uint32_t events[4],errors[4],ends[4];};
static_assert(sizeof(PathConfig)==128&&offsetof(PathConfig,lightCount)==96);
static_assert(sizeof(PathLight)==64&&sizeof(PathPixel)==112);
