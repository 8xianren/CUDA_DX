#include "assets/character_import.h"
#include "assimp_mesh_copy.h"
#include <assimp/Importer.hpp>
#include <assimp/scene.h>
#include <assimp/postprocess.h>
#include <cmath>
#include <functional>
#include <map>
#include <stdexcept>
namespace character {
static void Require(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
static Vec3 Vector(const aiVector3D& v){return {v.x,v.y,v.z};}
static Quat Quaternion(const aiQuaternion& q){return {q.x,q.y,q.z,q.w};}
static Mat4 Matrix(const aiMatrix4x4& a){Mat4 m;for(unsigned r=0;r<4;++r)for(unsigned c=0;c<4;++c)m[r][c]=a[r][c];return m;}
static Matrix4 Copy(const aiMatrix4x4& a){Matrix4 m;for(unsigned r=0;r<4;++r)for(unsigned c=0;c<4;++c)m.m[r*4+c]=a[r][c];return m;}
// 唯一依赖Assimp的角色适配层；所有数据深拷贝为项目值类型，Importer析构后仍然有效。
Rig Load(const std::string& path){
    Assimp::Importer importer;
    const auto* source=importer.ReadFile(path,aiProcess_Triangulate|aiProcess_ValidateDataStructure);
    if(!source||!source->mRootNode)throw std::runtime_error(importer.GetErrorString());
    Rig out;out.scene.meshes=CopyCpuMeshes(*source,true);out.scene.materialAssets=CopyMaterialAssets(*source,path);
    std::map<std::string,uint32_t> names;
    std::function<void(const aiNode*,int,unsigned)> visit=[&](const aiNode* n,int parent,unsigned depth){
        Require(depth<128,"node tree too deep");uint32_t index=uint32_t(out.scene.nodes.size());
        Require(names.emplace(n->mName.C_Str(),index).second,"duplicate node name");
        CpuNode node;node.name=n->mName.C_Str();node.parent=parent;node.local=Copy(n->mTransformation);
        Pose pose;aiVector3D scale,translation;aiQuaternion rotation;n->mTransformation.Decompose(scale,rotation,translation);
        pose.scale=Vector(scale);pose.translation=Vector(translation);pose.rotation=Quaternion(rotation);
        out.defaults.push_back(pose);
        for(unsigned i=0;i<n->mNumMeshes;++i){Require(n->mMeshes[i]<out.scene.meshes.size(),"bad mesh reference");
            node.meshIndices.push_back(n->mMeshes[i]);out.scene.instances.push_back({index,n->mMeshes[i]});}
        out.scene.nodes.push_back(node);
        for(unsigned i=0;i<n->mNumChildren;++i)visit(n->mChildren[i],int(index),depth+1);
    };
    visit(source->mRootNode,-1,0);UpdateWorldMatrices(out.scene);
    for(unsigned mi=0;mi<source->mNumMeshes;++mi){
        const auto& mesh=*source->mMeshes[mi];if(!mesh.HasBones())continue;
        Skin skin;skin.mesh=mi;skin.node=UINT32_MAX;
        for(const auto& instance:out.scene.instances)if(instance.meshIndex==mi){Require(skin.node==UINT32_MAX,"multiple skinned instances unsupported");skin.node=instance.nodeIndex;}
        Require(skin.node!=UINT32_MAX,"unreferenced skin");skin.influence.resize(mesh.mNumVertices);
        std::vector<unsigned> count(mesh.mNumVertices);
        for(unsigned bi=0;bi<mesh.mNumBones;++bi){
            const auto& bone=*mesh.mBones[bi];Require(names.count(bone.mName.C_Str())!=0,"missing bone node");
            skin.joints.push_back({names.at(bone.mName.C_Str()),Matrix(bone.mOffsetMatrix)});
            for(unsigned i=0;i<bone.mNumWeights;++i){const auto& w=bone.mWeights[i];
                Require(w.mVertexId<count.size()&&std::isfinite(w.mWeight)&&w.mWeight>=0,"invalid weight");
                if(w.mWeight==0)continue;auto& n=count[w.mVertexId];Require(n<4,"more than four influences");
                auto& inf=skin.influence[w.mVertexId];inf.joint[n]=bi;inf.weight[n++]=w.mWeight;
            }
        }
        for(const auto& inf:skin.influence){float sum=0;for(float w:inf.weight)sum+=w;Require(std::abs(sum-1)<1e-4f,"unnormalized skin weights");}
        out.skins.push_back(std::move(skin));
    }
    for(unsigned ai=0;ai<source->mNumAnimations;++ai){
        const auto& a=*source->mAnimations[ai];Require(a.mTicksPerSecond>0&&std::isfinite(a.mTicksPerSecond),"unknown animation time unit");
        Require(a.mDuration>0&&std::isfinite(a.mDuration)&&!a.mNumMorphMeshChannels&&!a.mNumMeshChannels,"unsupported animation");
        Clip clip;clip.name=a.mName.C_Str();clip.duration=a.mDuration/a.mTicksPerSecond;
        for(unsigned ci=0;ci<a.mNumChannels;++ci){
            const auto& c=*a.mChannels[ci];Require(names.count(c.mNodeName.C_Str())!=0,"unknown animation target");
            Track track;track.node=names.at(c.mNodeName.C_Str());
            for(unsigned i=0;i<c.mNumPositionKeys;++i)track.translation.push_back({c.mPositionKeys[i].mTime/a.mTicksPerSecond,Vector(c.mPositionKeys[i].mValue)});
            for(unsigned i=0;i<c.mNumRotationKeys;++i)track.rotation.push_back({c.mRotationKeys[i].mTime/a.mTicksPerSecond,Quaternion(c.mRotationKeys[i].mValue)});
            for(unsigned i=0;i<c.mNumScalingKeys;++i)track.scale.push_back({c.mScalingKeys[i].mTime/a.mTicksPerSecond,Vector(c.mScalingKeys[i].mValue)});
            clip.tracks.push_back(std::move(track));
        }
        out.clips.push_back(std::move(clip));
    }
    Require(!out.skins.empty()&&!out.clips.empty(),"expected animated skin");return out;
}
}
