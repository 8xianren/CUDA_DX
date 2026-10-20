// C.2 接入探针：库负责解码，本程序只遍历 CPU 数据并输出可比较的语义摘要。
// 不创建 GPU 资源；不预变换顶点，以便保留共享网格与节点实例关系。
#include <assimp/Importer.hpp>
#include <assimp/Exporter.hpp>
#include <assimp/scene.h>
#include <assimp/material.h>
#include <assimp/postprocess.h>
#include <assimp/version.h>
#include <iostream>
#include <iomanip>
#include <stdexcept>
#include <string>
#include <cmath>

static void node(const aiNode* n, unsigned meshCount, unsigned& instances) {
    std::cout << "node " << n->mName.C_Str() << " meshes";
    for (unsigned i=0; i<n->mNumMeshes; ++i) {
        if (n->mMeshes[i]>=meshCount) throw std::runtime_error("invalid mesh reference");
        std::cout << ' ' << n->mMeshes[i]; ++instances;
    }
    // aiMatrix4x4 的 a/b/c/d 是四行；完整打印局部变换，不误当成世界矩阵。
    const auto& m=n->mTransformation;
    std::cout << " local " << m.a1 << ' ' << m.a2 << ' ' << m.a3 << ' ' << m.a4
      << ' ' << m.b1 << ' ' << m.b2 << ' ' << m.b3 << ' ' << m.b4
      << ' ' << m.c1 << ' ' << m.c2 << ' ' << m.c3 << ' ' << m.c4
      << ' ' << m.d1 << ' ' << m.d2 << ' ' << m.d3 << ' ' << m.d4 << '\n';
    for(unsigned i=0;i<n->mNumChildren;++i) node(n->mChildren[i],meshCount,instances);
}

int main(int argc,char** argv) {
    if(argc!=2 && argc!=4) { std::cerr<<"usage: scene_import_probe input [--export-glb output]\n"; return 2; }
    try {
        Assimp::Importer importer;
        // ReadFile(path, flags)：路径交给库，Triangulate 将多边形转三角形；
        // ValidateDataStructure 检查导入结构。没有启用坐标翻转/法线生成/节点合并。
        // scene 及其子指针归 importer 所有；它析构或再次 ReadFile 后不能再访问。
        const aiScene* s=importer.ReadFile(argv[1],aiProcess_Triangulate|aiProcess_ValidateDataStructure);
        if(!s || !s->mRootNode || (s->mFlags & AI_SCENE_FLAGS_INCOMPLETE)) {
            std::cerr<<"IMPORT_ERROR "<<argv[1]<<": "<<importer.GetErrorString()<<'\n'; return 1;
        }
        std::cout<<std::setprecision(9)<<"Assimp "<<aiGetVersionMajor()<<'.'<<aiGetVersionMinor()<<'.'<<aiGetVersionPatch()<<'\n';
        unsigned instances=0,faces=0;
        node(s->mRootNode,s->mNumMeshes,instances);
        for(unsigned k=0;k<s->mNumMeshes;++k) {
            const auto& m=*s->mMeshes[k];
            if(m.mMaterialIndex>=s->mNumMaterials) throw std::runtime_error("invalid material");
            std::cout<<"mesh "<<k<<" material "<<m.mMaterialIndex<<" vertices "<<m.mNumVertices<<" faces "<<m.mNumFaces<<'\n';
            for(unsigned v=0;v<m.mNumVertices;++v) {
                const auto& p=m.mVertices[v];
                if(!std::isfinite(p.x)||!std::isfinite(p.y)||!std::isfinite(p.z)) throw std::runtime_error("nonfinite position");
                std::cout<<"v "<<p.x<<' '<<p.y<<' '<<p.z<<'\n';
            }
            for(unsigned f=0;f<m.mNumFaces;++f) {
                const auto& face=m.mFaces[f];
                if(face.mNumIndices!=3) throw std::runtime_error("probe only accepts triangles");
                std::cout<<"triangle";
                for(unsigned j=0;j<3;++j) {
                    if(face.mIndices[j]>=m.mNumVertices) throw std::runtime_error("index out of range");
                    std::cout<<' '<<face.mIndices[j];
                }
                std::cout<<'\n'; ++faces;
            }
        }
        // 材质只验收本课 baseColor，不能据此宣称所有材质语义已兼容。
        for(unsigned i=0;i<s->mNumMaterials;++i) {
            aiColor4D c;
            if(s->mMaterials[i]->Get(AI_MATKEY_BASE_COLOR,c)==AI_SUCCESS)
                std::cout<<"baseColor "<<i<<' '<<c.r<<' '<<c.g<<' '<<c.b<<' '<<c.a<<'\n';
        }
        std::cout<<"SUMMARY meshes="<<s->mNumMeshes<<" instances="<<instances<<" triangles="<<faces<<" cameras="<<s->mNumCameras<<'\n';
        if(argc==4) {
            if(std::string(argv[2])!="--export-glb") return 2;
            Assimp::Exporter exporter;
            // Export 不接管场景所有权；必须在 importer 仍存活时执行。
            if(exporter.Export(s,"glb2",argv[3])!=AI_SUCCESS) {
                std::cerr<<"EXPORT_ERROR "<<exporter.GetErrorString()<<'\n'; return 1;
            }
        }
        return 0;
    } catch(const std::exception& e) { std::cerr<<"ERROR "<<e.what()<<'\n'; return 1; }
}
