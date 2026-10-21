// 有限历史的教学时域滤波，有偏，不冒充额外独立路径样本。
struct Guide {float4 position,normal,previousPixel,previousNormal;};
ByteAddressBuffer raw:register(t0);
StructuredBuffer<Guide> currentGuide:register(t1);
StructuredBuffer<Guide> previousGuide:register(t2);
StructuredBuffer<float4> previousColor:register(t3);
RWStructuredBuffer<float4> filtered:register(u0);
cbuffer Controls:register(b0){uint width,height,resetHistory,maxHistory;float4 previousEye,previousForward;};
[numthreads(8,8,1)]
void Filter(uint3 tid:SV_DispatchThreadID){
    if(tid.x>=width||tid.y>=height)return;uint index=tid.y*width+tid.x;
    float3 color=asfloat(raw.Load3(128*index));Guide guide=currentGuide[index];float count=1;
    if(resetHistory==0&&guide.position.w>0&&guide.previousPixel.w>0&&guide.previousNormal.w>0){
        uint2 xy=uint2(guide.previousPixel.xy);uint oldIndex=xy.y*width+xy.x;Guide old=previousGuide[oldIndex];
        float oldDepth=dot(old.position.xyz-previousEye.xyz,previousForward.xyz);
        bool valid=old.position.w==guide.position.w&&old.normal.w==guide.normal.w;
        valid=valid&&abs(oldDepth-guide.previousPixel.z)<max(.02,.01*guide.previousPixel.z)&&dot(old.normal.xyz,guide.previousNormal.xyz)>.9;
        if(valid){
            float4 history=previousColor[oldIndex];
            // 3x3当前颜色包围盒限制旧阴影拖尾；它引入偏差，不能作为物理正确性证明。
            float3 low=color,high=color;
            for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){int2 p=clamp(int2(tid.xy)+int2(x,y),int2(0,0),int2(width-1,height-1));float3 c=asfloat(raw.Load3(128*(p.y*width+p.x)));low=min(low,c);high=max(high,c);}
            count=min(history.w+1,float(maxHistory));color=lerp(clamp(history.rgb,low,high),color,1/count);
        }
    }
    filtered[index]=float4(color,count);
}
