// H1：直接检查固定版本 Assimp 的实际输出，不经过旧课的静态适配器。
// importer 拥有全部 aiScene 内存；这里只借用读取并输出报告，不返回悬空指针。
#include <assimp/Importer.hpp>
#include <assimp/scene.h>
#include <assimp/postprocess.h>
#include <assimp/version.h>
#include <algorithm>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

struct NodeInfo { const aiNode* node; aiMatrix4x4 world; std::string parent; };
using Nodes=std::map<std::string,NodeInfo>;
static void Need(bool ok,const std::string& message){if(!ok)throw std::runtime_error(message);}
static double Difference(const aiMatrix4x4& a,const aiMatrix4x4& b){
    double error=0;
    for(unsigned r=0;r<4;++r)for(unsigned c=0;c<4;++c){
        Need(std::isfinite(a[r][c])&&std::isfinite(b[r][c]),"nonfinite matrix");
        error=std::max(error,std::abs(double(a[r][c])-b[r][c]));
    }
    return error;
}
static void Visit(const aiNode* n,const aiMatrix4x4& parent,const std::string& parentName,Nodes& out,unsigned depth=0){
    Need(n&&depth<128,"invalid node tree");
    NodeInfo info{n,parent*n->mTransformation,parentName};
    Need(out.emplace(n->mName.C_Str(),info).second,"duplicate node name");
    Difference(info.world,info.world);
    for(unsigned i=0;i<n->mNumChildren;++i)Visit(n->mChildren[i],info.world,n->mName.C_Str(),out,depth+1);
}
template<class Key> static void Keys(const Key* values,unsigned count,double duration){
    Need(count>0&&values,"missing animation keys");
    double last=-1;
    for(unsigned i=0;i<count;++i){
        Need(std::isfinite(values[i].mTime)&&values[i].mTime>=0&&values[i].mTime>last,"unordered keys");
        Need(values[i].mTime<=duration+1e-3,"key beyond duration");
        last=values[i].mTime;
    }
}
static Nodes Probe(const aiScene& s,const std::string& label,const std::string& output){
    Nodes nodes; Visit(s.mRootNode,aiMatrix4x4(),"",nodes);
    std::ofstream report(output+"/"+label+".txt");
    Need(bool(report),"cannot open report");
    report<<std::setprecision(10)<<"assimp "<<aiGetVersionMajor()<<'.'<<aiGetVersionMinor()<<'.'<<aiGetVersionPatch()
          <<"\nnodes "<<nodes.size()<<" meshes "<<s.mNumMeshes<<" animations "<<s.mNumAnimations<<'\n';
    for(const auto& pair:nodes)report<<"node "<<pair.first<<" parent "<<pair.second.parent<<'\n';
    unsigned totalVertices=0,totalTriangles=0;
    double maxWeightError=0,maxBindError=0;
    for(unsigned mi=0;mi<s.mNumMeshes;++mi){
        const aiMesh& mesh=*s.mMeshes[mi];
        Need(mesh.HasPositions()&&mesh.HasNormals(),"missing positions/normals");
        Need(!mesh.mNumAnimMeshes,"morph not supported in H1 baseline");
        std::vector<double> weights(mesh.mNumVertices);
        std::vector<unsigned> influence(mesh.mNumVertices);
        const NodeInfo* meshNode=nullptr;
        for(const auto& pair:nodes)for(unsigned j=0;j<pair.second.node->mNumMeshes;++j)
            if(pair.second.node->mMeshes[j]==mi){Need(!meshNode,"multiple skinned mesh instances require explicit policy");meshNode=&pair.second;}
        Need(meshNode,"unreferenced mesh");
        // 在绑定姿势，jointWorld * inverseBind 应等于网格节点的 world。
        // 左乘 inverse(meshWorld) 后才是写回网格局部 VB 的蒙皮矩阵。
        for(unsigned b=0;b<mesh.mNumBones;++b){
            const aiBone& bone=*mesh.mBones[b];
            Need(nodes.count(bone.mName.C_Str())!=0,"bone has no node");
            maxBindError=std::max(maxBindError,Difference(nodes.at(bone.mName.C_Str()).world*bone.mOffsetMatrix,meshNode->world));
            for(unsigned j=0;j<bone.mNumWeights;++j){
                const auto& w=bone.mWeights[j];
                Need(w.mVertexId<mesh.mNumVertices&&std::isfinite(w.mWeight)&&w.mWeight>=0,"invalid skin weight");
                weights[w.mVertexId]+=w.mWeight;
                if(w.mWeight>0)++influence[w.mVertexId];
            }
        }
        for(unsigned v=0;v<mesh.mNumVertices;++v){
            const auto& p=mesh.mVertices[v];
            Need(std::isfinite(p.x)&&std::isfinite(p.y)&&std::isfinite(p.z),"invalid position");
            if(mesh.HasBones()){Need(influence[v]>0,"unweighted vertex");maxWeightError=std::max(maxWeightError,std::abs(weights[v]-1));}
        }
        for(unsigned f=0;f<mesh.mNumFaces;++f){
            Need(mesh.mFaces[f].mNumIndices==3,"nontriangle");
            for(unsigned j=0;j<3;++j)Need(mesh.mFaces[f].mIndices[j]<mesh.mNumVertices,"index out of bounds");
        }
        report<<"mesh "<<mi<<" vertices "<<mesh.mNumVertices<<" triangles "<<mesh.mNumFaces<<" bones "<<mesh.mNumBones
              <<" maxInfluences "<<*std::max_element(influence.begin(),influence.end())<<'\n';
        totalVertices+=mesh.mNumVertices;totalTriangles+=mesh.mNumFaces;
    }
    std::set<std::string> clips;
    for(unsigned ai=0;ai<s.mNumAnimations;++ai){
        const auto& a=*s.mAnimations[ai];
        Need(std::isfinite(a.mTicksPerSecond)&&a.mTicksPerSecond>0,"unknown ticks per second; no guessed fallback");
        Need(std::isfinite(a.mDuration)&&a.mDuration>0,"invalid clip duration");
        Need(!a.mNumMeshChannels&&!a.mNumMorphMeshChannels,"unsupported mesh animation");
        clips.insert(a.mName.C_Str());
        std::set<std::string> targets;
        for(unsigned ci=0;ci<a.mNumChannels;++ci){
            const auto& c=*a.mChannels[ci];
            Need(nodes.count(c.mNodeName.C_Str())&&targets.insert(c.mNodeName.C_Str()).second,"missing/duplicate channel target");
            Keys(c.mPositionKeys,c.mNumPositionKeys,a.mDuration);
            Keys(c.mRotationKeys,c.mNumRotationKeys,a.mDuration);
            Keys(c.mScalingKeys,c.mNumScalingKeys,a.mDuration);
            for(unsigned k=0;k<c.mNumRotationKeys;++k){const auto& q=c.mRotationKeys[k].mValue;
                double norm=q.w*q.w+q.x*q.x+q.y*q.y+q.z*q.z;Need(std::isfinite(norm)&&std::abs(norm-1)<1e-3,"nonunit quaternion");}
            for(unsigned k=0;k<c.mNumPositionKeys;++k){const auto& v=c.mPositionKeys[k].mValue;Need(std::isfinite(v.x)&&std::isfinite(v.y)&&std::isfinite(v.z),"nonfinite translation");}
            for(unsigned k=0;k<c.mNumScalingKeys;++k){const auto& v=c.mScalingKeys[k].mValue;Need(std::isfinite(v.x)&&std::isfinite(v.y)&&std::isfinite(v.z)&&v.x>0&&v.y>0&&v.z>0,"invalid scale");}
        }
        report<<"clip "<<a.mName.C_Str()<<" ticksPerSecond "<<a.mTicksPerSecond<<" durationTicks "<<a.mDuration
              <<" seconds "<<a.mDuration/a.mTicksPerSecond<<" channels "<<a.mNumChannels<<'\n';
    }
    if(label=="animation")for(const char* clip:{"Idle_Loop","Walk_Loop","Sprint_Loop","Jump_Start","Jump_Loop","Jump_Land"})
        Need(clips.count(clip)!=0,std::string("missing required clip ")+clip);
    report<<"SUMMARY vertices "<<totalVertices<<" triangles "<<totalTriangles<<" weightError "<<maxWeightError<<" bindError "<<maxBindError<<'\n';
    Need(maxWeightError<1e-4,"weights not normalized");
    // 默认节点姿势不一定是绑定姿势；记录该差异，不能未经核验就硬性认定资产坏掉。
    std::cout<<label<<" vertices="<<totalVertices<<" triangles="<<totalTriangles<<" weightError="<<maxWeightError<<" bindError="<<maxBindError<<'\n';
    return nodes;
}
int main(int argc,char** argv){
    try{
        Need(argc==4,"usage: h_asset_probe character animation output-directory");
        Assimp::Importer character,animation;
        const unsigned flags=aiProcess_Triangulate|aiProcess_ValidateDataStructure;
        const aiScene* c=character.ReadFile(argv[1],flags);
        Need(c&&c->mRootNode,std::string("character import: ")+character.GetErrorString());
        const aiScene* a=animation.ReadFile(argv[2],flags);
        Need(a&&a->mRootNode,std::string("animation import: ")+animation.GetErrorString());
        const auto cn=Probe(*c,"character",argv[3]);
        const auto an=Probe(*a,"animation",argv[3]);
        double localError=0;unsigned shared=0,parentMismatch=0;
        std::ofstream report(std::string(argv[3])+"/compatibility.txt");
        Need(bool(report),"cannot write compatibility report");
        for(const auto& pair:an){
            auto other=cn.find(pair.first);if(other==cn.end())continue;
            ++shared;const double error=Difference(pair.second.node->mTransformation,other->second.node->mTransformation);
            localError=std::max(localError,error);
            if(pair.second.parent!=other->second.parent)++parentMismatch;
            report<<pair.first<<" localDifference "<<error<<" parents "<<pair.second.parent<<" / "<<other->second.parent<<'\n';
        }
        report<<"sharedNodes "<<shared<<" maxLocalDifference "<<localError<<" parentMismatch "<<parentMismatch<<'\n';
        std::cout<<"sharedNodes="<<shared<<" maxLocalDifference="<<localError<<" parentMismatch="<<parentMismatch<<"\nPASS asset structural probe (compatibility is measured, not assumed)\n";
        return 0;
    }catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
}
