#pragma once
#include "scene_io.h"
#include <algorithm>
#include <numeric>
#include <functional>
namespace cuda_pt {
struct Bounds {Vec3 lo{FLT_MAX,FLT_MAX,FLT_MAX},hi{-FLT_MAX,-FLT_MAX,-FLT_MAX};
    void Add(Vec3 p){lo=Min(lo,p);hi=Max(hi,p);}void Add(const Bounds& b){Add(b.lo);Add(b.hi);}};
inline Bounds TriangleBounds(const Triangle& t){Bounds b;b.Add(t.a);b.Add(t.b);b.Add(t.c);
    // 当前米级教学场景的保守外扩，避免float slab与triangle算术误差把贴边命中剪掉。
    // 这是显式数值策略，不宣称对所有浮点尺度/极薄三角形具有watertight保证。
    float scale=1+std::max({fabsf(b.lo.x),fabsf(b.lo.y),fabsf(b.lo.z),fabsf(b.hi.x),fabsf(b.hi.y),fabsf(b.hi.z)});
    Vec3 padding{2e-6f*scale,2e-6f*scale,2e-6f*scale};b.lo=b.lo-padding;b.hi=b.hi+padding;return b;
}
struct Bvh {std::vector<Node> nodes;std::vector<uint32_t> order;unsigned maxDepth=0,leaves=0;};
inline Bvh BuildBvh(const Scene& scene){
    ValidateScene(scene);Bvh b;size_t count=scene.triangles.size();if(!count)return b;
    b.order.resize(count);std::iota(b.order.begin(),b.order.end(),0u);b.nodes.reserve(2*count);
    std::vector<Bounds> bounds(count);std::vector<Vec3> centroids(count);
    for(size_t i=0;i<count;++i){const auto& t=scene.triangles[i];bounds[i]=TriangleBounds(t);centroids[i]=(t.a+t.b+t.c)*(1.f/3);}
    std::function<uint32_t(uint32_t,uint32_t,unsigned)> build=[&](uint32_t begin,uint32_t end,unsigned depth){
        Require(depth<64,"BVH depth exceeds traversal stack contract");b.maxDepth=std::max(b.maxDepth,depth);
        uint32_t index=uint32_t(b.nodes.size());b.nodes.push_back({});Bounds box,centroidBox;
        for(uint32_t i=begin;i<end;++i){box.Add(bounds[b.order[i]]);centroidBox.Add(centroids[b.order[i]]);}
        // 递归push_back可能移动vector存储，不能提前保存Node&引用再跨递归使用。
        Node node{};node.lower=box.lo;node.upper=box.hi;uint32_t n=end-begin;
        if(n<=4){node.first=begin;node.second=LeafBit|n;++b.leaves;}
        else{
            Vec3 extent=centroidBox.hi-centroidBox.lo;unsigned axis=extent.y>extent.x?1:0;if(extent.z>Axis(extent,axis))axis=2;
            uint32_t middle=begin+n/2;
            // 中心相同也以稳定原ID打破平局，始终二分计数，避免退化中心造成无限递归。
            std::nth_element(b.order.begin()+begin,b.order.begin()+middle,b.order.begin()+end,[&](uint32_t a,uint32_t c){
                float x=Axis(centroids[a],axis),y=Axis(centroids[c],axis);return x<y||(x==y&&a<c);});
            node.first=build(begin,middle,depth+1);node.second=build(middle,end,depth+1);
        }b.nodes[index]=node;return index;
    };build(0,uint32_t(count),0);return b;
}
inline void ValidateBvh(const Scene& scene,const Bvh& b){
    if(scene.triangles.empty()){Require(b.nodes.empty()&&b.order.empty(),"nonempty tree for empty scene");return;}
    Require(!b.nodes.empty()&&b.order.size()==scene.triangles.size(),"BVH/order extent");
    std::vector<unsigned char> seenNodes(b.nodes.size(),0),seenTriangles(scene.triangles.size(),0);
    std::function<void(uint32_t,unsigned)> visit=[&](uint32_t i,unsigned depth){
        Require(i<b.nodes.size()&&depth<64&&!seenNodes[i],"BVH invalid child/cycle/duplicate node/depth");seenNodes[i]=1;const Node& n=b.nodes[i];
        Require(Finite(n.lower)&&Finite(n.upper)&&n.lower.x<=n.upper.x&&n.lower.y<=n.upper.y&&n.lower.z<=n.upper.z,"invalid finite node bounds");
        auto contains=[&](Vec3 p){return p.x>=n.lower.x&&p.x<=n.upper.x&&p.y>=n.lower.y&&p.y<=n.upper.y&&p.z>=n.lower.z&&p.z<=n.upper.z;};
        if(IsLeaf(n)){uint32_t count=n.second&~LeafBit;Require(count>0&&count<=4&&n.first<=b.order.size()&&count<=b.order.size()-n.first,"leaf range/count");
            for(uint32_t k=0;k<count;++k){uint32_t id=b.order[n.first+k];Require(id<scene.triangles.size()&&!seenTriangles[id],"triangle missing/duplicate index");seenTriangles[id]=1;
                const auto& t=scene.triangles[id];Require(contains(t.a)&&contains(t.b)&&contains(t.c),"leaf does not enclose triangle");}}
        else{for(uint32_t child:{n.first,n.second}){Require(child<b.nodes.size(),"child range");Require(contains(b.nodes[child].lower)&&contains(b.nodes[child].upper),"parent does not enclose child");visit(child,depth+1);}}
    };visit(0,0);
    Require(std::all_of(seenNodes.begin(),seenNodes.end(),[](auto n){return n==1;}),"unreachable node");
    Require(std::all_of(seenTriangles.begin(),seenTriangles.end(),[](auto n){return n==1;}),"missing triangle");
}
}
