// 该文件在RayRecord与output声明之后包含。每像素只有一个RayGen写者，故不需要原子加。
// 同一队列相邻Dispatch之间由宿主UAV barrier保证历史写后读，shader内不能替代此同步。
RWStructuredBuffer<float4> history : register(u1); // xyz=线性平均，w=样本数（本课上限2048，可精确表示）。
void store_progressive(uint index,inout RayRecord result){
    if(result.stamp.w==0xffffffffu){
        history[index]=0;output[index]=result;return; // 视口外既清输出，也清历史。
    }
    uint count=sampleControls.x+1u;
#if ENABLE_HISTORY
    // RNG序号x可以持续增长；历史失效时只把宿主传入的旧样本数w置0。
    count=sampleControls.w+1u;
#endif
    float3 mean;
    // 第一个样本直接赋值，不读未初始化的Default Heap，也不依赖旧实验的历史内容。
    if(count==1u)mean=result.directLight.xyz;
    else mean=history[index].xyz+(result.directLight.xyz-history[index].xyz)/float(count);
    history[index]=float4(mean,float(count));
    result.meanCount=history[index];
    output[index]=result; // 另存本帧原始样本，CPU才能独立用double求和检查累计平均。
}
