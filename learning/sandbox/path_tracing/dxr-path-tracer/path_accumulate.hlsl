#include "path_pixel.hlsli"
StructuredBuffer<Pixel> batch : register(t0);
RWStructuredBuffer<HistoryPixel> history : register(u0);
// root constants共6个uint；它们是命令流快照，不需要每批再创建cbuffer。
cbuffer Accumulation : register(b0) {
    uint width,height,batchCount,previousCount,generation,flags;
};
[numthreads(8,8,1)]
void Accumulate(uint3 id : SV_DispatchThreadID) {
    // 测试包含95×49这种不能整除线程组的尺寸，边缘线程必须先退出。
    if(id.x>=width||id.y>=height)return;
    uint index=id.y*width+id.x;
    Pixel current=batch[index];HistoryPixel next;
    if(previousCount==0){
        // 重置必须完全不读旧历史：新资源内容未初始化；旧资源也可能含NaN或另一相机的值。
        // “old*0+new”仍会传播NaN，因此采用真正的控制流分支。
        next.value=current;next.meta=uint4(batchCount,generation,flags&2,0);
    }else{
        next=history[index];
        // 每像素计数/代号与CPU计划必须一致。失败写入既有非法状态计数，由验收拒绝。
        if(next.meta.x!=previousCount||next.meta.y!=generation||next.meta.z!=(flags&2))next.value.errors.x++;
        float weight=float(batchCount)/float(previousCount+batchCount);
        next.value.radiance=next.value.radiance+(current.radiance-next.value.radiance)*weight;
        if(flags&2){
            // 同样本数权重累积albedo、单位法线均值、coverage与深度矩；不是平均实例ID。
            next.value.albedo+=(current.albedo-next.value.albedo)*weight;
            next.value.normal+=(current.normal-next.value.normal)*weight;
        }
        next.value.events+=current.events;next.value.errors+=current.errors;next.value.ends+=current.ends;
        // 非guides模式仍保留首主样本诊断；guides均值是滤波特征，不声称代表某个真实表面。
        next.meta.x=previousCount+batchCount;
    }
    history[index]=next; // 一像素一个线程，无跨像素读写，无需原子操作。
}
