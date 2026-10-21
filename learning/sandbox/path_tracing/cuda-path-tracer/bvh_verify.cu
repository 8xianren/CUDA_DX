#include "cuda_support.h"
#include "bvh_reference.h"
#include <iostream>
#include <iomanip>
#include <chrono>
using namespace cuda_pt;
template<bool Accelerated>
__global__ void TraceKernel(const Triangle* triangles,uint32_t triangleCount,const Node* nodes,uint32_t nodeCount,
    const uint32_t* order,const Ray* rays,uint32_t rayCount,Result* output){
    uint32_t i=blockIdx.x*blockDim.x+threadIdx.x;if(i>=rayCount)return;
    // 一线程一条完整求交查询，各自写output[i]，无跨线程原子操作；BVH与暴力只改变候选选择。
    output[i]=Accelerated?TraceBvh(triangles,triangleCount,nodes,nodeCount,order,rays[i]):TraceBrute(triangles,triangleCount,rays[i]);
}
struct SlabCase {Ray ray;Vec3 lower,upper;uint32_t hit;float entry,exit;};
__global__ void SlabKernel(const SlabCase* cases,uint32_t count,Vec3* output){
    unsigned i=threadIdx.x+blockDim.x*blockIdx.x;if(i>=count)return;float entry,exit;
    bool hit=IntersectBounds(cases[i].ray,cases[i].lower,cases[i].upper,cases[i].ray.tmax,entry,exit);output[i]={hit?1.f:0.f,entry,exit};
}
void ValidateSlabs(){
    // [-1,1]^3闭盒；测试±方向、精确零、起点在内部/面上、有限t区间和恰好接触端点。
    std::vector<SlabCase> cases;auto add=[&](Ray ray,bool hit,float entry=0,float exit=0){cases.push_back({ray,{-1,-1,-1},{1,1,1},uint32_t(hit),entry,exit});};
    add({{0,0,5},0,{0,0,-1},100},true,4,6);add({{0,0,-5},0,{0,0,1},100},true,4,6);
    add({{2,0,5},0,{0,0,-1},100},false);add({{1,0,5},0,{-0.f,0,-1},100},true,4,6);
    add({{0,0,0},0,{1,0,0},100},true,0,1);add({{0,0,5},0,{0,0,-1},3},false);
    add({{0,0,5},0,{0,0,-1},4},true,4,4);add({{0,0,5},6,{0,0,-1},100},true,6,6);
    add({{0,0,5},7,{0,0,-1},100},false);add({{0,2,0},0,{1,0,0},100},false);
    add({{1,1,1},0,{1,0,0},100},true,0,0);add({{-1,-1,-1},0,{-1,0,0},100},true,0,0);
    DeviceBuffer<SlabCase> input(cases);DeviceBuffer<Vec3> output(cases.size());
    SlabKernel<<<1,32>>>(input.pointer,unsigned(cases.size()),output.pointer);CheckCuda(cudaGetLastError(),"slab launch");CheckCuda(cudaDeviceSynchronize(),"slab complete");
    auto values=output.Download();for(size_t i=0;i<cases.size();++i){const auto& c=cases[i];float entry,exit;bool hit=IntersectBounds(c.ray,c.lower,c.upper,c.ray.tmax,entry,exit);
        Require(hit==bool(c.hit)&&values[i].x==float(c.hit),"slab CPU/GPU analytic hit");
        if(hit)Require(entry==c.entry&&exit==c.exit&&values[i].y==c.entry&&values[i].z==c.exit,"slab analytic interval");}
    std::cout<<"SLAB 12 CPU/GPU analytic cases PASS\n";
}
struct Summary {uint64_t hits=0,boxes=0,triangles=0;unsigned stackMax=0,audits=0;double maxT=0,maxBary=0;float bruteMs=0,bvhMs=0;};
Summary VerifyCase(const char* name,const Scene& scene,const Bvh& bvh,const std::vector<Ray>& rays,
    std::ofstream& csv,unsigned auditLimit){
    ValidateScene(scene);ValidateBvh(scene,bvh);for(auto& ray:rays)ValidateRay(ray);
    DeviceBuffer<Triangle> triangles(scene.triangles);DeviceBuffer<Node> nodes(bvh.nodes);DeviceBuffer<uint32_t> order(bvh.order);
    DeviceBuffer<Ray> input(rays);DeviceBuffer<Result> brute(rays.size()),accelerated(rays.size());CudaStream stream;CudaEvents events;
    // 上传用默认流上的同步cudaMemcpy；pageable H→D返回时不能一概认定DMA已结束。
    // 后续是nonblocking stream，不依赖默认流隐式排序，因此明确完成所有上传再启动计时/查询。
    // 这里只在初始化边界等待；正式求交的三个计时轮次不包含该等待或传输。
    CheckCuda(cudaDeviceSynchronize(),"uploads complete before nonblocking stream");
    unsigned groups=(unsigned(rays.size())+127)/128;
    auto launch=[&](bool useBvh){
        if(useBvh)TraceKernel<true><<<groups,128,0,stream.value>>>(triangles.pointer,unsigned(triangles.count),nodes.pointer,unsigned(nodes.count),order.pointer,input.pointer,unsigned(input.count),accelerated.pointer);
        else TraceKernel<false><<<groups,128,0,stream.value>>>(triangles.pointer,unsigned(triangles.count),nodes.pointer,unsigned(nodes.count),order.pointer,input.pointer,unsigned(input.count),brute.pointer);
        CheckCuda(cudaGetLastError(),"trace kernel launch");};
    auto measure=[&](bool useBvh){
        launch(useBvh);CheckCuda(cudaStreamSynchronize(stream.value),"trace warmup");std::vector<float> times;
        for(unsigned repeat=0;repeat<3;++repeat){CheckCuda(cudaEventRecord(events.begin,stream.value),"trace begin");launch(useBvh);CheckCuda(cudaEventRecord(events.end,stream.value),"trace end");
            CheckCuda(cudaEventSynchronize(events.end),"trace complete");float ms=0;CheckCuda(cudaEventElapsedTime(&ms,events.begin,events.end),"trace event time");times.push_back(ms);}
        std::sort(times.begin(),times.end());return times[1];};
    Summary s;s.bruteMs=measure(false);s.bvhMs=measure(true);auto reference=brute.Download(),results=accelerated.Download();
    for(size_t i=0;i<rays.size();++i){auto& a=reference[i];auto& p=results[i];Require(a.counts.error==0&&p.counts.error==0,"GPU traversal error/stack overflow");
        Require(a.hit.id==p.hit.id,"GPU BVH/brute nearest ID mismatch");
        if(a.hit.id!=Invalid){++s.hits;double e=std::abs(double(a.hit.t)-p.hit.t)/(1+std::abs(double(a.hit.t)));Require(e<1e-5,"GPU BVH/brute distance mismatch");}
        Require(a.counts.triangles==scene.triangles.size(),"brute triangle count");s.boxes+=p.counts.boxes;s.triangles+=p.counts.triangles;s.stackMax=std::max(s.stackMax,p.counts.stackMax);
    }
    unsigned audits=std::min(unsigned(rays.size()),auditLimit);
    for(unsigned a=0;a<audits;++a){size_t i=(uint64_t(a)*104729+37)%rays.size();auto independent=Reference(scene,rays[i]);auto actual=results[i].hit;
        if(independent.id!=actual.id){std::cerr<<name<<" CPU audit="<<a<<" ray="<<i<<" expected="<<independent.id<<" actual="<<actual.id<<'\n';}
        Require(independent.id==actual.id,"CPU double plane/Gram vs GPU ID mismatch");
        if(actual.id!=Invalid){s.maxT=std::max(s.maxT,std::abs(actual.t-independent.t)/(1+std::abs(independent.t)));
            s.maxBary=std::max({s.maxBary,std::abs(actual.u-independent.u),std::abs(actual.v-independent.v)});}
        ++s.audits;
    }
    Require(s.maxT<3e-5&&s.maxBary<.003,"CPU double/GPU numeric tolerance");
    csv<<name<<','<<scene.triangles.size()<<','<<rays.size()<<','<<bvh.nodes.size()<<','<<bvh.leaves<<','<<bvh.maxDepth<<','<<s.hits<<','<<s.boxes<<','<<s.triangles<<','<<uint64_t(scene.triangles.size())*rays.size()<<','<<s.stackMax<<','<<s.audits<<','<<s.maxT<<','<<s.maxBary<<','<<s.bruteMs<<','<<s.bvhMs<<'\n';csv.flush();
    std::cout<<name<<" PASS rays="<<rays.size()<<" triangles="<<scene.triangles.size()<<" nodes="<<bvh.nodes.size()<<" depth="<<bvh.maxDepth<<" hits="<<s.hits<<" triangleTests="<<s.triangles<<" boxes="<<s.boxes<<" stack="<<s.stackMax<<" CPU="<<s.audits<<" error="<<s.maxT<<" GPU ms brute/BVH="<<s.bruteMs<<'/'<<s.bvhMs<<'\n'<<std::flush;
    return s;
}
int main(int argc,char** argv){
    if(argc!=4){std::cerr<<"bvh_verify gallery.meshbin output full|quick\n";return 2;}
    try{
        bool quick=std::string(argv[3])=="quick";Require(quick||std::string(argv[3])=="full","verification mode");
        std::filesystem::path out=argv[2];std::filesystem::create_directories(out);std::ofstream csv(out/"bvh.csv");csv<<std::setprecision(12)<<"case,triangles,rays,nodes,leaves,max_depth,hits,box_tests,bvh_triangle_tests,brute_triangle_tests,stack_max,cpu_audits,max_t_relative,max_bary,brute_ms,bvh_ms\n";
        CheckCuda(cudaSetDevice(0),"device");cudaDeviceProp properties{};CheckCuda(cudaGetDeviceProperties(&properties,0),"device properties");
        Require(properties.major==12&&properties.minor==0,"lesson binary expects sm_120 device");
        cudaFuncAttributes attributes{};CheckCuda(cudaFuncGetAttributes(&attributes,TraceKernel<true>),"BVH kernel attributes");
        std::cout<<"GPU="<<properties.name<<" sm="<<properties.major<<properties.minor<<" BVH registers="<<attributes.numRegs<<" localBytes/thread="<<attributes.localSizeBytes<<" staticSharedBytes="<<attributes.sharedSizeBytes<<'\n';
        ValidateSlabs();
        std::vector<Ray> anchors{{{.25f,.25f,1},0,{0,0,-1},10},{{.25f,.25f,-1},0,{0,0,1},10},{{.8f,.8f,1},0,{0,0,-1},10},
            {{.25f,.25f,1},0,{1,0,0},10},{{0,0,1},0,{0,0,-1},1},{{.25f,.25f,1},0,{0,0,-1},.5f},{{.25f,.25f,1},1.1f,{0,0,-1},10}};
        auto single=Fixture();auto one=VerifyCase("single-analytic",single,BuildBvh(single),anchors,csv,7);Require(one.hits==3,"analytic triangle hit count");
        auto duplicate=Fixture(100);auto duplicateResult=VerifyCase("coincident-100",duplicate,BuildBvh(duplicate),anchors,csv,7);
        Require(duplicateResult.triangles==400,"overlap worst-case triangle count"); // 三条命中射线，加(.8,.8)穿过AABB却落在三角形外的一条；每条都访问100个重叠三角形。
        Scene empty;VerifyCase("empty",empty,BuildBvh(empty),anchors,csv,7);
        auto degenerate=Fixture();degenerate.triangles[0].c={2,0,0};VerifyCase("degenerate",degenerate,BuildBvh(degenerate),anchors,csv,7);
        for(float scale:{.001f,1000.f}){auto scene=Fixture(1,scale);auto rays=anchors;for(auto& r:rays){r.origin=r.origin*scale;r.tmin*=scale;r.tmax*=scale;}
            VerifyCase(scale<1?"small-scale":"large-scale",scene,BuildBvh(scene),rays,csv,7);}
        // 反例：输入数组先放远三角形，任何“碰到第一个就返回”的closest实现都会错选z=5。
        Scene nearest=Fixture(2);for(auto* p:{&nearest.triangles[0].a,&nearest.triangles[0].b,&nearest.triangles[0].c})p->z=5;
        for(auto* p:{&nearest.triangles[1].a,&nearest.triangles[1].b,&nearest.triangles[1].c})p->z=2;
        Ray ray{{.25f,.25f,0},0,{0,0,1},10};auto good=TraceBrute(nearest.triangles.data(),2,ray);Hit first;first.t=10;IntersectTriangle(ray,nearest.triangles[0],first);
        Require(good.hit.id==1&&good.hit.t==2&&first.id==0&&first.t==5,"first-hit negative control");
        VerifyCase("nearest-not-first",nearest,BuildBvh(nearest),{ray},csv,1);
        auto scene=LoadScene(argv[1]);auto start=std::chrono::steady_clock::now();auto bvh=BuildBvh(scene);double buildMs=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();ValidateBvh(scene,bvh);
        auto rays=GalleryRays(bvh,quick?129:8197);auto result=VerifyCase("gallery-random",scene,bvh,rays,csv,quick?64:512);
        // CPU结构验证必须拒绝坏树/坏输入，避免把越界和环送进GPU。修改仅发生在验证副本。
        unsigned rejected=0;auto bad=bvh;bad.nodes[0].first=uint32_t(bad.nodes.size());try{ValidateBvh(scene,bad);}catch(...){++rejected;}
        bad=bvh;bad.nodes[0].first=0;try{ValidateBvh(scene,bad);}catch(...){++rejected;}
        bad=bvh;bad.order[0]=bad.order[1];try{ValidateBvh(scene,bad);}catch(...){++rejected;}
        Ray zero{};try{ValidateRay(zero);}catch(...){++rejected;}
        Require(rejected==4,"CPU invalid-input rejection");
        std::ofstream meta(out/"metadata.txt");meta<<"build_cpu_ms="<<buildMs<<"\nnode_bytes="<<bvh.nodes.size()*sizeof(Node)<<"\norder_bytes="<<bvh.order.size()*4<<"\ntriangle_bytes="<<scene.triangles.size()*sizeof(Triangle)<<"\nregisters="<<attributes.numRegs<<"\nlocal_bytes_per_thread="<<attributes.localSizeBytes<<"\nrejected="<<rejected<<'\n';
        Require(meta&&csv,"report write");std::cout<<"BVH VERIFY PASS CPU_build_ms="<<buildMs<<" invalid_rejected="<<rejected<<'\n';return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
