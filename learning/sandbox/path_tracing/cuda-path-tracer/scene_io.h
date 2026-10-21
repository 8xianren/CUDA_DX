#pragma once
#include "geometry.h"
#include <vector>
#include <filesystem>
#include <fstream>
#include <stdexcept>
namespace cuda_pt {
inline void Require(bool condition,const char* what){if(!condition)throw std::runtime_error(what);}
struct Scene {std::vector<Triangle> triangles;std::vector<Material> materials;};
struct SceneHeader {uint32_t magic=0x39545043,version=1,triangles=0,materials=0;};
inline void ValidateScene(const Scene& scene){
    Require(scene.triangles.size()<=1048576&&scene.materials.size()<=65536,"scene count limits");
    for(size_t i=0;i<scene.triangles.size();++i){const auto& t=scene.triangles[i];
        Require(t.id==i&&t.material<scene.materials.size(),"triangle identity/material range");
        for(Vec3 p:{t.a,t.b,t.c})Require(Finite(p)&&fabsf(p.x)<=1e6f&&fabsf(p.y)<=1e6f&&fabsf(p.z)<=1e6f,"finite supported coordinate range");}
    for(auto& m:scene.materials)Require(Finite(m.base)&&Finite(m.emission),"finite material factors");
}
inline Scene LoadScene(const std::filesystem::path& path){
    std::ifstream f(path,std::ios::binary);SceneHeader h;Require(bool(f.read(reinterpret_cast<char*>(&h),sizeof(h))),"scene header read");
    Require(h.magic==0x39545043&&h.version==1&&h.triangles<=1048576&&h.materials<=65536,"scene header/version/count");
    Scene s;s.triangles.resize(h.triangles);s.materials.resize(h.materials);
    Require(bool(f.read(reinterpret_cast<char*>(s.triangles.data()),s.triangles.size()*sizeof(Triangle))),"triangle payload read");
    Require(bool(f.read(reinterpret_cast<char*>(s.materials.data()),s.materials.size()*sizeof(Material))),"material payload read");
    Require(f.peek()==std::char_traits<char>::eof(),"unexpected scene trailing bytes");ValidateScene(s);return s;
}
inline void SaveScene(const std::filesystem::path& path,const Scene& scene){
    ValidateScene(scene);std::filesystem::create_directories(path.parent_path());std::ofstream f(path,std::ios::binary);
    SceneHeader h;h.triangles=uint32_t(scene.triangles.size());h.materials=uint32_t(scene.materials.size());
    f.write(reinterpret_cast<const char*>(&h),sizeof(h));f.write(reinterpret_cast<const char*>(scene.triangles.data()),scene.triangles.size()*sizeof(Triangle));
    f.write(reinterpret_cast<const char*>(scene.materials.data()),scene.materials.size()*sizeof(Material));Require(bool(f),"scene write");
}
inline void ValidateRay(const Ray& r){Require(Finite(r.origin)&&Finite(r.direction)&&Dot(r.direction,r.direction)>0&&Finite(r.tmin)&&Finite(r.tmax)&&r.tmin>=0&&r.tmax>=r.tmin,"invalid finite ray interval/direction");}
}
