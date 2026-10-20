#include "cpu_scene.h"
#include <iostream>
#include <stdexcept>
int main(int argc,char** argv) {
    if(argc!=2)return 2;
    try {
        auto scene=LoadCpuScene(argv[1]);
        std::cout<<"meshes="<<scene.meshes.size()<<" instances="<<scene.instances.size()<<'\n';
        for(const auto& d:scene.diagnostics) std::cout<<"NOTICE "<<d<<'\n';
        std::cout<<"ACCEPTED_CPU\n";
        return 0;
    }catch(const std::exception& e){std::cerr<<"REJECTED "<<e.what()<<'\n';return 1;}
}
