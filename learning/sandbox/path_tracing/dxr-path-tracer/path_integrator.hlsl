#define PBR_ENERGY_BALANCED 1
#include "pbr.hlsli"
#include "surface.hlsli"
#include "sky_environment.hlsli"
#include "../pt08-materials/dielectric.hlsli"
ByteAddressBuffer pathData:register(t6);
struct Config {uint width,height,spp,seed,maxScatters,mode,rrStart,flags;float3 eye,forward,right,up,environment;float tanHalfFovY,environmentIntensity,offset,lightScale;uint lightCount,sampleOffset;float totalArea;};
Config ReadConfig(){Config c;uint4 a=pathData.Load4(0),b=pathData.Load4(16);c.width=a.x;c.height=a.y;c.spp=a.z;c.seed=a.w;
    c.maxScatters=b.x;c.mode=b.y;c.rrStart=b.z;c.flags=b.w;
    float4 e=asfloat(pathData.Load4(32)),f=asfloat(pathData.Load4(48)),r=asfloat(pathData.Load4(64)),u=asfloat(pathData.Load4(80));
    c.eye=e.xyz;c.tanHalfFovY=e.w;c.forward=f.xyz;c.environmentIntensity=f.w;c.right=r.xyz;c.offset=r.w;c.up=u.xyz;c.lightScale=u.w;
    c.lightCount=pathData.Load(96);c.totalArea=asfloat(pathData.Load(100));c.sampleOffset=pathData.Load(104);c.environment=asfloat(pathData.Load3(112));return c;}
struct Light {float3 a,b,c;float area,cdf;uint instance,primitive;};
Light ReadLight(uint i){uint address=128+64*i;Light l;l.a=asfloat(pathData.Load3(address));l.b=asfloat(pathData.Load3(address+16));l.c=asfloat(pathData.Load3(address+32));
    uint4 tail=pathData.Load4(address+48);l.area=asfloat(tail.x);l.cdf=asfloat(tail.y);l.instance=tail.z;l.primitive=tail.w;return l;}
