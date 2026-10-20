#include "cpu_scene.h"
#include "assimp_mesh_copy.h"
#include <assimp/Importer.hpp>
#include <assimp/scene.h>
#include <assimp/postprocess.h>
#include <stdexcept>
#include <cmath>
#include <limits>
#include <utility>

Matrix4 Multiply(const Matrix4& a,const Matrix4& b) {
    Matrix4 result; result.m.fill(0);
    // r行c列 = a第r行与b第c列点积；列向量约定中右侧矩阵先作用。
    for(int r=0;r<4;++r) for(int c=0;c<4;++c) for(int k=0;k<4;++k)
        result.m[r*4+c]+=a.m[r*4+k]*b.m[k*4+c];
    return result;
}
std::array<float,3> TransformPoint(const Matrix4& m,const float* p) {
    // 只用于本课仿射位置（w=1），不是法线变换或投影/透视除法。
    std::array<float,3> out{};
    for(int r=0;r<3;++r) out[r]=m.m[r*4]*p[0]+m.m[r*4+1]*p[1]+m.m[r*4+2]*p[2]+m.m[r*4+3];
    return out;
}
static Matrix4 CopyMatrix(const aiMatrix4x4& a) {
    Matrix4 out;
    out.m={a.a1,a.a2,a.a3,a.a4,a.b1,a.b2,a.b3,a.b4,a.c1,a.c2,a.c3,a.c4,a.d1,a.d2,a.d3,a.d4};
    for(float x:out.m) if(!std::isfinite(x)) throw std::runtime_error("nonfinite node matrix");
    return out;
}
static void Visit(const aiNode& source,int parent,CpuScene& out,unsigned depth=0) {
    // 此限制只保护我们的复制递归；Assimp已经解析过输入，不能宣传成解析器安全沙箱。
    if(depth>128) throw std::runtime_error("node depth exceeds adapter limit 128");
    if(out.nodes.size()>=static_cast<size_t>(std::numeric_limits<int>::max())) throw std::runtime_error("too many nodes");
    const auto index=static_cast<uint32_t>(out.nodes.size());
    CpuNode node; node.name=source.mName.C_Str(); node.parent=parent; node.local=CopyMatrix(source.mTransformation);
    for(unsigned i=0;i<source.mNumMeshes;++i) {
        const auto mesh=source.mMeshes[i];
        if(mesh>=out.meshes.size()) throw std::runtime_error("node mesh reference out of range");
        node.meshIndices.push_back(mesh);
        out.instances.push_back({index,mesh});
    }
    out.nodes.push_back(std::move(node));
    // 不持有 vector 元素引用跨递归：后续 push_back 可能使引用失效。
    for(unsigned i=0;i<source.mNumChildren;++i) Visit(*source.mChildren[i],static_cast<int>(index),out,depth+1);
}
void UpdateWorldMatrices(CpuScene& scene) {
    for(size_t i=0;i<scene.nodes.size();++i) {
        auto& n=scene.nodes[i];
        if(n.parent < -1 || n.parent>=static_cast<int>(i)) throw std::runtime_error("parent must precede child");
        n.world=n.parent==-1?n.local:Multiply(scene.nodes[n.parent].world,n.local);
        for(float x:n.world.m) if(!std::isfinite(x)) throw std::runtime_error("nonfinite world matrix");
    }
}
CpuScene LoadCpuScene(const std::string& path) {
    Assimp::Importer importer;
    // 不启用 PreTransformVertices，避免提前烘焙世界位置并丢失教学所需的实例关系。
    const aiScene* source=importer.ReadFile(path,aiProcess_Triangulate|aiProcess_ValidateDataStructure);
    if(!source || !source->mRootNode || (source->mFlags&AI_SCENE_FLAGS_INCOMPLETE))
        throw std::runtime_error("[read] "+path+": "+importer.GetErrorString());
    try {
    if(source->mNumAnimations) throw std::runtime_error("unsupported animation playback");
    if(!source->mNumMeshes) throw std::runtime_error("no supported mesh definitions");
    CpuScene out; out.meshes=CopyCpuMeshes(*source);
    out.materialAssets=CopyMaterialAssets(*source,path);
    for(const auto& mesh:out.meshes) {
        const auto& material=out.materialAssets.materials.at(mesh.materialIndex);
        for(const auto& binding:material.textures)
            if(binding.image>=0 && !mesh.hasUV) throw std::runtime_error("textured mesh has no UV0");
    }
    Visit(*source->mRootNode,-1,out);
    UpdateWorldMatrices(out);
    if(out.instances.empty()) throw std::runtime_error("no drawable mesh instances");
    if(source->mNumCameras) out.diagnostics.push_back("camera projection not imported; node transforms retained; use renderer camera");
    if(source->mNumLights) out.diagnostics.push_back("asset lights not imported; use explicitly configured renderer lights");
    out.diagnostics.push_back("CPU import only: encoded images not decoded; PBR/alpha/normal-map GPU behavior not validated");
    out.diagnostics.push_back("decoded-scene checks are not full glTF validation; original extensions/alignment may not survive import");
    return out; // 节点名、矩阵、引用和网格都是自有值；没有返回 Assimp 指针。
    } catch(const std::exception& e) {
        // 失败时局部vector和Importer自动释放；外部拿不到部分构造的CpuScene。
        throw std::runtime_error("[adapt] "+path+": "+e.what());
    }
}
