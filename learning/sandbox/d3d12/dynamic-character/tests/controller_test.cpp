#include "simulation/character_controller.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <set>
using namespace character;
static void Need(bool ok,const char* text){if(!ok)throw std::runtime_error(text);}
int main(int argc,char** argv){try{
    Need(argc==2,"controller_test output");std::filesystem::create_directories(argv[1]);
    std::ofstream log(std::filesystem::path(argv[1])/"states.csv");log<<"tick,state,x,y,z,vy,grounded\n";
    CharacterState baseline;std::set<Motion> seen;
    for(unsigned fps:{30u,60u,144u}){
        CharacterController body;FixedClock clock(body.Config().step);
        for(unsigned frame=0;frame<fps*16;++frame)clock.Advance(1.0/fps,[&](uint64_t){
            body.Step(DemoIntent(body.State(),body.Config().step));const auto& s=body.State();
            Need(s.position.y>=0,"ground penetration");seen.insert(s.motion);
            if(fps==30)log<<s.tick<<','<<MotionName(s.motion)<<','<<s.position.x<<','<<s.position.y<<','<<s.position.z<<','<<s.velocity.y<<','<<s.grounded<<'\n';
        });
        Need(clock.Ticks()==1920&&body.State().tick==1920,"fixed step count mismatch");
        if(fps==30)baseline=body.State();else Need(body.State().position.x==baseline.position.x&&body.State().position.y==baseline.position.y&&body.State().motion==baseline.motion,"render cadence altered simulation");
    }
    Need(seen.size()==6,"missing motion state");
    CharacterController jump;double worst=0;unsigned landedTick=0;
    for(unsigned i=0;i<180;++i){CharacterIntent intent;intent.jumpPressed=i==0;jump.Step(intent);
        double t=(i+1)*jump.Config().step;double expected=std::max(0.0,jump.Config().jumpSpeed*t-.5*jump.Config().gravity*t*t);
        worst=std::max(worst,std::abs(jump.State().position.y-expected));
        if(jump.State().motion==Motion::Land&&!landedTick)landedTick=i+1;
    }
    Need(worst<1e-4&&landedTick==unsigned(std::ceil(2*jump.Config().jumpSpeed/jump.Config().gravity/jump.Config().step)),"jump analytic/contact reference");
    bool invalid=false;try{CharacterIntent bad;bad.x=NAN;jump.Step(bad);}catch(...){invalid=true;}Need(invalid,"invalid intent accepted");
    std::ofstream report(std::filesystem::path(argv[1])/"summary.json");report<<"{\"pass\":true,\"fixed_steps_per_run\":1920,\"render_cadences\":[30,60,144],\"states\":6,\"jump_max_error\":"<<worst<<",\"landed_tick\":"<<landedTick<<"}\n";
    std::cout<<"PASS controller: 3 cadences, 1920 ticks each, 6 states, jump error="<<worst<<'\n';
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
