// F2全屏三角形没有VB：三个顶点覆盖viewport，避开两个三角形的对角接缝。
Texture2D<float4> inputColor:register(t0);SamplerState linearClamp:register(s0);
cbuffer Display:register(b0){uint mode;float exposure;uint ui;uint frame;};
struct V{float4 p:SV_Position;float2 uv:TEXCOORD;};
V DisplayVS(uint id:SV_VertexID){V o;o.uv=float2((id<<1)&2,id&2);o.p=float4(o.uv*float2(2,-2)+float2(-1,1),0,1);return o;}
float4 DisplayPS(V i):SV_Target{
    float4 c=inputColor.SampleLevel(linearClamp,i.uv,0);
    if(mode==1)c.rgb=dot(c.rgb,float3(.2126,.7152,.0722));
    if(mode==2)c.rgb*=exp2(exposure);
    if(mode==3){c.rgb=max(c.rgb,0)*exp2(exposure);c.rgb=c.rgb/(1+c.rgb);c.rgb=select(c.rgb<=.0031308,c.rgb*12.92,1.055*pow(c.rgb,1/2.4)-.055);}
    // UI在输出分辨率合成，边框固定像素宽；不进入低分辨率输入/历史。
    uint2 p=uint2(i.p.xy);if(ui&&p.x>=8&&p.x<120&&p.y>=8&&p.y<30){bool edge=p.x<10||p.x>=118||p.y<10||p.y>=28;c.rgb=edge?float3(1,1,1):float3(.02,.1,.15);if(p.y>=16&&p.y<22&&p.x<14+frame%100)c.rgb=float3(.1,1,.2);}
    c.a=1;return c;
}
