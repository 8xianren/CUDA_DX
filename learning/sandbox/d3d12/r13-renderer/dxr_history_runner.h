#pragma once
#include "dxr_history_reference.h"
// 自动reset与故意不reset的GPU实验，共用GpuRaySequence；不复制两槽/屏障/读回实现。
inline bool run_history(ID3D12Device5* dev,ID3D12CommandQueue* queue,ID3D12Fence* fence,
    ID3D12RootSignature* root,ID3D12StateObject* state,ID3D12Resource* tlas,
    ID3D12Resource* vb,ID3D12Resource* ib,ID3D12Resource* sbt,const std::function<void(UINT64)>& waitFor,const std::filesystem::path& folder){
    namespace hp=history_policy;namespace hr=history_reference;namespace pr=progressive_reference;
    GpuRaySequence gpu(dev,queue,fence,root,state,tlas,vb,ib,sbt,waitFor);hp::Tracker tracker;hr::Verify verify;
    struct Stage {hp::Settings settings;std::string name;unsigned frames,expectedReason;bool force;};
    std::vector<Stage> stages;hp::Settings s;
    auto add=[&](const char* name,unsigned frames,unsigned reason,bool force=false){stages.push_back({s,name,frames,reason,force});};
    add("initial",16,hp::Initial);add("jitter-continues",8,0);
    s.exposureMultiplier=2;add("exposure-only",8,0);
    s.toneMap=1;add("tone-only",8,0);
    s.seed=77;add("seed-only",8,0);
    s.camera.eye={0,.35,.1};add("camera-translate",16,hp::Camera);
    s.camera.forward={1,.1,0};add("camera-rotate",16,hp::Camera);
    s.camera.fov=50;add("fov",16,hp::Camera);
    s.camera.nearPlane=.2;add("near-plane",16,hp::Camera);
    s.camera.x=8;s.camera.y=8;s.camera.w=144;s.camera.h=81;add("viewrect",16,hp::Mapping);
    s.doubleLight=true;add("light-double",16,hp::Light);
    s.blackMaterial=true;add("material-black",16,hp::Material);
    s.blackMaterial=false;add("material-restore",16,hp::Material);
    s.mask=4;add("scene-floor-only",16,hp::Scene);
    s.mask=7;add("scene-restore",16,hp::Scene);
    s.flags=2;add("pixel-center",16,hp::Filter);
    s.flags=0;add("pixel-area",16,hp::Filter);
    add("manual-reset",16,hp::Manual,true);
    unsigned serial=0,randomIndex=0,expectedCount=0,expectedEpoch=0,policyErrors=0,resets=0;
    bool pass=true;std::ofstream csv(folder/"history_events.csv");
    csv<<"serial,stage,rng_index,prior_history,count,epoch,reason,exposure_multiplier,tone_map\n";
    for(const auto& stage:stages){
        for(unsigned j=0;j<stage.frames;++j){
            auto input=hp::submission(stage.settings,randomIndex++,++serial);
            auto decision=tracker.schedule(hp::key(input),stage.force&&j==0);
            bool reset=j==0&&stage.expectedReason!=0;
            if(reset){expectedCount=0;++expectedEpoch;++resets;}++expectedCount;
            unsigned expectedReason=j==0?stage.expectedReason:0;
            if(decision.reasons!=expectedReason||decision.count!=expectedCount||decision.epoch!=expectedEpoch)++policyErrors;
            input.controls[3]=decision.previousCount;
            csv<<serial<<","<<stage.name<<","<<input.controls[0]<<","<<decision.previousCount<<","<<decision.count<<","<<decision.epoch<<","<<hp::reason_text(decision.reasons)<<","<<stage.settings.exposureMultiplier<<","<<stage.settings.toneMap<<"\n";
            unsigned count=expectedCount;bool last=j+1==stage.frames,full=j==0;
            // 捕获当前不可变快照，避免CPU已切到下一节状态时，旧帧读回错误地用新设置验证。
            gpu.enqueue(input,[&,settings=stage.settings,name=stage.name,decision,count,reset,last,full](const pr::Record* data,const RaySubmission& frame){
                verify.consume(data,frame,settings,count,reset,full);
                if(last){
                    pass=pr::save(folder/(name+".pfm"),verify.latest)&&pass;
                    std::printf("stage=%-18s epoch=%u finalCount=%u rng=%u exposure=%.1f tone=%u\n",name.c_str(),decision.epoch,decision.count,frame.controls[0],settings.exposureMultiplier,settings.toneMap);
                }
            });
        }
        // 不在状态变化时强制flush：旧帧可以仍在途，按队列顺序+UAV barrier安全切换。
    }
    gpu.flush();pass=verify.finish("automatic history")&&pass;
    csv.close();pass=bool(csv)&&policyErrors==0&&pass;
    std::printf("policy stages=%zu resets=%u errors=%u\n",stages.size(),resets,policyErrors);

    // 故意错误对照：旧相机64样本与新相机32样本混合。然后用完全相同的新相机样本重跑干净参考。
    hp::Settings before,after;after.camera.eye={0,.9,.1};hr::Verify mixed,clean;
    auto capture=[&](const hp::Settings& settings,unsigned startRng,unsigned frames,unsigned prior,hr::Verify& ref,const char* name){
        for(unsigned j=0;j<frames;++j){auto input=hp::submission(settings,startRng+j,++serial);input.controls[3]=prior+j;
            gpu.enqueue(input,[&,settings,count=prior+j+1,reset=prior==0&&j==0,full=j==0](const pr::Record* data,const RaySubmission& frame){ref.consume(data,frame,settings,count,reset,full);});}
        gpu.flush();pass=pr::save(folder/(std::string(name)+".pfm"),ref.latest)&&pass;return ref.latest;
    };
    auto oldImage=capture(before,0,64,0,mixed,"before-camera");
    auto wrongImage=capture(after,64,32,64,mixed,"wrong-no-reset");
    auto cleanImage=capture(after,64,32,0,clean,"correct-reset");
    pass=mixed.finish("intentional mixed average")&&clean.finish("clean new camera")&&pass;
    double bias=pr::mse(wrongImage,cleanImage),mixtureError=0;
    for(unsigned i=0;i<pr::Pixels;++i)mixtureError=std::max(mixtureError,view_reference::length(wrongImage[i]-(oldImage[i]*(2./3)+cleanImage[i]*(1./3))));
    pass=pass&&bias>1e-5&&mixtureError<1e-5;
    // 同一张未曝光PFM用于不同曝光/曲线的离线预览，证明显示变换无需重新追踪。
    std::printf("wrong-vs-clean MSE=%.9g mixed-formula maxError=%.3g fence=%llu/%llu\n",bias,mixtureError,(unsigned long long)fence->GetCompletedValue(),(unsigned long long)gpu.last_fence());
    return pass;
}
