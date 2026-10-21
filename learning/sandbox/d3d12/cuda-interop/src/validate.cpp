#include "validate.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>

std::vector<SharedInstance> Expected(const CpuScene& s,unsigned f){
    std::vector<SharedInstance> out;
    for(size_t i=0;i<s.instances.size();++i){
        // CPU参考通过通用矩阵乘法构造T*M，独立于kernel对两个元素的快捷修改。
        Matrix4 translation;translation.m[3]=float(int(f%9)-4)/8.f*((i%2)?-1.f:1.f);
        translation.m[7]=float(int((f+i)%5)-2)/16.f;
        auto world=Multiply(translation,s.nodes.at(s.instances[i].nodeIndex).world);
        SharedInstance v{};memcpy(v.world,world.m.data(),64);
        v.color[0]=float(i+1)/8;v.color[1]=float(f%8+1)/8;v.color[2]=float(8-i)/8;v.color[3]=float(f+1);out.push_back(v);
    }
    return out;
}
PixelAudit AuditPixels(const CpuScene& s,const InstanceCamera& camera,const std::vector<SharedInstance>& records,const std::vector<float>& pixels){
    struct Triangle {double p[3][2];unsigned object;};std::vector<Triangle> triangles;
    for(unsigned i=0;i<s.instances.size();++i){
        const auto& mesh=s.meshes.at(s.instances[i].meshIndex);Matrix4 world;memcpy(world.m.data(),records[i].world,64);
        for(size_t t=0;t<mesh.indices.size();t+=3){
            Triangle tri{};tri.object=i;
            for(unsigned v=0;v<3;++v){auto p=TransformPoint(world,mesh.vertices.at(mesh.indices[t+v]).position);
                // 当前固定正交相机在世界x=[4,18], y=[-7,9]，像素中心(x+.5,y+.5)。
                // 不复用shader的P*V乘法，因此可检出矩阵转置/绑定错误。
                tri.p[v][0]=(double(p[0])-4)/14*camera.width;
                tri.p[v][1]=(9-double(p[1]))/16*camera.height;
            }triangles.push_back(tri);
        }
    }
    PixelAudit out;
    for(unsigned y=0;y<camera.height;++y)for(unsigned x=0;x<camera.width;++x){
        int hit=-1;bool edge=false;double px=x+.5,py=y+.5;
        for(const auto& t:triangles){
            double ax=t.p[1][0]-t.p[0][0],ay=t.p[1][1]-t.p[0][1],bx=t.p[2][0]-t.p[0][0],by=t.p[2][1]-t.p[0][1];
            double det=ax*by-ay*bx;if(std::abs(det)<1e-12)continue;
            double dx=px-t.p[0][0],dy=py-t.p[0][1],u=(dx*by-dy*bx)/det,v=(ax*dy-ay*dx)/det,w=1-u-v;
            // 光栅顶点量化/top-left边界不同于实数重心。仅排除三角形附近的窄边带，不排除内部错误。
            constexpr double eps=.001;
            if(u>=-eps && v>=-eps && w>=-eps && std::min({u,v,w})<=eps)edge=true;
            if(u>=0&&v>=0&&w>=0)hit=int(t.object);
        }
        if(edge){++out.edges;continue;}++out.checked;if(hit>=0)++out.covered;
        bool bad=false;for(unsigned k=0;k<4;++k){float expected=hit<0?0:records[hit].color[k];
            float actual=pixels[(size_t(y)*camera.width+x)*4+k];if(!std::isfinite(actual)||std::abs(actual-expected)>1e-6f)bad=true;}
        if(bad)++out.mismatch;
    }return out;
}
void SaveImage(const std::filesystem::path& path,unsigned w,unsigned h,const std::vector<float>& pixels){
    // 诊断图直接把RGB数值量化，不是完整sRGB显示管线；alpha帧号不用于图像透明度。
    std::ofstream f(path,std::ios::binary);uint8_t header[54]{};header[0]='B';header[1]='M';
    auto put=[&](unsigned offset,uint32_t value){memcpy(header+offset,&value,4);};
    put(2,54+w*h*4);put(10,54);put(14,40);put(18,w);put(22,h);header[26]=1;header[28]=32;f.write(reinterpret_cast<char*>(header),54);
    for(unsigned y=h;y-->0;)for(unsigned x=0;x<w;++x){uint8_t bgra[4];
        for(unsigned c=0;c<3;++c)bgra[2-c]=uint8_t(std::clamp(pixels[(size_t(y)*w+x)*4+c],0.f,1.f)*255+.5f);
        bgra[3]=255;f.write(reinterpret_cast<char*>(bgra),4);}
    if(!f)throw std::runtime_error("image write failed");
}
