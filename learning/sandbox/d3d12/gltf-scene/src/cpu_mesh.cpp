#include "cpu_mesh.h"
#include "assimp_mesh_copy.h"
#include <assimp/Importer.hpp>
#include <assimp/scene.h>
#include <assimp/postprocess.h>
#include <cmath>
#include <stdexcept>
#include <utility>

std::vector<CpuMesh> LoadCpuMeshes(const std::string& path) {
    Assimp::Importer importer;
    // 不使用 FlipUVs：本适配层保留 Assimp 的统一 UV 约定。
    // glTF2Importer 自身会将源 v 转为 1-v，不能误以为禁用 FlipUVs 就等于原 glTF UV。
    const aiScene* scene=importer.ReadFile(path,aiProcess_Triangulate|aiProcess_ValidateDataStructure);
    if(!scene || !scene->mRootNode || (scene->mFlags&AI_SCENE_FLAGS_INCOMPLETE))
        throw std::runtime_error(path+": "+importer.GetErrorString());
    return CopyCpuMeshes(*scene);
}

std::vector<CpuMesh> CopyCpuMeshes(const aiScene& input) {
    const aiScene* scene=&input;
    std::vector<CpuMesh> result;
    result.reserve(scene->mNumMeshes);
    for(unsigned k=0;k<scene->mNumMeshes;++k) {
        const aiMesh& source=*scene->mMeshes[k];
        // 骨骼和Morph需要改变顶点；不能悄悄丢弃后按静态网格报告“导入成功”。
        if(source.HasBones()) throw std::runtime_error("unsupported skinning at mesh "+std::to_string(k));
        if(source.mNumAnimMeshes) throw std::runtime_error("unsupported morph targets at mesh "+std::to_string(k));
        if(!source.HasPositions() || source.mMaterialIndex>=scene->mNumMaterials)
            throw std::runtime_error("missing positions or invalid material index");
        CpuMesh mesh;
        mesh.materialIndex=source.mMaterialIndex;
        mesh.hasNormals=source.HasNormals();
        mesh.hasUV=source.HasTextureCoords(0);
        mesh.hasColors=source.HasVertexColors(0);
        if(mesh.hasUV && source.mNumUVComponents[0]!=2)
            throw std::runtime_error("this lesson requires 2D UV0");
        mesh.vertices.resize(source.mNumVertices);
        for(unsigned i=0;i<source.mNumVertices;++i) {
            Vertex& v=mesh.vertices[i];
            const auto& p=source.mVertices[i];
            v.position[0]=p.x; v.position[1]=p.y; v.position[2]=p.z;
            if(mesh.hasNormals) {
                const auto& n=source.mNormals[i];
                v.normal[0]=n.x; v.normal[1]=n.y; v.normal[2]=n.z;
            }
            if(mesh.hasUV) {
                const auto& uv=source.mTextureCoords[0][i];
                v.uv[0]=uv.x; v.uv[1]=uv.y;
            }
            if(mesh.hasColors) {
                const auto& c=source.mColors[0][i];
                v.color[0]=c.r; v.color[1]=c.g; v.color[2]=c.b; v.color[3]=c.a;
            }
            // 分数组检查，避免把结构体强转 float* 后跨成员数组做未定义的指针运算。
            for(float x:v.position) if(!std::isfinite(x)) throw std::runtime_error("nonfinite position");
            for(float x:v.normal) if(!std::isfinite(x)) throw std::runtime_error("nonfinite normal");
            for(float x:v.uv) if(!std::isfinite(x)) throw std::runtime_error("nonfinite UV");
            for(float x:v.color) if(!std::isfinite(x)) throw std::runtime_error("nonfinite color");
        }
        // aiFace 按面存索引；这里铺平成 uint32 数组，每连续三个索引是一个三角形。
        // 无索引 glTF 也已由库生成 aiFace，不需要猜测原文件中的索引字节类型。
        for(unsigned f=0;f<source.mNumFaces;++f) {
            const aiFace& face=source.mFaces[f];
            if(face.mNumIndices!=3) throw std::runtime_error("only triangle faces are supported");
            for(unsigned j=0;j<3;++j) {
                if(face.mIndices[j]>=source.mNumVertices) throw std::runtime_error("index out of range");
                mesh.indices.push_back(static_cast<uint32_t>(face.mIndices[j]));
            }
        }
        result.push_back(std::move(mesh));
    }
    return result; // 自有数组独立于传入的 aiScene；借用关系到此结束。
}
