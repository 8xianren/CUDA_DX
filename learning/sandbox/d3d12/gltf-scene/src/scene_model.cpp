#include "cpu_scene.h"
#include <cmath>
#include <stdexcept>
// D.4：运行时节点运算只依赖自有值类型；不需要文件、Assimp或图形设备。
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
void UpdateWorldMatrices(CpuScene& scene) {
    for(size_t i=0;i<scene.nodes.size();++i) {
        auto& n=scene.nodes[i];
        if(n.parent < -1 || n.parent>=static_cast<int>(i)) throw std::runtime_error("parent must precede child");
        n.world=n.parent==-1?n.local:Multiply(scene.nodes[n.parent].world,n.local);
        for(float x:n.world.m) if(!std::isfinite(x)) throw std::runtime_error("nonfinite world matrix");
    }
}
