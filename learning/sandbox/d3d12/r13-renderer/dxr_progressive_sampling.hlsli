// R.13.6：按像素/样本序号/随机种子/维度寻址，无可变的全局RNG状态。
// 宿主root constants b1与uint4严格对应，不改变原View的128B布局。
cbuffer Sampling : register(b1) {
    uint4 sampleControls; // x=RNG样本序号，y=种子，z=测试flags；R.13.7的w=旧历史样本数，.6为0。
};
// flags: 1冻结随机序号（错误对照），2固定像素中心，4解析HDR序列（隔离累积测试）。
uint progressive_hash(uint x){x^=x>>16;x*=0x7feb352du;x^=x>>15;x*=0x846ca68bu;x^=x>>16;return x;}
float progressive_uniform(uint pixel,uint dimension){
    uint s=(sampleControls.z&1u)?0u:sampleControls.x;
    uint x=progressive_hash(pixel^0xa511e9b3u);
    x=progressive_hash(x^progressive_hash(s+0x63d83595u));
    x=progressive_hash(x^progressive_hash(sampleControls.y+0x9e3779b9u));
    x=progressive_hash(x^((dimension+1u)*0x85ebca6bu));
    // 16位中点均匀格：严格在(0,1)内，CPU/GPU可精确复现；不宣称连续IID。
    return (float(x>>16)+.5)/65536.;
}
float2 progressive_pixel_offset(uint pixel){
    return (sampleControls.z&2u)?float2(.5,.5):float2(progressive_uniform(pixel,0),progressive_uniform(pixel,1));
}
