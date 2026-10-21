#include "material_sampling.h"
#include <cmath>
#include <iostream>
#include <stdexcept>
// D.4：本目标只链接scene_render→scene_gpu→scene_model，不链接Assimp。
// 场景来自程序而非文件，检验GPU端是否真的只依赖CpuScene契约。
int main(int argc,char** argv){
    if(argc!=2){std::cerr<<"usage: scene_boundary_test material_rays.dxil\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    try{
        Check(com,"COM");CpuScene cpu;CpuMesh mesh;
        Vertex a,b,d;a.position[0]=-1;a.position[1]=-1;b.position[0]=1;b.position[1]=-1;d.position[1]=1;
        mesh.vertices={a,b,d};mesh.indices={0,1,2};cpu.meshes.push_back(mesh);
        CpuMaterial material;material.baseColor={.2f,.4f,.6f,1};cpu.materialAssets.materials.push_back(material);
        cpu.nodes.emplace_back();cpu.nodes[0].meshIndices={0};cpu.instances.push_back({0,0});UpdateWorldMatrices(cpu);
        UploadContext c;auto gpu=UploadScene(c,cpu);auto blases=BuildMeshBlases(c,gpu);
        c.SubmitWait();gpu.staging.clear();for(auto& blas:blases)blas.scratch.Reset();
        // 非法sampler在资源准备层报告。此工厂只Map/写描述符，不录制GPU命令，失败可直接丢弃局部结果。
        cpu.materialAssets.materials[0].textures[0].wrapU=-1;bool rejected=false;
        try{auto invalid=PrepareMaterialBindings(c,cpu,gpu);}catch(const std::runtime_error& e){rejected=std::string(e.what())=="unsupported texture address mode";}
        if(!rejected)throw std::runtime_error("invalid sampler not rejected");
        cpu.materialAssets.materials[0].textures[0].wrapU=10497;
        auto bindings=PrepareMaterialBindings(c,cpu,gpu);
        auto frame=BuildInstanceFrame(c,cpu,gpu,blases,false);
        cpu=CpuScene{}; // 显式销毁源场景；不删GPU资源，也不宣称移除了GpuScene里的验收用CPU参考副本。
        std::vector<MaterialRay> rays={{{0,0,1},0,{0,0,-1},2}};
        auto samples=SampleHitMaterials(c,bindings,gpu,frame,rays,argv[1]);
        const float expected[]={.2f,.4f,.6f,1};double error=0;
        for(int k=0;k<4;++k)error=std::max(error,double(std::abs(samples[0][k]-expected[k])));
        if(error>1e-6)throw std::runtime_error("prepared material depends on destroyed CPU scene");
        if(c.CheckDebug())throw std::runtime_error("debug validation failed");
        std::cout<<"PASS D.4 procedural_scene source_cpu_destroyed=true invalid_sampler_rejected=true rgba=";
        for(float v:samples[0])std::cout<<v<<' ';std::cout<<"max_error="<<error<<'\n';
    }catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}
    CoUninitialize();return 0;
}
