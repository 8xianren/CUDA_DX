// F.3–F.6 共用后处理。每个 8×8 group 的一个线程负责一个输出像素。
// 宿主必须在 dispatch 前把 t* 置于 NON_PIXEL_SHADER_RESOURCE、u* 置于 UAV，
// dispatch 后以 barrier/transition 明确生产者→消费者关系，不能同时读写同一子资源。
cbuffer PostConstants : register(b0) {
    uint2 inputSize, outputSize;
    float2 jitterUV, previousJitterUV;
    float historyWeight, depthRelativeThreshold, fxaaThreshold, fxaaMinThreshold;
    uint flags, frameIndex;
    float sharpenStrength, padding;
};
Texture2D<float4> currentColor : register(t0);
Texture2D<float4> historyColor : register(t1);
// xy: current→previous、UV 单位；z: 当前线性视深度；w: 同一表面的上一帧预期视深度。
// w 不能简单复制 z：相机前后移动时，同一个表面的视深度也会改变。
Texture2D<float4> motionDepth : register(t2);
Texture2D<float4> previousDepth : register(t3); // .r 线性视深度；不是 D3D depth 的非线性 z/w。
Texture2D<float4> reactiveMask : register(t4);  // .r∈[0,1]；1 完全使用当前颜色。
RWTexture2D<float4> outputColor : register(u0);
RWTexture2D<float4> diagnostic : register(u1); // (historyUsed, clampDelta, motionPixels, rejectCode)
SamplerState linearClamp : register(s0);

static const uint HISTORY_VALID=1, REPROJECT=2, REJECT_DEPTH=4, CLAMP_HISTORY=8;
static const uint YCOCG=16, MV_HAS_JITTER=32;
float3 Current(int2 p) { return currentColor.Load(int3(clamp(p,0,int2(inputSize)-1),0)).rgb; }
float3 SampleCurrent(float2 uv) { return currentColor.SampleLevel(linearClamp,uv,0).rgb; }
// 亮度权重是线性 Rec.709。sqrt 仅用来让边缘检测更接近感知对比；颜色仍在线性域滤波。
float Luma(float3 c) { return sqrt(max(0,dot(c,float3(.2126,.7152,.0722)))); }
float3 ToYCoCg(float3 c) { return float3(.25*c.r+.5*c.g+.25*c.b,.5*c.r-.5*c.b,-.25*c.r+.5*c.g-.25*c.b); }
float3 FromYCoCg(float3 c) { return float3(c.x+c.y-c.z,c.x+c.z,c.x-c.y-c.z); }

[numthreads(8,8,1)] void CopyCS(uint3 tid:SV_DispatchThreadID) {
    if(any(tid.xy>=outputSize)) return;
    outputColor[tid.xy]=float4(SampleCurrent((tid.xy+.5)/float2(outputSize)),1);
}

