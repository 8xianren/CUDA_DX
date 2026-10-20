// R.13.8a：CPU数值实验与真实DXR PFM的显示。沿用nvcc/sm_120构建入口，未启动CUDA kernel。
// 文件解析/结果输出属于本课验证层；显示数学单独放在dxr_display_reference.h，避免混入宿主渲染代码。
#include "dxr_display_reference.h"
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <string>
#include <vector>
namespace fs=std::filesystem;
namespace dr=display_reference;

struct Image {unsigned width,height;std::vector<float> rgb;};
// 只接受本仓库生成的PF / -1.0 / little-endian float32 PFM；不是通用图片加载器。
// PFM文件行从底部开始，加载后转成顶部第一行，RGB连续、每像素12字节，无行padding。
// 返回对象拥有vector；ifstream析构自动关闭。坏头、截断、NaN/Inf/负值均拒绝。
Image read_pfm(const fs::path& path) {
    std::ifstream in(path,std::ios::binary);dr::require(bool(in),"Cannot open input PFM; run R.13.7 first");
    std::string magic;unsigned w=0,h=0;double scale=0;
    in>>magic>>w>>h>>scale;
    dr::require(bool(in)&&magic=="PF"&&scale==-1&&w>0&&h>0&&w<=4096&&h<=4096,"Unsupported PFM header");
    char newline=0;in.get(newline);if(newline=='\r')in.get(newline);
    dr::require(newline=='\n',"Invalid PFM header terminator");
    Image image{w,h,std::vector<float>(size_t(w)*h*3)};
    for(unsigned row=h;row>0;--row)
        in.read(reinterpret_cast<char*>(image.rgb.data()+size_t(row-1)*w*3),size_t(w)*3*sizeof(float));
    dr::require(bool(in),"Truncated PFM payload");dr::require(in.peek()==EOF,"Unexpected PFM trailing data");
    for(float v:image.rgb)dr::require(std::isfinite(v)&&v>=0,"Invalid PFM radiance");
    return image;
}
// BMP使用显式小端字段，避免直接序列化C++结构引入padding；RGB转BGR且行对齐4字节。
// 这里只写不带profile的8-bit SDR诊断文件，查看器按sRGB显示是本课预览约定。
void write_bmp(const fs::path& path,unsigned w,unsigned h,const std::vector<uint8_t>& rgb) {
    std::ofstream out(path,std::ios::binary);dr::require(bool(out),"Cannot create BMP");
    auto u16=[&](unsigned n){out.put(char(n));out.put(char(n>>8));};
    auto u32=[&](unsigned n){u16(n&65535);u16(n>>16);};
    unsigned stride=(w*3+3)&~3u,bytes=stride*h;
    out.put('B');out.put('M');u32(54+bytes);u32(0);u32(54);
    u32(40);u32(w);u32(h);u16(1);u16(24);u32(0);u32(bytes);u32(2835);u32(2835);u32(0);u32(0);
    for(unsigned row=h;row>0;--row){
        for(unsigned x=0;x<w;++x){size_t i=(size_t(row-1)*w+x)*3;out.put(char(rgb[i+2]));out.put(char(rgb[i+1]));out.put(char(rgb[i]));}
        for(unsigned p=w*3;p<stride;++p)out.put(0);
    }
    out.flush();dr::require(bool(out),"BMP write failed");
}
int main(int argc,char** argv) try {
    dr::require(argc<=2,"Usage: dxr_display_probe.exe [input.pfm]");
    // 输出从exe位置定位，不随工作目录散落；输入可显式指定，默认复用上节真实DXR结果。
    fs::path base=fs::absolute(argv[0]).parent_path(),folder=base/"results"/"r13-08a";
    fs::create_directories(folder);
    std::ofstream log(folder/"validation.txt"),csv(folder/"display_values.csv");
    dr::require(bool(log)&&bool(csv),"Cannot create result logs");
    auto record=[&](const std::string& s){std::cout<<s<<'\n';log<<s<<'\n';};
    auto check=[&](bool ok,const char* what){dr::require(ok,what);};
    check(dr::exposure_multiplier(0)==1&&dr::exposure_multiplier(1)==2&&dr::exposure_multiplier(-1)==0.5,"EV relation");
    check(dr::reinhard(0)==0&&dr::reinhard(1)==0.5,"Tone anchors");
    check(dr::quantize8(dr::srgb_encode(0.5))==188,"Linear half must encode to 188");
    check(dr::quantize8(0.5)==128,"Missing encoding control must give 128");
    check(dr::quantize8(dr::srgb_encode(dr::srgb_encode(0.5)))==223,"Double encoding control must give 223");
    double maxRoundtrip=0,maxQuantized=0,previous=-1;
    // 扫描码域和线性域，检查单调性、逆变换与量化误差；包含sRGB低端线性段。
    for(unsigned i=0;i<=100000;++i){double x=i/100000.0,e=dr::srgb_encode(x);
        check(e>=previous,"Non-monotonic sRGB");previous=e;
        maxRoundtrip=std::max(maxRoundtrip,std::abs(dr::srgb_decode(e)-x));
        maxQuantized=std::max(maxQuantized,std::abs(dr::quantize8(e)/255.0-e));
    }
    // 标准阈值经过十进制舍入，接缝附近不要求机器精度的完全互逆。
    for(double x:{0.0,0.0031308-1e-9,0.0031308,0.0031308+1e-9,1.0})
        maxRoundtrip=std::max(maxRoundtrip,std::abs(dr::srgb_decode(dr::srgb_encode(x))-x));
    check(maxRoundtrip<3e-9&&maxQuantized<=0.5/255+1e-14,"Roundtrip / quantization bound");
    unsigned rejected=0;for(double x:{-1.0,std::numeric_limits<double>::infinity(),std::numeric_limits<double>::quiet_NaN()})
        try{dr::display_byte(x,0);}catch(const std::exception&){++rejected;}
    check(rejected==3,"Invalid history rejection");
    csv<<"history,compensation_ev,exposed,tone_linear,srgb_code,byte\n"<<std::setprecision(12);
    for(double ev:{-1.,0.,1.})for(double h:{0.,0.003,0.18,0.5,1.,4.,16.}){
        double t=dr::display_linear(h,ev),s=dr::srgb_encode(t);
        csv<<h<<','<<ev<<','<<h*dr::exposure_multiplier(ev)<<','<<t<<','<<s<<','<<unsigned(dr::quantize8(s))<<'\n';
    }
    Image image=read_pfm(argc==2?fs::path(argv[1]):base/"results"/"r13-07"/"correct-reset.pfm");
    // 两行三列：上排0/1/2次sRGB；下排正确sRGB、EV=-1/0/+1。无重采样光照，无修改历史。
    // 最近邻放大3倍仅为了观察；8像素灰色间隔。全部160x96数据保留，未隐藏视口外像素。
    const unsigned zoom=3,gap=8,pw=image.width*zoom,ph=image.height*zoom,w=3*pw+4*gap,h=2*ph+3*gap;
    std::vector<uint8_t> pixels(size_t(w)*h*3,32);
    for(unsigned panel=0;panel<6;++panel)for(unsigned y=0;y<ph;++y)for(unsigned x=0;x<pw;++x){
        double ev=panel<3?0:double(panel)-4;
        for(unsigned c=0;c<3;++c){
            double v=dr::display_linear(image.rgb[(size_t(y/zoom)*image.width+x/zoom)*3+c],ev);
            unsigned times=panel<3?panel:1;for(unsigned i=0;i<times;++i)v=dr::srgb_encode(v);
            unsigned ox=gap+(panel%3)*(pw+gap)+x,oy=gap+(panel/3)*(ph+gap)+y;
            pixels[(size_t(oy)*w+ox)*3+c]=dr::quantize8(v);
        }
    }
    write_bmp(folder/"display_comparison.bmp",w,h,pixels);
    record("CPU display probe (no GPU dispatch)");
    record("linear 0.5: missing=128 correct=188 double=223");
    record("roundtrip_max="+std::to_string(maxRoundtrip)+" (bound 3e-9; precise values below)");
    log<<std::setprecision(15)<<"roundtrip_precise="<<maxRoundtrip<<" quantization_code_error="<<maxQuantized<<'\n';
    record("100001-point sweep + threshold anchors PASS; invalid inputs rejected=3");
    record("Top: missing / correct / double sRGB. Bottom: EV -1 / 0 / +1, correct sRGB.");
    record("R.13.8a PASS");
    log.flush();csv.flush();dr::require(bool(log)&&bool(csv),"Result write failed");return 0;
} catch(const std::exception& e){std::cerr<<"R.13.8a FAIL: "<<e.what()<<'\n';return 1;}
