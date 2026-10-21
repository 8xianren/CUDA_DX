#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <vector>

// GPU与CPU共享的逻辑格式：float头4个，按roughness行排列的E，再放每行Eavg。
// 仅包含F0=.04、各向同性单次GGX/高度相关Smith/Schlick的方向反照率，不能换模型后沿用旧表。
namespace pbr_energy {
constexpr unsigned Rows=129,Columns=257,Header=4,AverageOffset=Header+Rows*Columns;
constexpr float MinAlpha=1e-4f;
inline double Cosine(unsigned j){double u=double(j)/(Columns-1);return u*u*u*u;}
inline double Alpha(unsigned i){return 1e-4*std::pow(1e4,double(i)/(Rows-1));}
struct Table {
    std::vector<float> data;
    void Validate()const{
        if(data.size()!=AverageOffset+Rows||data[0]!=Rows||data[1]!=Columns||data[2]!=MinAlpha||data[3]!=AverageOffset)
            throw std::runtime_error("energy LUT layout/version mismatch");
        for(size_t i=Header;i<data.size();++i)if(!std::isfinite(data[i])||data[i]<0||data[i]>1)
            throw std::runtime_error("energy LUT invalid value");
        for(unsigned i=0;i<Rows;++i){
            if(data[AverageOffset+i]>=1)throw std::runtime_error("energy LUT singular average");
            double average=0;
            for(unsigned j=0;j+1<Columns;++j){double c=Cosine(j),h=Cosine(j+1)-c,e=data[Header+i*Columns+j],d=data[Header+i*Columns+j+1]-e;
                average+=2*h*(e*c+(e*h+d*c)/2+d*h/3);}
            if(std::abs(average-data[AverageOffset+i])>2e-7)throw std::runtime_error("energy LUT average mismatch");
        }
    }
    // r轴在log(alpha)上线性插值；c轴用四次方节点，但区间内仍在真实c上线性插值。
    // 两轴采用相同r权重查E和Eavg，保证积分平均与实际插值函数一致（float舍入除外）。
    void RowIndex(double roughness,unsigned& i,double& t)const{
        double x=std::clamp(std::log2(roughness*roughness/1e-4)/std::log2(1e4)*(Rows-1),0.,double(Rows-1));
        i=std::min(unsigned(x),Rows-2);t=x-i;
    }
    double At(double roughness,double cosine)const{
        if(roughness*roughness<=1e-4)return .04+.96*std::pow(1-cosine,5);
        unsigned i;double tr;RowIndex(roughness,i,tr);
        double x=std::sqrt(std::sqrt(std::clamp(cosine,0.,1.)))*(Columns-1);
        unsigned j=std::min(unsigned(x),Columns-2);double tc=(cosine-Cosine(j))/(Cosine(j+1)-Cosine(j));
        auto row=[&](unsigned k){size_t n=Header+k*Columns+j;return data[n]*(1-tc)+data[n+1]*tc;};
        return row(i)*(1-tr)+row(i+1)*tr;
    }
    double Average(double roughness)const{
        if(roughness*roughness<=1e-4)return 3./35;
        unsigned i;double t;RowIndex(roughness,i,t);return data[AverageOffset+i]*(1-t)+data[AverageOffset+i+1]*t;
    }
};
inline Table Load(const std::filesystem::path& path){
    std::ifstream file(path,std::ios::binary|std::ios::ate);if(!file)throw std::runtime_error("missing energy LUT");
    auto bytes=file.tellg();if(bytes!=std::streamoff((AverageOffset+Rows)*sizeof(float)))throw std::runtime_error("energy LUT file size");
    Table table;table.data.resize(AverageOffset+Rows);file.seekg(0);file.read(reinterpret_cast<char*>(table.data.data()),bytes);
    if(!file)throw std::runtime_error("energy LUT read failed");table.Validate();return table;
}
}