// 教学 FXAA：9 点方向判别→沿边界的双向端点搜索→沿法线亚像素取样。
// 这不是普通 3×3 box blur，也不声称与某一 FXAA 3.11 preset 逐位一致。
[numthreads(8,8,1)] void FxaaCS(uint3 tid:SV_DispatchThreadID) {
    if(any(tid.xy>=outputSize)) return;
    int2 p=int2(tid.xy); float2 texel=1.0/float2(inputSize), uv=(p+.5)*texel;
    float m=Luma(Current(p)),n=Luma(Current(p+int2(0,-1))),s=Luma(Current(p+int2(0,1)));
    float w=Luma(Current(p+int2(-1,0))),e=Luma(Current(p+int2(1,0)));
    float lo=min(m,min(min(n,s),min(w,e))),hi=max(m,max(max(n,s),max(w,e))),range=hi-lo;
    if(range<max(fxaaMinThreshold,hi*fxaaThreshold)) {
        outputColor[p]=float4(Current(p),1); diagnostic[p]=0; return;
    }
    float nw=Luma(Current(p+int2(-1,-1))),ne=Luma(Current(p+int2(1,-1)));
    float sw=Luma(Current(p+int2(-1,1))),se=Luma(Current(p+int2(1,1)));
    // 二阶差分度量法线方向上的亮度变化；平行边界方向不应产生大变化。
    float horizontal=2*abs(n+s-2*m)+abs(nw+sw-2*w)+abs(ne+se-2*e);
    float vertical=2*abs(w+e-2*m)+abs(nw+ne-2*n)+abs(sw+se-2*s);
    bool horizontalEdge=horizontal>=vertical;
    float negative=horizontalEdge?n:w,positive=horizontalEdge?s:e;
    bool chooseNegative=abs(negative-m)>=abs(positive-m);
    float neighbor=chooseNegative?negative:positive;
    float gradient=abs(neighbor-m),edgeLuma=.5*(neighbor+m);
    float2 normal=horizontalEdge?float2(0,texel.y):float2(texel.x,0);
    normal*=chooseNegative?-1:1;
    float2 tangent=horizontalEdge?float2(texel.x,0):float2(0,texel.y);
    float2 origin=uv+.5*normal;
    float dn=0,dp=0,ln=0,lp=0; bool foundN=false,foundP=false;
    // 固定最多 12 次；跨度逐渐增加，但每侧单独停止。实际采样沿 tangent，而不是跨边模糊。
    [loop] for(uint i=0;i<12;++i) {
        float stepLength=i<5?1.0:(i<9?2.0:4.0);
        if(!foundN) { dn+=stepLength; ln=Luma(SampleCurrent(origin-tangent*dn))-edgeLuma; foundN=abs(ln)>=gradient*.25; }
        if(!foundP) { dp+=stepLength; lp=Luma(SampleCurrent(origin+tangent*dp))-edgeLuma; foundP=abs(lp)>=gradient*.25; }
        if(foundN&&foundP) break;
    }
    float edgeOffset=.5-min(dn,dp)/max(dn+dp,1e-6);
    float nearestLuma=dn<dp?ln:lp;
    // 若近端与中心在边缘均值同侧，移动会越过错误一侧，取消几何边缘偏移。
    if((nearestLuma<0)==(m-edgeLuma<0)) edgeOffset=0;
    float average=(2*(n+s+w+e)+nw+ne+sw+se)/12;
    float subpixel=saturate(abs(average-m)/max(range,1e-6));
    subpixel=subpixel*subpixel*(3-2*subpixel); subpixel=subpixel*subpixel*.75;
    float offset=max(edgeOffset,subpixel);
    outputColor[p]=float4(SampleCurrent(uv+normal*offset),1);
    diagnostic[p]=float4(horizontalEdge?1:0,offset,dn+dp,1);
}

[numthreads(8,8,1)] void TaaCS(uint3 tid:SV_DispatchThreadID) {
    if(any(tid.xy>=outputSize)) return;
    int2 p=int2(tid.xy); float2 uv=(p+.5)/float2(inputSize);
    float3 current=Current(p); float4 md=motionDepth.Load(int3(p,0));
    float2 previousUV=uv;
    if(flags&REPROJECT) {
        previousUV+=md.xy;
        if(!(flags&MV_HAS_JITTER)) previousUV+=previousJitterUV-jitterUV;
    }
    float motionPixels=length(md.xy*float2(inputSize));
    // 先拒绝，再读取历史；Camera Cut 首帧确实不执行 historyColor.SampleLevel。
    uint reason=0;
    if(!(flags&HISTORY_VALID)) reason=1;
    else if(any(previousUV<0)||any(previousUV>=1)||!all(isfinite(previousUV))) reason=2;
    else if(flags&REJECT_DEPTH) {
        int2 hp=clamp(int2(previousUV*float2(inputSize)),0,int2(inputSize)-1);
        float actual=previousDepth.Load(int3(hp,0)).r;
        float tolerance=max(.001,abs(md.w)*depthRelativeThreshold);
        if(!(md.w>0)||!isfinite(actual)||abs(actual-md.w)>tolerance) reason=3;
    }
    if(reason) { outputColor[p]=float4(current,1); diagnostic[p]=float4(0,0,motionPixels,reason); return; }
    float3 history=historyColor.SampleLevel(linearClamp,previousUV,0).rgb;
    if(!all(isfinite(history))) { outputColor[p]=float4(current,1); diagnostic[p]=float4(0,0,motionPixels,4); return; }
    float3 originalHistory=history;
    if(flags&CLAMP_HISTORY) {
        float3 lo=1e30,hi=-1e30;
        [unroll] for(int y=-1;y<=1;++y) [unroll] for(int x=-1;x<=1;++x) {
            float3 c=Current(p+int2(x,y)); if(flags&YCOCG)c=ToYCoCg(c);
            lo=min(lo,c); hi=max(hi,c);
        }
        if(flags&YCOCG)history=ToYCoCg(history);
        history=clamp(history,lo,hi);
        if(flags&YCOCG)history=FromYCoCg(history);
    }
    float reactive=saturate(reactiveMask.Load(int3(p,0)).r);
    float weight=saturate(historyWeight)*(1-reactive);
    outputColor[p]=float4(lerp(current,history,weight),1);
    diagnostic[p]=float4(weight>0?1:0,length(originalHistory-history),motionPixels,reactive>=1?5:0);
}

