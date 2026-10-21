// 本节是CPU解析参考实验：沿用nvcc/sm_120构建入口，但没有CUDA kernel或DXR调用。
#include "path_loop.h"
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
using namespace throughput;
void Require(bool ok,const char* text){if(!ok)throw std::runtime_error(text);}
int main(int argc,char** argv){
    try{
        if(argc!=2)throw std::runtime_error("usage: throughput_test results-directory");
        std::filesystem::path out=argv[1];std::filesystem::create_directories(out);
        std::ofstream summary(out/"summary.csv"),depthFile(out/"depths.csv"),traceFile(out/"trace.csv");
        Require(bool(summary)&&bool(depthFile)&&bool(traceFile),"cannot create outputs");
        summary<<"mode,max_scatters,channel,mean,analytic_finite,analytic_infinite,seed_mean_SE\n"<<std::setprecision(15);
        depthFile<<"mode,depth,paths,beta_r,beta_g,beta_b\n"<<std::setprecision(15);
        traceFile<<"depth,beta_before_r,beta_before_g,beta_before_b,add_r,sum_r,cosine,pdf,distance,beta_after_r\n"<<std::setprecision(15);
        const RGB rho{.6,.4,.2},emission{.1,.2,.3};constexpr int maxDepth=16,seeds=8,pathsPerSeed=8192;
        const char* names[]={"cosine","uniform","wrong_missing_pdf","wrong_emission_order"};
        double maxResidual=0,maxCosineError=0;uint64_t segments=0;double uniformAt8=0,missingAt8=0,orderAt8=0;
        for(int modeIndex=0;modeIndex<4;++modeIndex){
            Mode mode=static_cast<Mode>(modeIndex);
            std::array<RGB,maxDepth+1> seedMean{},seedM2{},betaSum{};
            for(int seed=0;seed<seeds;++seed){
                std::array<RGB,maxDepth+1> sums{};
                for(int path=0;path<pathsPerSeed;++path){
                    auto records=Trace(rho,emission,maxDepth,mode,0x12345678ULL+seed*7919,path+1);
                    for(int d=0;d<=maxDepth;++d){auto& r=records[d];maxResidual=std::max(maxResidual,r.sphereResidual);
                        for(int c=0;c<3;++c){sums[d][c]+=r.sum[c];betaSum[d][c]+=r.betaBefore[c];}
                        if(d<maxDepth)++segments;
                        if(mode==Mode::Cosine){auto exact=Analytic(rho,emission,d);
                            for(int c=0;c<3;++c)maxCosineError=std::max(maxCosineError,std::abs(r.sum[c]-exact[c]));}
                        if(mode==Mode::Uniform&&seed==0&&path==0)traceFile<<d<<','<<r.betaBefore[0]<<','<<r.betaBefore[1]<<','<<r.betaBefore[2]
                            <<','<<r.contribution[0]<<','<<r.sum[0]<<','<<r.cosine<<','<<r.pdf<<','<<r.distance<<','<<r.betaAfter[0]<<'\n';
                    }
                }
                for(int d=0;d<=maxDepth;++d)for(int c=0;c<3;++c){double mean=sums[d][c]/pathsPerSeed;
                    // Welford按seed统计：避免近乎零方差时E[x²]-E[x]²的相消误差。
                    double delta=mean-seedMean[d][c];seedMean[d][c]+=delta/(seed+1);
                    seedM2[d][c]+=delta*(mean-seedMean[d][c]);}
            }
            for(int d=0;d<=maxDepth;++d){
                depthFile<<names[modeIndex]<<','<<d<<','<<seeds*pathsPerSeed;
                for(int c=0;c<3;++c)depthFile<<','<<betaSum[d][c]/(seeds*pathsPerSeed);depthFile<<'\n';
                auto exact=Analytic(rho,emission,d);
                for(int c=0;c<3;++c){double mean=seedMean[d][c];
                    double variance=std::max(0.,seedM2[d][c]/(seeds-1));
                    double se=std::sqrt(variance/seeds),expected=exact[c];
                    if(mode==Mode::WrongEmissionOrder)expected*=rho[c];
                    if(mode==Mode::WrongMissingPdf){double a=rho[c]/(2*mis::pi);expected=emission[c]*(1-std::pow(a,d+1))/(1-a);}
                    Require(std::abs(mean-expected)<6*se+1e-10,"mean outside analytic regression tolerance");
                    summary<<names[modeIndex]<<','<<d<<','<<c<<','<<mean<<','<<exact[c]<<','<<emission[c]/(1-rho[c])<<','<<se<<'\n';
                    if(d==8&&c==0){std::cout<<std::setprecision(12)<<names[modeIndex]<<" K=8 red_mean="<<mean<<" SE="<<se<<" correct_reference="<<exact[c]<<'\n';
                        if(mode==Mode::Uniform)uniformAt8=mean;if(mode==Mode::WrongMissingPdf)missingAt8=mean;if(mode==Mode::WrongEmissionOrder)orderAt8=mean;}
                }
            }
        }
        Require(maxCosineError<1e-12,"cosine per-path identity failed");
        Require(uniformAt8-missingAt8>.1&&uniformAt8-orderAt8>.09,"negative controls did not expose dimming");
        auto zero=Trace({0,0,0},emission,2,Mode::Cosine,1,1);
        for(int c=0;c<3;++c)Require(zero.back().sum[c]==emission[c],"black reflecting emitter must still emit");
        std::cout<<"CPU_ONLY segments="<<segments<<" max_sphere_residual="<<maxResidual<<" max_cosine_path_error="<<maxCosineError
            <<" black_reflector_emission=PASS negative_controls=PASS\nTHROUGHPUT PASS\n";
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
    return 0;
}
