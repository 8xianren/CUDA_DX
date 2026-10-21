#include "material_sampling.h"
#include <cmath>
#include <algorithm>
#include <fstream>
#include <iostream>
#include <stdexcept>
namespace {
void Require(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
double Decode(double x){return x<=.04045?x/12.92:std::pow((x+.055)/1.055,2.4);}
double Encode(double x){return x<=.0031308?12.92*x:1.055*std::pow(x,1/2.4)-.055;}
int Address(int i,int n,int wrap){
    if(wrap==33071)return std::clamp(i,0,n-1);
    int period=wrap==33648?2*n:n;i=(i%period+period)%period;
    return i<n?i:2*n-1-i;
}
// 独立CPU参考：逐texel解码RGB，再双线性；alpha只UNORM，不走sRGB。
// 对整数邻居寻址，repeat接缝才能跨图像两端过滤。CPU用double计算权重。
LinearRGBA Sample(const Pixels& p,double u,double v,const TextureBinding& binding,bool wrongSRGB=false){
    const bool linear=binding.magFilter!=9728;
    double x=u*p.width-.5,y=v*p.height-.5;int ix=int(std::floor(x)),iy=int(std::floor(y));
    double fx=x-ix,fy=y-iy;LinearRGBA out{};
    if(!linear){ix=int(std::floor(u*p.width));iy=int(std::floor(v*p.height));fx=fy=0;}
    for(int dy=0;dy<(linear?2:1);++dy)for(int dx=0;dx<(linear?2:1);++dx){
        const int sx=Address(ix+dx,p.width,binding.wrapU),sy=Address(iy+dy,p.height,binding.wrapV);
        const double weight=linear?(dx?fx:1-fx)*(dy?fy:1-fy):1;
        for(int k=0;k<4;++k){double value=p.rgba[(size_t(sy)*p.width+sx)*4+k]/255.;
            if(k<3&&binding.srgbRGB&&!wrongSRGB)value=Decode(value);out[k]+=float(value*weight);}
    }
    return out;
}
struct Expected {LinearRGBA value,flipped,encoded;unsigned pixel;};
void Run(CpuScene cpu,const std::filesystem::path& dxil,const std::filesystem::path& out,const std::string& name,int wrap,int filter,bool fixture){
    for(auto& m:cpu.materialAssets.materials){m.textures[0].wrapU=wrap;m.textures[0].wrapV=wrap;
        m.textures[0].minFilter=m.textures[0].magFilter=filter;}
    if(fixture){
        // 已知源glTF v=-.75，Assimp应输出1.75；防止CPU/GPU一起翻错却通过对照。
        Require(std::abs(cpu.meshes[0].vertices[0].uv[1]-1.75f)<1e-6,"Assimp V convention changed");
        // 非恒定线性顶点色测试重心插值，修改只在本次CPU诊断副本，不改源资产。
        for(auto& mesh:cpu.meshes)for(size_t i=0;i<mesh.vertices.size();++i){mesh.vertices[i].color[0]=.25f+.25f*float(i%3);mesh.vertices[i].color[3]=.5f;}
    }
    UploadContext c;auto gpu=UploadScene(c,cpu);auto blases=BuildMeshBlases(c,gpu);
    c.SubmitWait();gpu.staging.clear();for(auto& b:blases)b.scratch.Reset();
    auto frame=BuildInstanceFrame(c,cpu,gpu,blases,false);
    auto bindings=PrepareMaterialBindings(c,cpu,gpu); // 两次采样复用同一份准备结果。
    std::vector<MaterialRay> rays;std::vector<Expected> expected;
    unsigned triangleCount=0;for(auto instance:cpu.instances)triangleCount+=UINT(cpu.meshes[instance.meshIndex].indices.size()/3);
    const unsigned width=triangleCount*32,height=32;unsigned tile=0;
    for(auto instance:cpu.instances){const auto& mesh=cpu.meshes[instance.meshIndex];const auto& matrix=cpu.nodes[instance.nodeIndex].world;
        Require(mesh.hasUV,"textured test requires UV0");const auto& material=cpu.materialAssets.materials.at(mesh.materialIndex);const auto& binding=material.textures[0];
        const auto& image=gpu.images.at(binding.image<0?gpu.images.size()-1:size_t(binding.image)).reference;
        for(size_t t=0;t<mesh.indices.size();t+=3,++tile){
            const Vertex* vertex[3]={&mesh.vertices[mesh.indices[t]],&mesh.vertices[mesh.indices[t+1]],&mesh.vertices[mesh.indices[t+2]]};
            std::array<float,3> p[3];for(int j=0;j<3;++j)p[j]=TransformPoint(matrix,vertex[j]->position);
            double e[3],f[3],normal[3];for(int k=0;k<3;++k){e[k]=p[1][k]-p[0][k];f[k]=p[2][k]-p[0][k];}
            normal[0]=e[1]*f[2]-e[2]*f[1];normal[1]=e[2]*f[0]-e[0]*f[2];normal[2]=e[0]*f[1]-e[1]*f[0];
            double len=std::sqrt(normal[0]*normal[0]+normal[1]*normal[1]+normal[2]*normal[2]);Require(len>1e-8,"degenerate triangle");
            for(double& n:normal)n/=len;
            for(unsigned y=0;y<31;++y)for(unsigned x=0;x+y<31;++x){
                // 二进制精确的内点重心权重，避开几何共享边。短射线从三角形上方射回表面。
                double w[]={1-(x+.3125+y+.5625)/32,(x+.3125)/32,(y+.5625)/32};
                MaterialRay ray{};ray.tmax=.02f;double u=0,v=0;LinearRGBA color{};
                for(int k=0;k<3;++k){double position=0;for(int j=0;j<3;++j)position+=w[j]*p[j][k];
                    ray.origin[k]=float(position+.01*normal[k]);ray.direction[k]=float(-normal[k]);}
                for(int j=0;j<3;++j){u+=w[j]*vertex[j]->uv[0];v+=w[j]*vertex[j]->uv[1];for(int k=0;k<4;++k)color[k]+=float(w[j]*vertex[j]->color[k]);}
                Expected ref{Sample(image,u,1-v,binding),Sample(image,u,v,binding),Sample(image,u,1-v,binding,true),y*width+tile*32+x};
                for(int k=0;k<4;++k){float factor=material.baseColor[k]*color[k];ref.value[k]*=factor;ref.flipped[k]*=factor;ref.encoded[k]*=factor;}
                rays.push_back(ray);expected.push_back(ref);
            }
        }
    }
    auto actual=SampleHitMaterials(c,bindings,gpu,frame,rays,dxil);double maximum=0;unsigned errors=0,flipDetected=0,srgbDetected=0;
    std::vector<uint8_t> preview(size_t(width)*height*3,24);
    std::ofstream csv(out/(name+".csv"));csv<<"sample,r,g,b,a,ref_r,ref_g,ref_b,ref_a\n";
    for(size_t i=0;i<actual.size();++i){
        double error=0,flip=0,encoded=0;
        for(int k=0;k<4;++k){Require(std::isfinite(actual[i][k]),"nonfinite sample");error=std::max(error,double(std::abs(actual[i][k]-expected[i].value[k])));
            flip=std::max(flip,double(std::abs(actual[i][k]-expected[i].flipped[k])));encoded=std::max(encoded,double(std::abs(actual[i][k]-expected[i].encoded[k])));}
        maximum=std::max(maximum,error);errors+=error>.006;flipDetected+=flip>.03;srgbDetected+=encoded>.03;
        csv<<i;for(float v:actual[i])csv<<','<<v;for(float v:expected[i].value)csv<<','<<v;csv<<'\n';
        for(int k=0;k<3;++k)preview[size_t(expected[i].pixel)*3+k]=uint8_t(std::lround(255*std::clamp(Encode(std::max(0.f,actual[i][k])),0.,1.)));
    }
    std::ofstream ppm(out/(name+".ppm"),std::ios::binary);ppm<<"P6\n"<<width<<' '<<height<<"\n255\n";ppm.write(reinterpret_cast<char*>(preview.data()),preview.size());
    std::cout<<name<<" samples="<<rays.size()<<" max_error="<<maximum<<" errors="<<errors<<" wrong_v_detected="<<flipDetected<<" wrong_srgb_detected="<<srgbDetected<<"\n";
    Require(errors==0,"material sample mismatch");Require(flipDetected>0&&srgbDetected>0,"negative controls did not distinguish errors");
    if(!fixture&&wrap==10497&&filter==9729){
        // 官方BoxTextured的固定正面正交预览。数值验收仍以上述逐三角形参考为准；
        // 本图补充肉眼检查方向，不将预览本身冒充完整逐像素参考或光照渲染。
        std::vector<MaterialRay> cameraRays;
        for(int y=0;y<128;++y)for(int x=0;x<128;++x)
            cameraRays.push_back({{float((x+.5)/128-.5),float(.5-(y+.5)/128),2},0,{0,0,-1},4});
        auto image=SampleHitMaterials(c,bindings,gpu,frame,cameraRays,dxil);
        std::ofstream face(out/"box-front.ppm",std::ios::binary);face<<"P6\n128 128\n255\n";
        for(const auto& pixel:image)for(int k=0;k<3;++k){
            auto byte=uint8_t(std::lround(255*std::clamp(Encode(std::max(0.f,pixel[k])),0.,1.)));
            face.write(reinterpret_cast<char*>(&byte),1);
        }
    }
    Require(c.CheckDebug()==0,"GPU validation failed");
}
}
int main(int argc,char** argv){
    if(argc!=5){std::cerr<<"usage: material_sampling_test scene.gltf shader.dxil output-dir fixture|official\n";return 2;}
    HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    try{Check(com,"COM");std::filesystem::path out=argv[3];std::filesystem::create_directories(out);auto cpu=LoadCpuScene(argv[1]);
        const bool fixture=std::string(argv[4])=="fixture";
        for(int wrap:{10497,33071,33648})for(int filter:{9728,9729})Run(cpu,argv[2],out,std::to_string(wrap)+"-"+std::to_string(filter),wrap,filter,fixture);
        std::cout<<"PASS D.3 six sampler variants, linear RGBA, UV and sRGB negative controls\n";
    }catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<'\n';if(SUCCEEDED(com))CoUninitialize();return 1;}
    CoUninitialize();return 0;
}

