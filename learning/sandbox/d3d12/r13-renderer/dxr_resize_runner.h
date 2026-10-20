#pragma once
#include "dxr_window_display.h"
// R.13.8c：真实WM_SIZE/ResizeBuffers生命周期验收。固定内部history，输出尺寸与积分目标分开。
// 每阶段最后一帧故意保留未退役的提交；下一阶段先排空、清除旧命令，再释放尺寸相关资源。
inline bool run_resize(IDXGIFactory6* factory,ID3D12Device5* dev,ID3D12CommandQueue* queue,ID3D12Fence* fence,
    ID3D12RootSignature* root,ID3D12StateObject* state,ID3D12Resource* tlas,ID3D12Resource* vb,ID3D12Resource* ib,
    ID3D12Resource* sbt,const std::function<void(UINT64)>& waitFor,const std::filesystem::path& folder){
    WindowDisplay display(factory,dev,queue,folder.parent_path().parent_path(),true);
    GpuRaySequence gpu(dev,queue,fence,root,state,tlas,vb,ib,sbt,waitFor);
    history_policy::Settings settings;history_policy::Tracker tracker;history_reference::Verify reference;
    struct Stage{UINT w,h;const char* name;bool reset;};
    const Stage stages[]={{480,270,"initial",true},{641,359,"odd-size",false},{321,481,"portrait",false},
        {321,481,"restore-same-size",false},{800,200,"wide-new-view",true},{800,200,"same-size-old-view",true},
        {480,270,"original-size",false},{120,1,"one-row",false}};
    // 本机带标题栏窗口将1像素客户区宽度约束到120；使用真实可达的120x1窗口，内接显示区仍1x1。
    std::ofstream csv(folder/"resize_events.csv");require(bool(csv),"Open resize CSV");
    csv<<"stage,frame,width,height,history_count,epoch,reset_reason,resource_generation\n";
    bool pass=true;unsigned frame=0,count=0,resets=0,skipped=0;
    for(unsigned stage=0;stage<8;++stage){const auto& s=stages[stage];
        if(stage==3){
            display.minimize();require(display.pump()&&display.suspended(),"Minimize message missing");
            // 先收束上一帧，之后暂停期间不派发、不Present、不Signal、不增加采样数。
            gpu.discard_recordings();auto before=gpu.last_fence();
            for(unsigned tick=0;tick<3;++tick){require(display.pump()&&display.suspended(),"Unexpected restore during pause");
                require(!display.apply_resize(),"Minimized window must not ResizeBuffers");++skipped;
                MsgWaitForMultipleObjectsEx(0,nullptr,16,QS_ALLINPUT,MWMO_INPUTAVAILABLE);}
            require(gpu.last_fence()==before,"Minimized window submitted GPU work");
            display.restore();require(display.pump()&&!display.suspended(),"Restore message missing");
            std::printf("minimize skipped=%u unchangedFence=%llu\n",skipped,(unsigned long long)before);
        }
        // 合并尺寸意图：回调只存最后尺寸，真正重建发生在渲染线程安全点。
        display.request_client_size(s.w,s.h);require(display.pump()&&!display.suspended(),"Unexpected closed/zero window");
        gpu.discard_recordings();display.apply_resize();
        require(display.width()==s.w&&display.height()==s.h,"Requested client size not applied");
        if(stage==4){settings.camera.x=20;settings.camera.y=3;settings.camera.w=120;settings.camera.h=90;}
        if(stage==5)settings.camera=progressive_reference::camera();
        if(s.reset)count=0;
        for(unsigned j=0;j<8;++j,++frame){
            auto input=history_policy::submission(settings,frame,frame+1);auto decision=tracker.schedule(history_policy::key(input));
            bool reset=s.reset&&j==0;++count;
            require(decision.count==count&&bool(decision.reasons)==reset,"Resize/history policy mismatch");
            if(reset)++resets;input.controls[3]=decision.previousCount;
            auto constants=display.constants(settings.camera,0);
            auto snapshot=j==7?folder/(std::string(s.name)+".ppm"):std::filesystem::path{};
            csv<<s.name<<','<<frame+1<<','<<display.width()<<','<<display.height()<<','<<count<<','<<decision.epoch<<','
                <<history_policy::reason_text(decision.reasons)<<','<<display.resizes()<<'\n';
            gpu.enqueue(input,[&,settings,count,reset,constants,snapshot](const progressive_reference::Record* records,const RaySubmission& submitted){
                reference.consume(records,submitted,settings,count,reset,reset);pass=display.verify(records,constants,snapshot)&&pass;
            },[&](ID3D12GraphicsCommandList4* list,ID3D12Resource* history){display.record(list,history,constants);},[&]{display.present();});
            if(j<7)gpu.flush(); // 最后一帧留给下一阶段的安全点退役，验证旧尺寸下读回后才resize。
        }
        std::printf("resize stage=%s history=%u epoch=%u generation=%u\n",s.name,count,resets,display.resizes());
    }
    gpu.flush();pass=reference.finish("resize HDR")&&pass;pass=display.finish(64)&&pass;
    csv.flush();require(bool(csv),"Resize CSV write failed");
    std::printf("resize summary frames=%u resets=%u rebuilds=%u skipped=%u fence=%llu/%llu\n",frame,resets,display.resizes(),skipped,
        (unsigned long long)fence->GetCompletedValue(),(unsigned long long)gpu.last_fence());
    return pass&&frame==64&&resets==3&&display.resizes()==5&&skipped==3;
}
