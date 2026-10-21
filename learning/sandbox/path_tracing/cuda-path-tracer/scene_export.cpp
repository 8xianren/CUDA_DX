#include "scene_io.h"
#include "../dxr-path-tracer/path_scene.h"
#include <iostream>
int main(int argc,char** argv){
    if(argc!=3){std::cerr<<"cuda_scene_export input.gltf output.meshbin\n";return 2;}
    try{
        // 复用已有Assimp→CpuScene→世界三角形路径；不读取DXR BLAS内部格式，不另写glTF解析器。
        auto cpu=LoadCpuScene(argv[1]);auto world=WorldTriangles(cpu);cuda_pt::Scene result;
        auto vec=[](V v){return cuda_pt::Vec3{float(v.x),float(v.y),float(v.z)};};
        for(const auto& p:world){cuda_pt::Triangle t{};t.a=vec(p.a);t.b=vec(p.b);t.c=vec(p.c);
            t.instance=p.instance;t.primitive=p.primitive;t.material=p.material;t.id=uint32_t(result.triangles.size());result.triangles.push_back(t);}
        // 此阶段只验收几何。保存基础因子供后续教学积分，不声称导出纹理/GGX/玻璃的完整材质。
        for(const auto& m:cpu.materialAssets.materials){cuda_pt::Material t{};t.base={m.baseColor[0],m.baseColor[1],m.baseColor[2]};t.emission={m.emissive[0],m.emissive[1],m.emissive[2]};result.materials.push_back(t);}
        cuda_pt::SaveScene(argv[2],result);std::cout<<"EXPORTED world triangles="<<result.triangles.size()<<" materials="<<result.materials.size()<<" triangle_stride="<<sizeof(cuda_pt::Triangle)<<"\n";
        return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
