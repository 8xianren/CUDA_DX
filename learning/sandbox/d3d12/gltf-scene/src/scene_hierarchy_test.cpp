#include "cpu_scene.h"
#include <iostream>
#include <cmath>
#include <stdexcept>
#include <algorithm>
static void Check(bool c,const char* text) {if(!c) throw std::runtime_error(text);}
static float error=0;
static void Near(float a,float b) { error=std::max(error,std::abs(a-b)); Check(std::abs(a-b)<1e-5f,"world position mismatch"); }
int main(int argc,char** argv) {
    if(argc!=3) return 2;
    try {
        auto scene=LoadCpuScene(argv[1]); // 此后Importer已析构。
        if(std::string(argv[2])=="topology") {
            Check(scene.meshes.size()==1 && scene.instances.size()==2,"topology counts");
            const auto& mesh=scene.meshes[0]; Check(mesh.indices.size()==6,"two triangles required");
            float area=0;
            for(size_t i=0;i<6;i+=3) {
                const auto* a=mesh.vertices.at(mesh.indices[i]).position;
                const auto* b=mesh.vertices.at(mesh.indices[i+1]).position;
                const auto* c=mesh.vertices.at(mesh.indices[i+2]).position;
                float twice=(b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0]);
                Check(twice>0,"winding changed"); area+=twice*0.5f;
            }
            Near(area,1); std::cout<<"triangles=2 positive winding area="<<area<<'\n';
        } else {
            Check(scene.meshes.size()==2 && scene.instances.size()==4,"shared mesh counts");
            int group=-1;
            for(size_t i=0;i<scene.nodes.size();++i) if(scene.nodes[i].name=="Group") group=static_cast<int>(i);
            Check(group>=0,"group missing");
            auto original=scene.meshes; // 独立保留局部顶点，检查更新没有烘焙/改写几何。
            const auto verify=[&](float tx) {
                for(const auto& instance:scene.instances) {
                    const auto& node=scene.nodes[instance.nodeIndex];
                    Check(node.name=="Left"||node.name=="Right","unexpected mesh node");
                    Check(node.meshIndices==std::vector<uint32_t>{0,1},"shared references changed");
                    const float childX=node.name=="Left"?-2.f:2.f;
                    const auto& mesh=scene.meshes[instance.meshIndex];
                    for(size_t v=0;v<mesh.vertices.size();++v) {
                        const auto* p=mesh.vertices[v].position;
                        auto world=TransformPoint(node.world,p);
                        // 独立标量参考：先子平移，再父S(2,3,1)，Rz90，最后父T(tx,1,0)。
                        Near(world[0],tx-3*p[1]); Near(world[1],1+2*(p[0]+childX)); Near(world[2],p[2]);
                        for(int c=0;c<3;++c) Near(p[c],original[instance.meshIndex].vertices[v].position[c]);
                    }
                    float origin[3]{}; auto center=TransformPoint(node.world,origin);
                    std::cout<<node.name<<" mesh="<<instance.meshIndex<<" origin="<<center[0]<<','<<center[1]<<','<<center[2]<<'\n';
                }
            };
            verify(10);
            // Group父节点为导入器合成的单位根，改局部X平移也就是沿世界X移动。
            scene.nodes[group].local.m[3]+=10;
            UpdateWorldMatrices(scene);
            verify(20);
        }
        std::cout<<"PASS nodes="<<scene.nodes.size()<<" meshes="<<scene.meshes.size()<<" instances="<<scene.instances.size()<<" maxError="<<error<<'\n';
        return 0;
    } catch(const std::exception& e) {std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
}
