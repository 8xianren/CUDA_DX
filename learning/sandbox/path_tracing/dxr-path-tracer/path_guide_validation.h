#pragma once
#include "path_interop.h"
#include <fstream>
#include <iostream>
inline double RelativeDifference(float a,float b){return std::abs(double(a)-b)/(1+std::abs(double(b)));}
inline double ValidatePacket(const InteropResult& r,bool copy){
    size_t n=r.source.size();Require(r.packet.size()==6*n,"packet size");double maximum=0;
    for(size_t i=0;i<n;++i){
        const auto& p=r.source[i];const auto& c=r.packet[i];const auto& a=r.packet[n+i];const auto& v=r.packet[2*n+i];const auto& d=r.packet[3*n+i];
        Require(p.guideMode==2&&p.value.errors[0]==0&&p.value.errors[1]==0,"source guide mode/errors");
        uint32_t meta[4];memcpy(meta,&r.packet[5*n+i],16);
        Require(meta[0]==p.count&&meta[1]==p.generation&&meta[2]==0&&meta[3]==r.stamp,"CUDA packet metadata/errors/stamp");
        Require(memcmp(&c,p.value.radiance,12)==0&&memcmp(&a,p.value.albedo,16)==0&&memcmp(&v,p.value.normal,12)==0,"packing changed source fields");
        float depth=a.w>0?p.value.normal[3]/a.w:0;maximum=std::max(maximum,RelativeDifference(d.x,depth));
        Require(c.w==1&&v.w==0&&d.y==a.w,"packet channel semantics");
        if(copy)Require(memcmp(&c,&r.packet[4*n+i],16)==0,"CUDA passthrough mismatch");
    }
    Require(maximum<2e-6,"conditional depth mismatch");return maximum;
}
inline double ValidateGuidesCpu(const CpuScene& cpu,const PathConfig& cfg,const std::vector<PathHistoryPixel>& image){
    // 独立double三角形暴力参考，仅用于自编无纹理gallery的主射线特征，不复刻GPU路径积分。
    // 深度/法线按每个抖动样本求值再平均；不能拿平均射线重新求交当成期望值。
    auto triangles=WorldTriangles(cpu);auto iors=TeachingIors(cpu);double maximum=0;
    for(unsigned audit=0;audit<64;++audit){
        unsigned i=unsigned((uint64_t(audit)*15485863+137)%image.size()),x=i%cfg.width,y=i/cfg.width;
        V albedo{},normal{};double coverage=0,depth=0;
        for(unsigned sample=0;sample<image[i].count;++sample){
            double sx=((x+Random(i,sample,cfg.seed,0,0))/cfg.width*2-1)*(double(cfg.width)/cfg.height)*cfg.tanHalfFovY;
            double sy=(1-(y+Random(i,sample,cfg.seed,0,1))/cfg.height*2)*cfg.tanHalfFovY;
            V direction=ggx::Normalize(Vector(cfg.forward)+Vector(cfg.right)*sx+Vector(cfg.up)*sy);
            auto hit=Intersect(triangles,Vector(cfg.eye),direction);
            if(hit.triangle){auto& t=*hit.triangle;auto& material=cpu.materialAssets.materials[t.material];
                bool neutral=iors[t.material]>0||material.emissive[0]+material.emissive[1]+material.emissive[2]>0;
                albedo=albedo+(neutral?V{1,1,1}:Vector(material.baseColor.data()));normal=normal+t.normal;
                coverage+=1;depth+=ggx::Dot(direction*hit.distance,Vector(cfg.forward));
            }else albedo=albedo+V{1,1,1};
        }
        double scale=1./image[i].count;albedo=albedo*scale;normal=normal*scale;coverage*=scale;depth*=scale;
        double ref[8]{albedo.x,albedo.y,albedo.z,coverage,normal.x,normal.y,normal.z,depth};
        for(unsigned k=0;k<8;++k){float value=k<4?image[i].value.albedo[k]:image[i].value.normal[k-4];
            maximum=std::max(maximum,std::abs(value-ref[k])/(1+std::abs(ref[k])));}
    }
    Require(maximum<5e-4,"CPU primary guide reference mismatch");return maximum;
}
inline void SavePacket(const std::filesystem::path& folder,const std::string& name,const InteropResult& r,UINT width,UINT height){
    // PFM为线性floatRGB、little endian、底行先写。normal PFM保存有符号XYZ，不能sRGB解码。
    const char* names[]{"color","albedo","normal","depth","output"};size_t n=size_t(width)*height;
    for(unsigned plane=0;plane<5;++plane){std::ofstream file(folder/(name+"-"+names[plane]+".pfm"),std::ios::binary);
        file<<"PF\n"<<width<<' '<<height<<"\n-1.0\n";
        for(int y=int(height)-1;y>=0;--y)for(UINT x=0;x<width;++x)file.write(reinterpret_cast<const char*>(&r.packet[plane*n+size_t(y)*width+x]),12);
        Require(bool(file),"packet PFM write");}
}