#include "path_pixel.hlsli"
RWStructuredBuffer<Pixel> output:register(u0);
uint Hash(uint x){x=(x^(x>>16))*0x21f0aaadu;x=(x^(x>>15))*0x735a2d97u;return x^(x>>15);}
float Random(uint pixel,uint sample,uint seed,uint depth,uint dim){uint x=(pixel+1)*747796405u+(sample+1)*2891336453u+seed*277803737u+depth*1597334677u+dim*3812015801u;return ((Hash(x)>>9)+.5)/8388608.;}
float Power(float a,float b){float scale=max(a,b);if(scale<=0)return 0;a/=scale;b/=scale;return a*a/(a*a+b*b);}
float3 ToLocal(float3 w,float3 n,float3 t,float3 b){return float3(dot(w,t),dot(w,b),dot(w,n));}
float3 ToWorld(float3 w,float3 n,float3 t,float3 b){return normalize(w.x*t+w.y*b+w.z*n);}
float3 Offset(float3 p,float3 n,float3 direction,float epsilon){return p+(dot(n,direction)>=0?epsilon:-epsilon)*n;}
float LightPdf(float3 previous,float3 targetPoint,float3 normal,float totalArea){float3 v=targetPoint-previous;float d2=dot(v,v);float cosine=dot(normal,-normalize(v));return cosine>0&&totalArea>0?d2/(totalArea*cosine):0;}
[shader("raygeneration")]
void RayGen(){Config c=ReadConfig();uint2 ij=DispatchRaysIndex().xy;uint pixel=ij.y*c.width+ij.x;Pixel result=(Pixel)0;float3 sum=0;float square=0;
    float3 guideAlbedo=0,guideNormal=0;float guideCoverage=0,guideDepth=0;
    for(uint localSample=0;localSample<c.spp;++localSample){
        uint sample=c.sampleOffset+localSample; // 跨批次连续编号；历史重置时从0重新开始。
        // 从pixel/sample/depth/dimension直接取随机数；NEE或RR开关不会挪动BSDF随机序列。
        float sx=((ij.x+Random(pixel,sample,c.seed,0,0))/c.width*2-1)*(float(c.width)/c.height)*c.tanHalfFovY;
        float sy=(1-(ij.y+Random(pixel,sample,c.seed,0,1))/c.height*2)*c.tanHalfFovY;
        float3 origin=c.eye,direction=normalize(c.forward+sx*c.right+sy*c.up),beta=1,L=0,previous=0;
        float previousPdf=0,etaScale=1;bool previousDelta=true;int medium=-1;
        for(uint depth=0;depth<=c.maxScatters;++depth){
            Payload hit=Shoot(origin,direction);result.events.x++;
            if(hit.instancePlus==0){
                if(medium!=-1){result.errors.x++;break;} // 封闭玻璃内部不得在未穿出边界时直接逃到环境。
                if(depth==0&&(c.flags&2))guideAlbedo+=1; // 背景使用中性albedo1，normal/depth/coverage为0。
                if(c.flags&4){
                    // 天空与太阳是两个相加的辐亮度分量，各有一份 NEE 估计；BSDF
                    // 命中环境时必须分别使用对应 PDF 做 MIS，不能把整张天空再加一次。
                    // 相机/理想镜面/玻璃的 delta 路径没有连续 NEE 竞争，权重仍为 1。
                    float skyWeight=1,sunWeight=1;
                    if(depth>0&&!previousDelta&&c.mode==1){
                        skyWeight=Power(previousPdf,SkyDomePdf());
                        sunWeight=Power(previousPdf,SkySunPdf(direction));
                    }
                    L+=beta*c.environmentIntensity*(SkyDomeRadiance(direction)*skyWeight+SkyDiskRadiance(direction)*sunWeight);
                }else L+=beta*c.environment*c.environmentIntensity; // 旧恒色环境仍不参与 NEE，保持既有基线。
                break;
            }
            Surface s=LoadSurface(hit,(c.flags&8)!=0);float3 woWorld=-direction;float front=dot(s.geometryNormal,woWorld);
            // 插值法线在轮廓附近可能背向观察方向，即使三角形本身仍为正面。
            // BRDF 的 wo.z 必须为正；这里明确回退几何法线，避免 0/0 权重和黑边。
            if(front>0&&dot(s.normal,woWorld)<=0)s.normal=s.geometryNormal;
            if(localSample==0&&depth==0){result.albedo=float4(s.material.base,s.material.roughness);result.normal=float4(s.normal,s.materialID+1);result.position=float4(s.position,hit.instancePlus);}
            bool glass=s.dielectricIOR>0;
            if(depth==0&&(c.flags&2)){
                // 降噪特征与beauty共用同一抖动主射线/箱式像素滤波，不把首个样本冒充完整像素。
                // 首命中近似：普通材质用base，纯金属时它就是F0；无吸收玻璃/发光面取中性1。
                // normal为世界空间单位着色法线的样本均值（flags8关闭时等于几何法线）；
                // 均值不再归一化，保留轮廓覆盖信息。
                guideAlbedo+=(glass||any(s.emission>0))?float3(1,1,1):s.material.base;
                guideNormal+=s.normal;guideCoverage+=1;guideDepth+=dot(s.position-c.eye,c.forward);
            }
            if(!glass&&front<=0){result.ends.z++;break;} // 当前明确单面：不将背面法线静默翻到相机侧。
            if(front>0&&any(s.emission>0)){
                float w=1;if(depth>0&&!previousDelta&&c.mode==1)w=Power(previousPdf,LightPdf(previous,s.position,s.geometryNormal,c.totalArea));
                L+=beta*s.emission*c.lightScale*w;result.ends.w++;
            }
            // 深度K的定义：先收取第K次散射后的发光，再停止；最后顶点不额外执行NEE。
            if(depth==c.maxScatters){result.ends.y++;break;}
            float3 t,b;LocalFrame(s.normal,t,b);float3 wo=ToLocal(woWorld,s.normal,t,b);
            if(!glass&&c.mode!=0&&c.lightCount>0){
                float selector=Random(pixel,sample,c.seed,depth,10);uint low=0,high=c.lightCount-1;
                // 面积CDF二分，不假定所有灯等面积，也不把primitive编号误当成全场景编号。
                while(low<high){uint mid=(low+high)/2;if(selector<ReadLight(mid).cdf)high=mid;else low=mid+1;}
                Light light=ReadLight(low);float root=sqrt(Random(pixel,sample,c.seed,depth,11)),v=Random(pixel,sample,c.seed,depth,12);
                float3 bary=float3(1-root,root*(1-v),root*v),target=light.a*bary.x+light.b*bary.y+light.c*bary.z;
                float3 wiWorld=normalize(target-s.position),wi=ToLocal(wiWorld,s.normal,t,b);
                float3 lightNormal=normalize(cross(light.b-light.a,light.c-light.a));float pL=LightPdf(s.position,target,lightNormal,c.totalArea);
                if(wi.z>0&&dot(s.geometryNormal,wiWorld)>0&&pL>0){PbrEvaluation e=PbrEval(s.material,wo,wi,0);
                    if(any(e.f>0)){
                        // 偏移用于避免自交；阴影方向重新指向选中的灯点，几何PDF仍由原表面点计算。
                        float3 shadowOrigin=Offset(s.position,s.geometryNormal,wiWorld,c.offset);Payload shadow=Shoot(shadowOrigin,normalize(target-shadowOrigin));result.events.x++;result.events.y++;
                        bool visible=shadow.instancePlus==light.instance+1&&shadow.primitive==light.primitive;
                        if(visible){Payload chosen;chosen.instancePlus=light.instance+1;chosen.primitive=light.primitive;chosen.bary=bary.yz;Surface emitter=LoadSurface(chosen);
                            float w=c.mode==1?Power(pL,e.pdf):1;L+=beta*e.f*wi.z*emitter.emission*c.lightScale*w/pL;}
                    }
                }
            }
            if(!glass&&c.mode!=0&&(c.flags&4)&&c.environmentIntensity>0){
                // 每个分量各采一次，分别估计 ∫ f Li cosθ V dω；它们不是一次二选一
                // 的混合采样，所以没有 1/2 选择概率，也不能将两份光各加上全环境。
                // 与 BSDF 采用同样的一样本 power heuristic。mode=0 为纯 BSDF；
                // mode=1 为正确 MIS；mode=2 保留本课程既有“重复计数”负对照语义。
                [unroll] for(uint environmentPart=0;environmentPart<2;++environmentPart){
                    uint dimension=30+2*environmentPart;
                    float2 random=float2(Random(pixel,sample,c.seed,depth,dimension),Random(pixel,sample,c.seed,depth,dimension+1));
                    float3 wiWorld=environmentPart==0?SampleSkyDome(random):SampleSkySun(random);
                    float3 wi=ToLocal(wiWorld,s.normal,t,b);
                    float pL=environmentPart==0?SkyDomePdf():SkySunPdf(wiWorld);
                    if(wi.z>0&&dot(s.geometryNormal,wiWorld)>0&&pL>0){
                        PbrEvaluation e=PbrEval(s.material,wo,wi,0);
                        if(any(e.f>0)){
                            float3 shadowOrigin=Offset(s.position,s.geometryNormal,wiWorld,c.offset);
                            Payload shadow=Shoot(shadowOrigin,wiWorld);result.events.x++;result.events.y++;
                            // 沿用教学场景的 1000 m ray.TMax；只有未命中任何不透明几何
                            // 才看到无限远环境。当前阴影不求解穿过玻璃的折射/透射。
                            if(shadow.instancePlus==0){
                                float3 radiance=environmentPart==0?SkyDomeRadiance(wiWorld):SkyDiskRadiance(wiWorld);
                                float weight=c.mode==1?Power(pL,e.pdf):1;
                                L+=beta*e.f*wi.z*radiance*c.environmentIntensity*weight/pL;
                            }
                        }
                    }
                }
            }
            float3 next;bool delta;float pdf=0;
            if(glass){
                bool entering=front>0;int identity=int(hit.instancePlus)-1;
                if((entering&&medium!=-1)||(!entering&&medium!=identity)){result.errors.x++;break;} // 本课只支持彼此不嵌套的封闭介质。
                DielectricSample ds=SampleDielectric(direction,s.geometryNormal,1,s.dielectricIOR,Random(pixel,sample,c.seed,depth,20),0);
                if(ds.event==0){result.errors.x++;break;}next=normalize(ds.direction);beta*=ds.weight;etaScale*=ds.etaScale;delta=true;
                if(ds.event==2){medium=entering?identity:-1;result.errors.w++;}
            }else{
                PbrSample bs=PbrDraw(s.material,wo,float3(Random(pixel,sample,c.seed,depth,20),Random(pixel,sample,c.seed,depth,21),Random(pixel,sample,c.seed,depth,22)),0);
                if(bs.event==1){result.events.w++;break;}if(bs.event==0){result.errors.x++;break;}
                next=ToWorld(bs.wi,s.normal,t,b);beta*=bs.weight;delta=bs.event==3;pdf=bs.pdf;
                // 插值着色法线只控制 BRDF；几何法线仍定义实体表面。若采样到实体
                // 内部则拒绝该路径，不能从表面另一侧发射而漏光，也不把它记成 NaN。
                if(dot(s.geometryNormal,next)<=0){result.events.w++;break;}
            }
            result.events.z++;if(delta)result.errors.z++;
            if(any(!isfinite(beta))||any(beta<0)||!isfinite(etaScale)){result.errors.y++;break;}
            if(!any(beta>0))break;
            previous=s.position;previousPdf=pdf;previousDelta=delta;
            // beta包含Radiance的折射率平方；RR用beta*etaScale避免把进玻璃后的尺度变化误判为吸收。
            if((c.flags&1)&&depth+1>=c.rrStart){float peak=max(max(beta.x,beta.y),beta.z)*etaScale;float survival=clamp(peak,.05,.95);
                if(Random(pixel,sample,c.seed,depth,60)>=survival){result.ends.x++;break;}beta/=survival;}
            origin=Offset(s.position,s.geometryNormal,next,c.offset);direction=next;
        }
        if(any(!isfinite(L))||any(L<0)){result.errors.y++;L=0;}sum+=L;float y=dot(L,float3(.2126,.7152,.0722));square+=y*y;
    }
    result.radiance=float4(sum/c.spp,square/c.spp);
    if(c.flags&2){
        // 仅显式guides模式改写这两项语义；position仍保留首样本身份/位置用于几何诊断。
        result.albedo=float4(guideAlbedo/c.spp,guideCoverage/c.spp);
        result.normal=float4(guideNormal/c.spp,guideDepth/c.spp);
    }
    output[pixel]=result;
}
