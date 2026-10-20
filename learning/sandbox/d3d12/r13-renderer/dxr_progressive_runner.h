#pragma once
#include "dxr_gpu_sequence.h"
#include <functional>
// R.13.6宿主执行层：复用调用方已构建的设备/AS/RootSignature/StateObject/SBT。
// 只在这里管理采样循环和历史资源，不复制设备、场景和DXR管线初始化代码。
// 调用方保持所有输入COM对象存活；本函数拥有新增资源，并在返回前等待全部使用结束。
inline bool run_progressive(ID3D12Device5* dev,ID3D12CommandQueue* queue,ID3D12Fence* fence,
    ID3D12RootSignature* root,ID3D12StateObject* state,ID3D12Resource* tlas,
    ID3D12Resource* vb,ID3D12Resource* ib,ID3D12Resource* sbt,const std::function<void(UINT64)>& waitFor,const std::filesystem::path& folder){
    namespace pr=progressive_reference;
    GpuRaySequence sequence(dev,queue,fence,root,state,tlas,vb,ib,sbt,waitFor);
    bool pass=true;
    auto render=[&](unsigned seed,unsigned testFlags,unsigned frames,const std::string& name){
        pr::Verification verify(seed,testFlags,folder,name);
        std::printf("begin %-15s seed=%u flags=%u frames=%u\n",name.c_str(),seed,testFlags,frames);
        for(unsigned sample=0;sample<frames;++sample){
            RaySubmission input;input.view=view_reference::make_view(pr::camera(),sample+1);
            input.view.targetInfo[0]=pr::Width;input.view.targetInfo[1]=pr::Height;
            input.controls={sample,seed,testFlags,0};
            sequence.enqueue(input,[&](const pr::Record* data,const RaySubmission& frame){
                pass=verify.consume(data,frame.controls[0])&&pass;
            });
        }
        sequence.flush(); // verify局部变量销毁前排空引用它的读回回调。
        pass=verify.finish()&&pass;return verify;
    };
    // 参考图使用独立seed的2048个样本，只是高样本参考，不是无误差真值。
    auto reference=render(9000,0,2048,"reference");
    pass=pr::save(folder/"reference_2048spp.pfm",reference.latest)&&pass;
    std::ofstream csv(folder/"convergence.csv");csv<<"seed,spp,mse_vs_independent_2048spp\n";
    std::array<double,3> meanMse{};std::vector<view_reference::V3> baseline;
    for(unsigned seed=0;seed<8;++seed){auto run=render(seed,0,256,"seed"+std::to_string(seed));
        for(unsigned j=0;j<3;++j){unsigned spp=j==0?1:j==1?16:256;double error=pr::mse(run.checkpoints[j],reference.latest);
            meanMse[j]+=error/8;csv<<seed<<","<<spp<<","<<error<<"\n";}
        if(seed==0)baseline=run.latest;
    }
    auto center=render(0,2,256,"center"); // 灯样本变化，像素位置固定；不会消除轮廓采样偏差。
    auto frozen=render(0,1,16,"frozen"); // 再平均同一个样本，结果不会改善。
    auto hdr=render(0,4,16,"hdr-zero");
    auto replay=render(0,0,256,"replay");double repeatError=pr::mse(replay.latest,baseline);
    double frozenDifference=pr::mse(frozen.checkpoints[0],frozen.checkpoints[1]);
    pass=pass&&repeatError==0&&frozenDifference==0&&meanMse[1]<meanMse[0]&&meanMse[2]<meanMse[1];
    for(unsigned j=0;j<3;++j)std::printf("8-seed mean MSE spp=%u : %.9g ; RMSE=%.9g\n",j==0?1:j==1?16:256,meanMse[j],std::sqrt(meanMse[j]));
    std::printf("replay MSE=%.3g frozen 1/16 MSE=%.3g fence=%llu/%llu\n",repeatError,frozenDifference,(unsigned long long)fence->GetCompletedValue(),(unsigned long long)sequence.last_fence());
    csv.close();pass=bool(csv)&&pass;
    return pass;
}
