#include "animation.h"
#include <algorithm>
#include <cmath>
#include <functional>
#include <stdexcept>

namespace character {
static void Require(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
uint32_t Rig::ClipIndex(const std::string& name)const{
    for(uint32_t i=0;i<clips.size();++i)if(clips[i].name==name)return i;
    throw std::runtime_error("unknown clip: "+name);
}
// 已选GLB的原始sampler均LINEAR（H1独立审计记录）；不把Assimp丢失的插值模式猜成通用支持。
// 时间先映射到片段区间，再按轨道首末键夹取；不把播放速度混入仿真步长。
static Vec3 Interpolate(const Vec3& a,const Vec3& b,float u){return Lerp(a,b,u);}
static Quat Interpolate(const Quat& a,const Quat& b,float u){return Slerp(a,b,u);}
template<class T> static T At(const std::vector<AnimationKey<T>>& keys,double time,const T& fallback){
    if(keys.empty())return fallback;if(time<=keys.front().seconds)return keys.front().value;if(time>=keys.back().seconds)return keys.back().value;
    auto right=std::upper_bound(keys.begin(),keys.end(),time,[](double t,const AnimationKey<T>& k){return t<k.seconds;});
    const auto& left=*(right-1);return Interpolate(left.value,right->value,float((time-left.seconds)/(right->seconds-left.seconds)));
}
std::vector<Pose> Sample(const Rig& rig,uint32_t index,double seconds,bool loop){
    Require(index<rig.clips.size()&&std::isfinite(seconds),"invalid sample time/clip");const auto& c=rig.clips[index];
    double t=loop?std::fmod(seconds,c.duration):std::clamp(seconds,0.0,c.duration);if(t<0)t+=c.duration;
    auto poses=rig.defaults;
    for(const auto& track:c.tracks){auto& p=poses.at(track.node);
        p.translation=At(track.translation,t,p.translation);p.rotation=At(track.rotation,t,p.rotation);p.scale=At(track.scale,t,p.scale);}
    return poses;
}
std::vector<Pose> Blend(const std::vector<Pose>& a,const std::vector<Pose>& b,float alpha){
    Require(a.size()==b.size()&&std::isfinite(alpha)&&alpha>=0&&alpha<=1,"invalid blend");auto out=a;
    for(size_t i=0;i<a.size();++i){out[i].translation=Interpolate(a[i].translation,b[i].translation,alpha);
        out[i].rotation=Interpolate(a[i].rotation,b[i].rotation,alpha);out[i].scale=Interpolate(a[i].scale,b[i].scale,alpha);}
    return out;
}
std::vector<Mat4> Worlds(const Rig& rig,const std::vector<Pose>& poses){
    Require(poses.size()==rig.scene.nodes.size(),"pose/node size mismatch");std::vector<Mat4> result(poses.size());
    for(size_t i=0;i<poses.size();++i){const auto& p=poses[i];
        Mat4 local=Compose(p.scale,p.rotation,p.translation);int parent=rig.scene.nodes[i].parent;
        Require(parent<int(i),"parent must precede child");result[i]=parent<0?local:result[parent]*local;}
    return result;
}
std::vector<Mat4> Palette(const Skin& skin,const std::vector<Mat4>& world){
    auto inverse=Inverse(world.at(skin.node));
    std::vector<Mat4> out;for(const auto& j:skin.joints)out.push_back(inverse*world.at(j.node)*j.inverseBind);return out;
}
std::vector<Vertex> SkinCpu(const CpuMesh& mesh,const Skin& skin,const std::vector<Mat4>& palette){
    Require(mesh.vertices.size()==skin.influence.size(),"skin vertex count mismatch");auto out=mesh.vertices;
    for(size_t i=0;i<out.size();++i){const auto& in=mesh.vertices[i];const auto& weights=skin.influence[i];
        Vec3 p,n;for(unsigned k=0;k<4;++k){if(weights.weight[k]==0)continue;
            const auto& m=palette.at(weights.joint[k]);auto normal=Inverse(m);
            p+=Point(m,Vec3{in.position[0],in.position[1],in.position[2]})*weights.weight[k];
            n+=Normal(normal,Vec3{in.normal[0],in.normal[1],in.normal[2]})*weights.weight[k];}
        Require(n.SquareLength()>1e-12,"degenerate skinned normal");n.Normalize();
        out[i].position[0]=p.x;out[i].position[1]=p.y;out[i].position[2]=p.z;
        out[i].normal[0]=n.x;out[i].normal[1]=n.y;out[i].normal[2]=n.z;
    }
    // UV/颜色保持绑定网格值；当前Vertex没有切线，不能宣称已有法线贴图切线空间蒙皮。
    return out;
}
}
