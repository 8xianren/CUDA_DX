// CPU按DirectXMath行向量矩阵写入，显式row_major避免把内存顺序当数学约定。
cbuffer Object : register(b0){row_major float4x4 currentVP;row_major float4x4 previousVP;float4 color;float4 options;float4 jitterExtent;};
Texture2D<float4> checker : register(t0);SamplerState linearWrap : register(s0);
struct VOut{float4 position:SV_Position;float4 current:CURR;float4 previous:PREV;float2 uv:TEXCOORD;};
VOut SceneVS(float3 position:POSITION,float2 uv:TEXCOORD){VOut o;o.current=mul(float4(position,1),currentVP);o.previous=mul(float4(position,1),previousVP);o.position=o.current;o.position.xy+=float2(2,-2)*jitterExtent.xy/jitterExtent.zw*o.position.w;o.uv=uv;return o;}
struct Output{float4 color:SV_Target0;float4 motionDepth:SV_Target1;float depth:SV_Target2;float2 velocity:SV_Target3;float reactive:SV_Target4;};
Output ScenePS(VOut i){
    Output o;float alpha=color.a;float3 rgb=color.rgb;
    if(options.x==1)rgb*=checker.SampleBias(linearWrap,i.uv*3,options.z).rgb;
    if(options.x==2){ // 叶片状软alpha：clip和A2C使用同一连续信号，只改变覆盖规则。
        float v=sin(i.uv.x*48+i.uv.y*5);alpha=saturate(v*2+.5);
        if(options.y==0)clip(alpha-.5);
    }
    float2 currentUV=i.current.xy/i.current.w*float2(.5,-.5)+.5;
    float2 prevUV=i.previous.xy/i.previous.w*float2(.5,-.5)+.5;
    float2 motion=prevUV-currentUV;
    o.color=float4(rgb,alpha);o.motionDepth=float4(motion,i.current.w,i.previous.w);
    o.depth=i.current.w;o.velocity=motion*jitterExtent.zw;o.reactive=options.x==3?1:0;return o;
}