[numthreads(8,8,1)] void BilinearCS(uint3 tid:SV_DispatchThreadID) {
    if(any(tid.xy>=outputSize)) return;
    // 输出像素中心 → 归一化 UV；硬件 sampler 内部执行 uv*inputSize-.5。
    outputColor[tid.xy]=float4(SampleCurrent((tid.xy+.5)/float2(outputSize)),1);
}
float CubicWeight(float x) {
    // Catmull–Rom: a=-.5；满足插值节点、C1 连续和常数重建，负瓣可能引入 ringing。
    x=abs(x); if(x<1)return 1.5*x*x*x-2.5*x*x+1;
    if(x<2)return -.5*x*x*x+2.5*x*x-4*x+2; return 0;
}
[numthreads(8,8,1)] void BicubicCS(uint3 tid:SV_DispatchThreadID) {
    if(any(tid.xy>=outputSize)) return;
    float2 source=(tid.xy+.5)*float2(inputSize)/float2(outputSize)-.5;
    int2 base=int2(floor(source)); float2 f=source-base; float3 sum=0;
    [unroll] for(int y=-1;y<=2;++y) [unroll] for(int x=-1;x<=2;++x)
        sum+=Current(base+int2(x,y))*CubicWeight(x-f.x)*CubicWeight(y-f.y);
    outputColor[tid.xy]=float4(sum,1); // 不把 ringing 隐藏为 clamp 后再宣称无振铃。
}

[numthreads(8,8,1)] void MotionCS(uint3 tid:SV_DispatchThreadID) {
    if(any(tid.xy>=outputSize)) return;
    float2 v=motionDepth.Load(int3(tid.xy,0)).xy*float2(inputSize);
    outputColor[tid.xy]=float4(.5+v.x/32,.5+v.y/32,0,1);
}
[numthreads(8,8,1)] void SharpenCS(uint3 tid:SV_DispatchThreadID) {
    if(any(tid.xy>=outputSize))return;
    int2 p=int2(tid.xy);float3 c=Current(p);
    float3 blur=.25*(Current(p+int2(-1,0))+Current(p+int2(1,0))+Current(p+int2(0,-1))+Current(p+int2(0,1)));
    outputColor[p]=float4(max(0,c+saturate(sharpenStrength)*(c-blur)),1);
}

// TAA内部history定义在当帧jittered格点；最终显示/比较必须回到固定输出格点。
// clip几何向+j移动时，纹理Fj(u)=F(u-j)；查询Fj(u+j)才恢复F(u)，所以这里是加号。
// 此pass输出仅供显示/捕获，不交换进上面的jittered history，否则下一帧会混用两套网格。
// 同尺寸输入/输出，独立资源，线性clamp在屏幕边缘复制边界值；计时必须包含这个pass。
[numthreads(8,8,1)] void UnjitterCS(uint3 tid:SV_DispatchThreadID) {
    if(any(tid.xy>=outputSize))return;
    float2 uv=(tid.xy+.5)/float2(outputSize);
    outputColor[tid.xy]=float4(SampleCurrent(uv+jitterUV),1);
}
