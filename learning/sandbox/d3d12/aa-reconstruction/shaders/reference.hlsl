// F10：独立高分辨率光栅结果按整数像素面积平均；不是把双线性四个tap称为16样本参考。
Texture2D<float4> source:register(t0);RWTexture2D<float4> target:register(u0);
cbuffer Extent:register(b0){uint2 inputSize;uint2 outputSize;};
[numthreads(8,8,1)]void ReferenceCS(uint3 id:SV_DispatchThreadID){if(any(id.xy>=outputSize))return;uint2 scale=inputSize/outputSize;float3 sum=0;for(uint y=0;y<scale.y;++y)for(uint x=0;x<scale.x;++x)sum+=source.Load(int3(id.xy*scale+uint2(x,y),0)).rgb;target[id.xy]=float4(sum/(scale.x*scale.y),1);}
