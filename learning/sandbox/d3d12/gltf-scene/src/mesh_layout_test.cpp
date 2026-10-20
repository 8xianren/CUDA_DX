#include "cpu_mesh.h"
#include <iostream>
#include <iomanip>
#include <stdexcept>
#include <cmath>
static void Check(bool ok,const char* message) { if(!ok) throw std::runtime_error(message); }
static void Near(float a,float b) { Check(std::abs(a-b)<1e-6f,"attribute value mismatch"); }
int main(int argc,char** argv) {
    if(argc!=3) return 2;
    try {
        // 此函数返回时 Importer 已析构。以下所有检查都访问深拷贝后的自有内存。
        auto meshes=LoadCpuMeshes(argv[1]);
        const bool defaults=std::string(argv[2])=="defaults";
        std::cout<<std::setprecision(9)<<"Vertex stride="<<sizeof(Vertex)<<" meshes="<<meshes.size()<<'\n';
        if(defaults) {
            Check(meshes.size()==2,"C.1 mesh count");
            for(const auto& m:meshes) {
                Check(!m.hasNormals&&!m.hasUV&&!m.hasColors,"missing attribute flags");
                Check(m.vertices.size()==3 && m.indices==std::vector<uint32_t>{0,1,2},"C.1 geometry counts");
                for(const auto& v:m.vertices) {
                    for(float x:v.normal) Near(x,0);
                    for(float x:v.uv) Near(x,0);
                    for(float x:v.color) Near(x,1);
                }
            }
        } else {
            Check(meshes.size()==1,"expected one mesh");
            const auto& m=meshes[0];
            Check(m.hasNormals&&m.hasUV&&m.hasColors,"attribute flags");
            Check(m.vertices.size()==3 && m.indices==std::vector<uint32_t>{0,1,2},"indices");
            const float pos[3][3]={{0,0,0},{1,0,0},{0,1,0}};
            const float uv[3][2]={{0,0.75f},{1,0.5f},{0.25f,0}};
            const float color[3][4]={{1,128.f/255,0,1},{0,1,64.f/255,1},{32.f/255,0,1,128.f/255}};
            for(unsigned i=0;i<3;++i) {
                const auto& v=m.vertices[i];
                for(int c=0;c<3;++c) { Near(v.position[c],pos[i][c]); Near(v.normal[c],c==2?1.f:0.f); }
                for(int c=0;c<2;++c) Near(v.uv[c],uv[i][c]);
                for(int c=0;c<4;++c) Near(v.color[c],color[i][c]);
                std::cout<<"v"<<i<<" position="<<v.position[0]<<','<<v.position[1]<<','<<v.position[2]
                  <<" uv="<<v.uv[0]<<','<<v.uv[1]<<" color="<<v.color[0]<<','<<v.color[1]<<','<<v.color[2]<<','<<v.color[3]<<'\n';
            }
        }
        std::cout<<"PASS: owned arrays checked after Importer destruction\n";
        return 0;
    } catch(const std::exception& e) { std::cerr<<"FAIL: "<<e.what()<<'\n'; return 1; }
}
