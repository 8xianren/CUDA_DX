#pragma once
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>

namespace restir {
// PT.11 CPU double参考：Update接收原始候选，Merge接收同一面积测度的压缩候选组。
// Sample按值保存；不拥有光源/场景，也不保存全部候选。调用者保证样本身份有效。
// 不允许直接把其他reservoir视为proposal已知的普通候选：复用需另行推导权重。
template<class Sample> struct Reservoir {
    Sample sample{};
    double weightSum=0;       // S=sum(target/proposal)，不是最终估计，也不是PDF。
    double selectedTarget=0;  // 当前选中样本处的非负、可不归一化的标量目标函数。
    uint64_t M=0;            // 已处理的候选总数；零权候选也必须计入。
    bool valid=false;        // 全零权时不读取sample、不进行0/0。

    // target=目标函数t(y)，proposal=候选的概率质量或同测度PDF q(y)。
    // u是与本次选择独立的[0,1)随机变量；不能复用生成候选时的同一个随机数。
    // q>0、t>=0且有限。f非零处t/q必须有支持，由积分调用方保证，容器不能推断。
    // CPU单线程独占该对象；无原子、无跨线程共享，也没有隐式GPU同步。
    void Update(const Sample& candidate,double target,double proposal,double u){
        if(!std::isfinite(target)||target<0||!std::isfinite(proposal)||proposal<=0||
           !std::isfinite(u)||u<0||u>=1)throw std::invalid_argument("invalid reservoir input");
        double weight=target/proposal, next=weightSum+weight;
        if(!std::isfinite(weight)||!std::isfinite(next)||M==std::numeric_limits<uint64_t>::max())
            throw std::overflow_error("reservoir weight/count overflow");
        // 检查先于修改，非法输入不会污染原状态；先增加M，零权也代表一次抽样。
        ++M;weightSum=next;
        if(weight>0&&(!valid||u<weight/next)){
            sample=candidate;selectedTarget=target;valid=true;
        }
    }

    // W=S/(M*t(selected))。最终RGB为W*f(selected)，可见性属于f，仍需查询。
    // W是随机归一化权重，不应当作已知“最终PDF”的倒数去随意套用其他MIS公式。
    double Normalization() const {
        if(!valid)return 0;
        double w=(weightSum/double(M))/selectedTarget;
        if(!std::isfinite(w))throw std::overflow_error("reservoir normalization overflow");
        return w;
    }

    // 源reservoir代表source.M个候选。目标位置重新计算t_dst(source.sample)，
    // 合并选择权重为t_dst * source.W * source.M，最终分母累加source.M。
    // 本入口只支持相同样本空间/测度下的恒等映射(J=1)，不是通用GI路径迁移。
    // 前置：各源评分/提议覆盖目标真实贡献的支持域；组大小固定或满足相应无偏条件。
    // 来源可相关；M不是独立样本数。禁止原地自引用，跨像素应读旧缓冲、写新缓冲。
    void Merge(const Reservoir& source,double targetAtDestination,double u){
        if(this==&source)throw std::invalid_argument("in-place self merge");
        if(!std::isfinite(targetAtDestination)||targetAtDestination<0||!std::isfinite(u)||u<0||u>=1)
            throw std::invalid_argument("invalid merge input");
        if(source.M==0){if(source.valid||source.weightSum!=0)throw std::invalid_argument("invalid empty source");return;}
        if((source.valid&&(source.selectedTarget<=0||!std::isfinite(source.selectedTarget)||source.weightSum<=0))||
           (!source.valid&&source.weightSum!=0)||!std::isfinite(source.weightSum))throw std::invalid_argument("invalid source state");
        double weight=source.valid?targetAtDestination*source.Normalization()*double(source.M):0;
        double next=weightSum+weight;
        if(!std::isfinite(weight)||!std::isfinite(next)||source.M>std::numeric_limits<uint64_t>::max()-M)
            throw std::overflow_error("merge weight/count overflow");
        // 零权来源仍计候选数；一切检查先于修改。source由const引用借用，没有转移资源所有权。
        M+=source.M;weightSum=next;
        if(weight>0&&(!valid||u<weight/next)){sample=source.sample;selectedTarget=targetAtDestination;valid=true;}
    }
};
}
