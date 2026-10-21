#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <stdexcept>

// 模块之间只传本项目拥有的值类型。这里不包含Assimp、CUDA、Win32或D3D12头文件。
// 数学约定为列向量；Mat4按行存储。矩阵乘法顺序与内存排布分别定义。
namespace character {
struct Vec3 {
    float x=0,y=0,z=0;
    Vec3 operator+(Vec3 b)const{return{x+b.x,y+b.y,z+b.z};}
    Vec3 operator-(Vec3 b)const{return{x-b.x,y-b.y,z-b.z};}
    Vec3 operator*(float s)const{return{x*s,y*s,z*s};}
    Vec3& operator+=(Vec3 b){x+=b.x;y+=b.y;z+=b.z;return *this;}
    float SquareLength()const{return x*x+y*y+z*z;}
    Vec3& Normalize(){float length=std::sqrt(SquareLength());if(!(length>1e-12f))throw std::runtime_error("zero vector");x/=length;y/=length;z/=length;return *this;}
};
struct Quat {
    float x=0,y=0,z=0,w=1;
    Quat& Normalize(){float n=std::sqrt(x*x+y*y+z*z+w*w);if(!(n>1e-12f))throw std::runtime_error("zero quaternion");x/=n;y/=n;z/=n;w/=n;return *this;}
};
inline Vec3 Lerp(Vec3 a,Vec3 b,float u){return a+(b-a)*u;}
inline Quat Slerp(Quat a,Quat b,float u){
    a.Normalize();b.Normalize();float dot=a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w;
    // q与-q表示相同旋转，先选短弧；接近重合时避免除以极小sin(theta)。
    if(dot<0){b={-b.x,-b.y,-b.z,-b.w};dot=-dot;}
    float wa=1-u,wb=u;
    if(dot<.9995f){float theta=std::acos(std::clamp(dot,-1.f,1.f));float denominator=std::sin(theta);wa=std::sin((1-u)*theta)/denominator;wb=std::sin(u*theta)/denominator;}
    Quat q{wa*a.x+wb*b.x,wa*a.y+wb*b.y,wa*a.z+wb*b.z,wa*a.w+wb*b.w};return q.Normalize();
}
struct Mat4 {
    std::array<float,16> values{1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};
    float* operator[](size_t row){return values.data()+row*4;}
    const float* operator[](size_t row)const{return values.data()+row*4;}
};
inline Mat4 operator*(const Mat4& a,const Mat4& b){
    Mat4 out;out.values.fill(0);
    for(unsigned r=0;r<4;++r)for(unsigned c=0;c<4;++c)for(unsigned k=0;k<4;++k)out[r][c]+=a[r][k]*b[k][c];return out;
}
inline Vec3 Point(const Mat4& m,Vec3 p){return{
    m[0][0]*p.x+m[0][1]*p.y+m[0][2]*p.z+m[0][3],
    m[1][0]*p.x+m[1][1]*p.y+m[1][2]*p.z+m[1][3],
    m[2][0]*p.x+m[2][1]*p.y+m[2][2]*p.z+m[2][3]};}
inline Mat4 Compose(Vec3 scale,Quat q,Vec3 translation){
    q.Normalize();float x=q.x,y=q.y,z=q.z,w=q.w;Mat4 m;
    m[0][0]=1-2*(y*y+z*z);m[0][1]=2*(x*y-z*w);m[0][2]=2*(x*z+y*w);
    m[1][0]=2*(x*y+z*w);m[1][1]=1-2*(x*x+z*z);m[1][2]=2*(y*z-x*w);
    m[2][0]=2*(x*z-y*w);m[2][1]=2*(y*z+x*w);m[2][2]=1-2*(x*x+y*y);
    for(unsigned r=0;r<3;++r){m[r][0]*=scale.x;m[r][1]*=scale.y;m[r][2]*=scale.z;}
    m[0][3]=translation.x;m[1][3]=translation.y;m[2][3]=translation.z;return m;
}
inline Mat4 Inverse(const Mat4& m){
    // CPU小矩阵使用带选主元的Gauss-Jordan；double中间值控制误差，奇异输入显式失败。
    double a[4][8]{};for(unsigned r=0;r<4;++r){for(unsigned c=0;c<4;++c)a[r][c]=m[r][c];a[r][4+r]=1;}
    for(unsigned c=0;c<4;++c){unsigned pivot=c;for(unsigned r=c+1;r<4;++r)if(std::abs(a[r][c])>std::abs(a[pivot][c]))pivot=r;
        if(!std::isfinite(a[pivot][c])||std::abs(a[pivot][c])<1e-12)throw std::runtime_error("singular matrix");
        if(pivot!=c)for(unsigned k=0;k<8;++k)std::swap(a[c][k],a[pivot][k]);
        double factor=a[c][c];for(double& v:a[c])v/=factor;
        for(unsigned r=0;r<4;++r)if(r!=c){factor=a[r][c];for(unsigned k=0;k<8;++k)a[r][k]-=factor*a[c][k];}
    }
    Mat4 result;for(unsigned r=0;r<4;++r)for(unsigned c=0;c<4;++c)result[r][c]=float(a[r][c+4]);return result;
}
inline Vec3 Normal(const Mat4& inverse,Vec3 n){return{
    inverse[0][0]*n.x+inverse[1][0]*n.y+inverse[2][0]*n.z,
    inverse[0][1]*n.x+inverse[1][1]*n.y+inverse[2][1]*n.z,
    inverse[0][2]*n.x+inverse[1][2]*n.y+inverse[2][2]*n.z};}
}
