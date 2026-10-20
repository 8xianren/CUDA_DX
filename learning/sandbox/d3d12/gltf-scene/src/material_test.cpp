#include "cpu_scene.h"
#include <iostream>
#include <cmath>
#include <stdexcept>
static void Check(bool c,const char* s){if(!c)throw std::runtime_error(s);}
static void Near(float a,float b){Check(std::abs(a-b)<1e-6f,"factor mismatch");}
int main(int argc,char** argv) {
    if(argc!=3)return 2;
    try {
        auto scene=LoadCpuScene(argv[1]); // Importer已析构，以下检查全部使用自有材质/图像数据。
        const auto& m=scene.materialAssets.materials.at(scene.meshes.at(0).materialIndex);
        const std::string mode=argv[2];
        if(mode=="defaults") {
            for(float x:m.baseColor)Near(x,1);
            for(float x:m.emissive)Near(x,0);
            Near(m.metallic,1);Near(m.roughness,1);Near(m.alphaCutoff,.5f);
            Check(!m.doubleSided&&m.alpha==AlphaMode::Opaque,"default mode");
            for(const auto& t:m.textures)Check(t.image==-1,"unexpected default texture");
        } else {
            const float expected[]={.8f,.4f,.2f,.6f};
            for(int i=0;i<4;++i)Near(m.baseColor[i],expected[i]);
            Near(m.metallic,.7f);Near(m.roughness,.3f);Near(m.normalScale,.5f);Near(m.occlusionStrength,.4f);
            Near(m.emissive[0],.1f);Near(m.emissive[1],.2f);Near(m.emissive[2],.3f);Near(m.alphaCutoff,.45f);
            Check(m.doubleSided,"double sided");
            Check(m.alpha==(mode=="MASK"?AlphaMode::Mask:mode=="BLEND"?AlphaMode::Blend:AlphaMode::Opaque),"alpha mode");
            Check(scene.materialAssets.images.size()==1,"shared image was duplicated");
            const auto& bytes=scene.materialAssets.images[0].encodedBytes;
            Check(bytes.size()>8&&bytes[0]==137&&bytes[1]==80&&bytes[2]==78&&bytes[3]==71,"PNG bytes not preserved");
            for(int i=0;i<5;++i) {
                const auto& t=m.textures[i];
                Check(t.image==0&&t.uvSet==0,"texture reference");
                Check(t.srgbRGB==(i==0||i==4),"color space role");
                Check(t.wrapU==33071&&t.wrapV==33648&&t.minFilter==9987&&t.magFilter==9729,"sampler mapping");
            }
            std::cout<<"slots=5 sharedImages=1 encodedBytes="<<bytes.size()<<" normalScale="<<m.normalScale<<" occlusionStrength="<<m.occlusionStrength<<'\n';
        }
        std::cout<<"PASS "<<mode<<": owned CPU materials; no pixel decode or GPU sampling\n";
        return 0;
    }catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
}
