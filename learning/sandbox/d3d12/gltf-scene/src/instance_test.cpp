#include "gpu_instances.h"
#include <fstream>
#include <iostream>
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <algorithm>
static void Require(bool condition,const char* message){if(!condition)throw std::runtime_error(message);}
static HitIds Reference(const CpuScene& cpu,const InstanceCamera& camera,unsigned x,unsigned y,bool hideFirst,bool& edge) {
    // 独立平面三角形参考：测试资产所有顶点在world z=0，解二维重心坐标。
    // 不读取TLAS Transform或GPU对象表，以便发现它们的打包/编号错误。
    const double px=(2*(x+.5)/camera.width-1)*7+camera.inverseViewProjection.m[3];
    const double py=(1-2*(y+.5)/camera.height)*8+1;
    HitIds result{};edge=false;
    for(size_t i=0;i<cpu.instances.size();++i) {
        if(hideFirst&&i==0) continue;
        const auto& instance=cpu.instances[i];const auto& mesh=cpu.meshes[instance.meshIndex];const auto& world=cpu.nodes[instance.nodeIndex].world;
        for(size_t t=0;t<mesh.indices.size();t+=3) {
            std::array<float,3> p[3];
            for(int v=0;v<3;++v){p[v]=TransformPoint(world,mesh.vertices[mesh.indices[t+v]].position);Require(std::abs(p[v][2])<1e-6,"reference requires z=0");}
            double ax=p[0][0],ay=p[0][1],bx=p[1][0],by=p[1][1],cx=p[2][0],cy=p[2][1];
            double den=(by-cy)*(ax-cx)+(cx-bx)*(ay-cy);
            Require(std::abs(den)>1e-12,"degenerate test triangle");
            double a=((by-cy)*(px-cx)+(cx-bx)*(py-cy))/den;
            double b=((cy-ay)*(px-cx)+(ax-cx)*(py-cy))/den,cc=1-a-b;
            // 光栅有subpixel量化/top-left规则，DXR三角形共享边归属可能不同；边带明确排除，不吞内点错误。
            constexpr double tolerance=0.0002;
            if(a>=-tolerance&&b>=-tolerance&&cc>=-tolerance&&(a<tolerance||b<tolerance||cc<tolerance))edge=true;
            if(a>=0&&b>=0&&cc>=0) result={UINT(i+1),mesh.materialIndex+1,UINT(t/3+1),0};
        }
    }
    return result;
}
static void Save(const std::filesystem::path& path,const std::vector<HitIds>& ids,const InstanceCamera& camera) {
    // 仅把整数诊断ID映射到固定颜色，无光照、曝光或tone mapping；BMP记录GPU实际命中覆盖。
    BITMAPFILEHEADER file{};BITMAPINFOHEADER info{};file.bfType=0x4d42;file.bfOffBits=sizeof(file)+sizeof(info);file.bfSize=file.bfOffBits+camera.width*camera.height*4;
    info.biSize=sizeof(info);info.biWidth=camera.width;info.biHeight=-LONG(camera.height);info.biPlanes=1;info.biBitCount=32;
    std::ofstream out(path,std::ios::binary);out.write(reinterpret_cast<char*>(&file),sizeof(file));out.write(reinterpret_cast<char*>(&info),sizeof(info));
    const uint8_t palette[][3]={{0,0,0},{230,80,70},{70,140,240},{240,170,70},{100,210,220}};
    for(auto id:ids){auto color=palette[id[0]%5];uint8_t bgra[]={color[2],color[1],color[0],255};out.write(reinterpret_cast<char*>(bgra),4);}
    Require(bool(out),"write preview failed");
}
int main(int argc,char** argv) {
    if(argc!=5){std::cerr<<"usage: instance_test scene.gltf raster.hlsl rays.dxil output-dir\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    try {
        Check(com,"COM");auto cpu=LoadCpuScene(argv[1]);Require(cpu.meshes.size()==2&&cpu.instances.size()==4,"expected 2 primitives shared by 2 nodes");
        int parent=-1;for(size_t i=0;i<cpu.nodes.size();++i)if(cpu.nodes[i].name=="Group")parent=int(i);
        Require(parent>=0,"Group node missing");
        std::filesystem::path output=argv[4];std::filesystem::create_directories(output);
        UploadContext context;auto gpu=UploadScene(context,cpu);auto blases=BuildMeshBlases(context,gpu);
        context.SubmitWait();gpu.staging.clear();for(auto& blas:blases)blas.scratch.Reset();
        // 缓存地址和顶点，后续只改实例。BLAS不是按node复制；运行所有阶段期间保持result存活。
        const auto vb=gpu.vertices->GetGPUVirtualAddress(),ib=gpu.indices->GetGPUVirtualAddress();
        std::vector<D3D12_GPU_VIRTUAL_ADDRESS> addresses;for(const auto& blas:blases)addresses.push_back(blas.result->GetGPUVirtualAddress());
        std::vector<HitIds> baseline,previous;
        for(int stage=0;stage<4;++stage) {
            const char* name[]={"base","parent-moved","masked","camera-pan"};
            if(stage==1)cpu.nodes[parent].local.m[3]+=3;
            UpdateWorldMatrices(cpu);bool hide=stage==2;auto camera=MakeInstanceCamera(stage==3?.37f:0.f);
            auto frame=BuildInstanceFrame(context,cpu,gpu,blases,hide);
            // 针对本课fixture的独立已知答案：T(10,1)*Rz90*S(2,3)作用到子节点Tx±2。
            for(const auto& record:frame.records){
                const auto& node=cpu.nodes[record.node];const float y=node.name=="Left"?-3.f:5.f;
                Require(std::abs(record.world.m[3]-(stage?13.f:10.f))<1e-5f && std::abs(record.world.m[7]-y)<1e-5f,"known hierarchy anchor failed");
                Require(frame.descriptors[&record-frame.records.data()].AccelerationStructure==addresses[record.mesh],"BLAS not shared");
            }
            auto images=RenderInstances(context,gpu,frame,camera,argv[2],argv[3]);
            size_t checked=0,edges=0,mismatch=0,hits=0,changed=0;size_t perInstance[4]{};
            for(unsigned y=0;y<camera.height;++y)for(unsigned x=0;x<camera.width;++x) {
                size_t k=size_t(y)*camera.width+x;bool edge=false;auto expected=Reference(cpu,camera,x,y,hide,edge);
                if(edge){++edges;continue;}++checked;
                if(images.ray[k]!=expected||images.raster[k]!=expected)++mismatch;
                if(expected[0]){++hits;++perInstance[expected[0]-1];}
                // camera-pan与同样可见性/物体位置的parent-moved比较，单独验证相机影响。
                const auto& comparison=stage==3?baseline:previous;
                if(!comparison.empty()&&images.ray[k]!=comparison[k])++changed;
            }
            Require(gpu.vertices->GetGPUVirtualAddress()==vb&&gpu.indices->GetGPUVirtualAddress()==ib,"mesh buffers changed");
            size_t offset=0;for(const auto& mesh:cpu.meshes){Require(memcmp(mesh.vertices.data(),gpu.referenceVertices.data()+offset,mesh.vertices.size()*sizeof(Vertex))==0,"local vertices changed");offset+=mesh.vertices.size();}
            std::cout<<"stage="<<name[stage]<<" rays="<<images.ray.size()<<" checked="<<checked<<" edge_excluded="<<edges
                     <<" mismatch="<<mismatch<<" hits="<<hits<<" changed="<<changed<<"\n";
            Require(mismatch==0&&hits>0,"CPU/raster/DXR identity mismatch");
            for(size_t i=0;i<4;++i)Require((hide&&i==0)?perInstance[i]==0:perInstance[i]>0,"instance coverage missing");
            if(stage)Require(changed>0,"expected image change missing");
            Save(output/(std::string(name[stage])+"-ray.bmp"),images.ray,camera);Save(output/(std::string(name[stage])+"-raster.bmp"),images.raster,camera);
            if(stage==1)baseline=images.ray;
            previous=images.ray;
        }
        // 失败路径：实例矩阵不可逆时应在提交TLAS前拒绝，不能以崩溃代替报错。
        auto invalid=cpu;auto& m=invalid.nodes[invalid.instances[0].nodeIndex].world.m;m[0]=m[1]=m[2]=0;
        bool rejected=false;try{auto bad=BuildInstanceFrame(context,invalid,gpu,blases,false);}catch(const std::runtime_error& e){rejected=std::string(e.what())=="singular world transform";}
        Require(rejected,"singular transform not rejected");
        Require(context.CheckDebug()==0,"GPU validation error");
        std::cout<<"PASS D.2 mesh_definitions=2 BLAS_builds=2 TLAS_instances=4 stages=4 singular_rejected=true shared_geometry_unchanged=true\n";
    }catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<"\n";if(SUCCEEDED(com))CoUninitialize();return 1;}
    CoUninitialize();return 0;
}
