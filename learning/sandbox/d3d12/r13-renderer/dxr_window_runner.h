#pragma once
#include "dxr_window_display.h"
// R.13.8b验收模式：96帧自动结束。显示用同一GPU历史，不经CPU上传；读回仅用于验证。
// 每帧flush刻意串行化，便于本节专注显示契约；不宣称这是引擎的高吞吐帧调度。
inline bool run_window(IDXGIFactory6* factory,ID3D12Device5* dev,ID3D12CommandQueue* queue,ID3D12Fence* fence,
    ID3D12RootSignature* root,ID3D12StateObject* state,ID3D12Resource* tlas,ID3D12Resource* vb,ID3D12Resource* ib,
    ID3D12Resource* sbt,const std::function<void(UINT64)>& waitFor,const std::filesystem::path& folder){
    WindowDisplay display(factory,dev,queue,folder.parent_path().parent_path());
    GpuRaySequence gpu(dev,queue,fence,root,state,tlas,vb,ib,sbt,waitFor);
    history_policy::Settings settings;history_policy::Tracker tracker;history_reference::Verify reference;
    bool pass=true;unsigned resets=0,completed=0;
    for(unsigned frame=0;frame<96;++frame){
        if(!display.pump()){std::puts("Window closed: validation incomplete");pass=false;break;}
        float ev=frame<32?0.f:frame<64?1.f:-1.f;settings.exposureMultiplier=std::exp2(ev);
        auto input=history_policy::submission(settings,frame,frame+1);auto decision=tracker.schedule(history_policy::key(input));
        if(decision.reasons)++resets;input.controls[3]=decision.previousCount;
        require(decision.count==frame+1,"Display exposure must not reset HDR history");
        auto constants=display.constants(settings.camera,ev);
        auto snapshot=(frame%32==31)?folder/("frame-"+std::to_string(frame+1)+".ppm"):std::filesystem::path{};
        gpu.enqueue(input,[&,settings,frame,constants,snapshot](const progressive_reference::Record* records,const RaySubmission& submitted){
            reference.consume(records,submitted,settings,frame+1,frame==0,frame==0);
            pass=display.verify(records,constants,snapshot)&&pass;
        },[&](ID3D12GraphicsCommandList4* list,ID3D12Resource* history){display.record(list,history,constants);},[&]{display.present();});
        // Fence在Present之后Signal；完成后才读取两个readback或复用单个显示readback。
        gpu.flush();++completed;
        if(frame%32==31)std::printf("window frame=%u history=%u EV=%+.0f epoch=%u\n",frame+1,decision.count,ev,decision.epoch);
    }
    gpu.flush();pass=reference.finish("window HDR")&&pass;pass=display.finish()&&pass;
    std::printf("window resets=%u frames=%u fence=%llu/%llu\n",resets,completed,(unsigned long long)fence->GetCompletedValue(),(unsigned long long)gpu.last_fence());
    return pass&&resets==1&&completed==96;
}
