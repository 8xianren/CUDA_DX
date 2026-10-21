// 真实DXR求交的多反弹积分。法线/光源支持域限定于[-1,1]^3闭合轴对齐盒腔。
// mode0=BSDF-only；mode1=Power MIS；mode2=故意不加权而重复累加，用于反例。
struct ObjectRecord {row_major float4x4 world;uint material,node,mesh,pad;};
struct Config {uint paths,maxScatters,seed,mode;float3 rho;uint pad0;float3 emission;uint pad1;uint rrMode,rrStart;float rrMin,rrMax;};
struct Record {float4 position,beta,radiance,lightPoint,direct,rayDirection;uint4 diagnostics;float4 roulette;};
struct Payload {uint material;float t;uint2 pad;};
RaytracingAccelerationStructure scene:register(t0);
StructuredBuffer<ObjectRecord> objects:register(t1);
StructuredBuffer<Config> configs:register(t2);
RWStructuredBuffer<Record> output:register(u0);
static const float PI=3.14159265358979323846;
uint Next(inout uint state){state+=0x9e3779b9u;uint x=state;x=(x^(x>>16))*0x21f0aaadu;x=(x^(x>>15))*0x735a2d97u;return x^(x>>15);}
float Uniform(inout uint state){return ((Next(state)>>9)+.5)/8388608.;}
Payload Shoot(float3 origin,float3 direction){
    RayDesc ray;ray.Origin=origin;ray.Direction=direction;ray.TMin=1e-6;ray.TMax=100;
    Payload p=(Payload)0;TraceRay(scene,RAY_FLAG_FORCE_OPAQUE,255,0,0,0,ray,p);return p;
}
uint Axis(float3 p){float3 a=abs(p);return a.x>=a.y&&a.x>=a.z?0:(a.y>=a.z?1:2);}
float3 Normal(float3 p){uint axis=Axis(p);float3 n=0;n[axis]=p[axis]>0?-1:1;return n;}
float Weight(float own,float other){float scale=max(own,other);if(scale<=0)return 0;float a=own/scale,b=other/scale;return a*a/(a*a+b*b);}
float LightPdf(float3 from,float3 to){float3 delta=to-from;float r2=dot(delta,delta);float cosine=dot(Normal(to),-normalize(delta));return cosine>0?r2/(24*cosine):0;}
float3 LightPoint(inout uint rng){
    // 先选6个等面积面之一，再在面积4的面上均匀取点；联合面积密度(1/6)*(1/4)=1/24。
    uint face=min((uint)(Uniform(rng)*6),5u),axis=face/2;float3 q=0;q[axis]=(face&1)?1:-1;
    float a=2*Uniform(rng)-1,b=2*Uniform(rng)-1;
    if(axis==0){q.y=a;q.z=b;}else if(axis==1){q.x=a;q.z=b;}else{q.x=a;q.y=b;}return q;
}
float3 CosineDirection(float3 n,inout uint rng){
    float u=Uniform(rng),phi=2*PI*Uniform(rng),r=sqrt(u);
    float3 helper=abs(n.z)<.9?float3(0,0,1):float3(0,1,0);
    float3 t=normalize(cross(helper,n)),b=cross(n,t);
    return normalize(t*(r*cos(phi))+b*(r*sin(phi))+n*sqrt(1-u));
}
[shader("raygeneration")]
void RayGen(){
    Config c=configs[0];uint path=DispatchRaysIndex().x;uint rng=(path+1)*747796405u+c.seed*2891336453u;
    // 分开随机数流：轮盘赌不会挪动灯/BSDF的序列，便于同seed配对比较；无跨线程共享状态。
    uint rrRng=rng^0xa511e9b3u;
    float3 origin=0,direction=float3(0,0,1),beta=1,L=0,previousPoint=0;float previousPdf=0;
    for(uint depth=0;depth<=c.maxScatters;++depth){
        Record r=(Record)0;r.diagnostics.y=1;r.diagnostics.w=depth;r.rayDirection=float4(direction,0);
        Payload hit=Shoot(origin,direction);r.diagnostics.x=hit.material;
        if(hit.material==0){ // 封闭fixture中miss是失败，填满剩余记录，不能让读回包含未初始化内存。
            r.diagnostics.z=1;for(uint j=depth;j<=c.maxScatters;++j)output[path*(c.maxScatters+1)+j]=r;break;
        }
        float3 x=origin+hit.t*direction;uint axis=Axis(x);
        // 有限精度可能把临近棱边的交点舍入成同时位于两个面，下一方向会从错误侧出盒。
        // 将所属面坐标吸附到±1，切向坐标限制在距棱边2e-6以内侧；小于此量的几何细节被近似。
        // 仅限本轴对齐盒的数值防护，不是通用网格偏移算法；CPU检查实际几何偏差。
        float side=x[axis]>0?1:-1;x=clamp(x,-1+2e-6,1-2e-6);x[axis]=side;
        float3 n=Normal(x);r.position=float4(x,hit.t);
        float emissionWeight=1;
        if(depth>0&&c.mode==1)emissionWeight=Weight(previousPdf,LightPdf(previousPoint,x));
        r.beta=float4(beta,emissionWeight);L+=beta*c.emission*emissionWeight;
        // 在最后顶点仍收取发光，但不做再多一次散射的NEE，否则有限深度定义改变。
        if(depth<c.maxScatters&&c.mode!=0){
            float3 q=LightPoint(rng),delta=q-x;float3 wi=normalize(delta);float cosine=dot(n,wi),pL=LightPdf(x,q);
            r.lightPoint=float4(q,0);
            if(cosine>0&&pL>0){
                Payload shadow=Shoot(x,wi);r.diagnostics.y++;
                // 当前闭合凸盒中非同面连接应可见；仍用真实DXR距离确认到达所选灯点。
                bool visible=shadow.material!=0&&abs(shadow.t-length(delta))<2e-4;
                r.lightPoint.w=visible?1:0;if(!visible)r.diagnostics.z++;
                float pB=cosine/PI,w=c.mode==1?Weight(pL,pB):1;
                r.direct=float4(visible?beta*(c.rho/PI)*c.emission*cosine*w/pL:float3(0,0,0),w);
                L+=r.direct.xyz;
            }
        }
        r.radiance=float4(L,previousPdf);r.roulette=float4(1,0,0,0);
        if(depth==c.maxScatters){output[path*(c.maxScatters+1)+depth]=r;break;}
        float3 next=CosineDirection(n,rng);float pB=dot(n,next)/PI;
        // beta只乘散射因子，绝不乘本次直接光MIS权重。每次只记录供下一发光命中使用的PDF。
        beta*=c.rho/PI*dot(n,next)/pB;previousPdf=pB;previousPoint=x;
        bool keep=true;
        if(c.rrMode!=0&&depth+1>=c.rrStart){
            // 当前顶点的发光和NEE已经收取。只随机删除尚未追踪的后续项，不能缩放已有L。
            // 对反射RGB材质用最大通道估计后续权重；三个通道共享同一次生死决策和补偿。
            float peak=max(beta.x,max(beta.y,beta.z));
            float survival=peak>0?clamp(peak,c.rrMin,c.rrMax):0;
            float u=Uniform(rrRng);keep=u<survival;r.roulette=float4(survival,u,1,keep?1:0);
            if(keep&&c.rrMode==1)beta/=survival; // 必须除存活概率，不是除终止概率。
        }else r.roulette.w=1;
        output[path*(c.maxScatters+1)+depth]=r;
        if(!keep){
            // 未访问的槽写入零beta/零射线计数，并保留最终累计L；它们不算存活顶点。
            // 这样CPU可以固定步长读回，不把旧显存当作路径，也无需GPU原子追加队列。
            Record dead=(Record)0;dead.radiance=float4(L,0);
            for(uint j=depth+1;j<=c.maxScatters;++j){dead.diagnostics.w=j;output[path*(c.maxScatters+1)+j]=dead;}
            break;
        }
        origin=x;direction=next;
    }
}
[shader("miss")]void Miss(inout Payload hit){hit=(Payload)0;}
[shader("closesthit")]void ClosestHit(inout Payload hit,BuiltInTriangleIntersectionAttributes attributes){
    hit.material=objects[InstanceID()].material+1;hit.t=RayTCurrent(); // 无嵌套TraceRay，管线深度仍为1。
}
