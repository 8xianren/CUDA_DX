// R.13.1–2：引擎式相机的纯 CPU 数学验证。沿用 build.ps1/sm_120 编译入口，
// 但不创建 CUDA/D3D12 设备、无 GPU kernel、无上传或 Fence；不能称为 GPU 验收。
// 世界 +X前/+Y右/+Z上，视图 +x右/+y上/+z前。全部矩阵使用行向量 v*M。
#include <DirectXMath.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <stdexcept>
using namespace DirectX;

struct V3 { double x,y,z; };
V3 operator+(V3 a,V3 b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
V3 operator-(V3 a,V3 b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
V3 operator*(V3 a,double s){return {a.x*s,a.y*s,a.z*s};}
double dot(V3 a,V3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
V3 cross(V3 a,V3 b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
double norm(V3 a){return std::sqrt(dot(a,a));}
bool finite(V3 a){return std::isfinite(a.x)&&std::isfinite(a.y)&&std::isfinite(a.z);}
V3 unit(V3 a){double n=norm(a);if(!finite(a)||!std::isfinite(n)||n<1e-12)throw std::runtime_error("zero/invalid direction");return a*(1/n);}
XMVECTOR vec(V3 v,float w){return XMVectorSet(float(v.x),float(v.y),float(v.z),w);}
V3 xyz(FXMVECTOR v){XMFLOAT4 p;XMStoreFloat4(&p,v);return {p.x,p.y,p.z};}
// XMVector4Transform 保留齐次 w。明确做除法，避免把有限点和无穷远方向混淆。
V3 point(FXMVECTOR h){double w=XMVectorGetW(h);V3 p=xyz(h);if(!finite(p)||!std::isfinite(w)||std::fabs(w)<1e-8)throw std::runtime_error("not a finite homogeneous point");return p*(1/w);}
XMMATRIX inverse(FXMMATRIX m){
    // pDeterminant 是 CPU 输出参数，每个 lane 得到相同行列式；M 是输入矩阵。
    // API 不返回 HRESULT，奇异输入可能产生无穷矩阵，因此由调用者验证结果。
    XMVECTOR det;XMMATRIX result=XMMatrixInverse(&det,m);float d=XMVectorGetX(det);
    if(!std::isfinite(d)||std::fabs(d)<1e-12f)throw std::runtime_error("singular matrix");
    XMFLOAT4X4 raw;XMStoreFloat4x4(&raw,result);
    for(int i=0;i<4;++i)for(int j=0;j<4;++j)if(!std::isfinite(raw.m[i][j]))throw std::runtime_error("invalid inverse");
    // 1e-12 是本课小尺度输入下的保护，不是通用矩阵条件数判据。
    return result;
}
struct Rect {double x,y,w,h;};
void valid_rect(Rect r){if(!std::isfinite(r.x)||!std::isfinite(r.y)||!std::isfinite(r.w)||!std::isfinite(r.h)||r.w<=0||r.h<=0)throw std::runtime_error("invalid ViewRect");}
struct Camera {V3 eye,f,r,u; XMMATRIX view;};
Camera camera(V3 eye,V3 forward,V3 up){
    if(!finite(eye))throw std::runtime_error("invalid eye");
    V3 f=unit(forward),r=unit(cross(unit(up),f)),u=cross(f,r);
    // LookTo 接收方向，不是目标位置。这里使用世界Z参考上向；不得照抄Y-up常量。
    // r=up×f；默认f=+X/up=+Z时，r=+Y。绕视线的roll可通过up指定。
    return {eye,f,r,u,XMMatrixLookToLH(vec(eye,1),vec(f,0),vec(u,0))};
}
XMMATRIX projection(double fovY,double aspect,double nearPlane){
    if(!std::isfinite(fovY)||!std::isfinite(aspect)||!std::isfinite(nearPlane)||
       fovY<=0||fovY>=XM_PI||aspect<=0||nearPlane<=0)throw std::runtime_error("invalid projection");
    const float sy=float(1/std::tan(fovY*.5)),sx=float(sy/aspect),n=float(nearPlane);
    // 行向量无限远 reversed-Z 透视：clip=(sx*x,sy*y,n,z)，除w后zN=n/z。
    // near平面z=n→1，z→∞时深度→0；第3行的1使clip.w等于视图z。
    return XMMatrixSet(sx,0,0,0, 0,sy,0,0, 0,0,0,1, 0,0,n,0);
}
struct Ray {V3 origin,direction;double tNear;};
Ray deproject(const Camera& c,FXMMATRIX invVP,Rect rect,double screenX,double screenY,double n){
    valid_rect(rect);
    // 输入是连续屏幕坐标，不是整数像素编号；若输入像素中心，应在调用处加0.5一次。
    const double nx=2*(screenX-rect.x)/rect.w-1,ny=1-2*(screenY-rect.y)/rect.h;
    V3 q=point(XMVector4Transform(XMVectorSet(float(nx),float(ny),1,1),invVP));
    V3 d=unit(q-c.eye);double forward=dot(d,c.f);
    if(!(forward>0))throw std::runtime_error("ray is not forward");
    // 射线原点保留在针孔。为了匹配平面near，不能直接使用固定TMin=n。
    return {c.eye,d,n/forward};
}
int checks=0;
void require(bool ok,const char* label){++checks;if(!ok)throw std::runtime_error(label);}
template<class Fn> void rejected(Fn fn,const char* label){bool failed=false;try{fn();}catch(const std::runtime_error&){failed=true;}require(failed,label);}

int main(){try{
    const double n=.1,fov=XM_PIDIV2;Rect rect{100,50,800,400};
    Camera c=camera({3,-2,1},{1,0,0},{0,0,1});
    XMMATRIX p=projection(fov,rect.w/rect.h,n),vp=XMMatrixMultiply(c.view,p),invVP=inverse(vp);
    // View应将世界点先减eye再分别投影到R/U/F。用double点积作为独立参考。
    double basisError=0,roundTrip=0;
    for(const Camera& cam:{c,camera({3,-2,1},{1,1,.5},{0,0,1})}){
        XMMATRIX invV=inverse(cam.view);
        for(V3 q:{cam.eye,cam.eye+cam.r,cam.eye+cam.u,cam.eye+cam.f,V3{7,0,2}}){
            V3 v=point(XMVector4Transform(vec(q,1),cam.view)),delta=q-cam.eye;
            basisError=std::max(basisError,norm(v-V3{dot(delta,cam.r),dot(delta,cam.u),dot(delta,cam.f)}));
            roundTrip=std::max(roundTrip,norm(point(XMVector4Transform(vec(v,1),invV))-q));
        }
    }
    require(basisError<2e-6&&roundTrip<2e-6,"view basis/roundtrip");
    std::printf("View: max_basis_error=%.3g max_roundtrip=%.3g PASS\n",basisError,roundTrip);
    V3 world{7,0,2},view=point(XMVector4Transform(vec(world,1),c.view));
    XMVECTOR clip=XMVector4Transform(vec(world,1),vp);V3 ndc=point(clip);
    double screenX=rect.x+(ndc.x+1)*.5*rect.w,screenY=rect.y+(1-ndc.y)*.5*rect.h;
    Ray ray=deproject(c,invVP,rect,screenX,screenY,n);
    V3 reconstructed=point(XMVector4Transform(vec(ndc,1),invVP));
    double lineError=norm(cross(world-ray.origin,ray.direction));
    require(norm(view-V3{2,1,4})<1e-6&&std::fabs(screenX-600)<1e-4&&std::fabs(screenY-200)<1e-4,"known screen point");
    require(norm(reconstructed-world)<1e-5&&lineError<1e-5,"project/unproject line");
    std::printf("Known world=(7,0,2) view=(%.6f,%.6f,%.6f)\n",view.x,view.y,view.z);
    std::printf("clip=(%.6f,%.6f,%.6f,%.6f) ndc=(%.6f,%.6f,%.6f) screen=(%.6f,%.6f)\n",xyz(clip).x,xyz(clip).y,xyz(clip).z,double(XMVectorGetW(clip)),ndc.x,ndc.y,ndc.z,screenX,screenY);
    std::printf("ray D=(%.8f,%.8f,%.8f) tNear=%.8f line_error=%.3g\n",ray.direction.x,ray.direction.y,ray.direction.z,ray.tNear,lineError);
    // 同屏幕位置但zN=1恢复近面点，zN=原深度恢复原表面点。两者不可混同。
    for(double z:{.1,1.,10.,1000.}){
        double depth=point(XMVector4Transform(XMVectorSet(0,0,float(z),1),p)).z;
        require(std::fabs(depth-n/z)<1e-6,"reversed depth");
        std::printf("view_z=%g -> depth=%.8f\n",z,depth);
    }
    XMVECTOR infinity=XMVector4Transform(XMVectorSet(.25f,.25f,0,1),invVP);
    require(std::fabs(XMVectorGetW(infinity))<1e-7,"infinite endpoint w");
    require(norm(unit(xyz(infinity))-ray.direction)<1e-5,"infinite direction");
    rejected([&]{point(infinity);},"infinity must not divide");
    std::printf("zN=0 -> homogeneous w=%.8f (direction, not finite point) PASS\n",double(XMVectorGetW(infinity)));
    // 离轴60度射线与near平面的相交距离应为2n；固定n仅到前向深度n/2。
    V3 d60=c.f*.5+c.r*(std::sqrt(3.)*.5);double t60=n/dot(d60,c.f);
    require(std::fabs(t60-.2)<1e-12,"off axis near");
    std::printf("60deg: plane near=%.3f tNear=%.3f; fixed t=near gives forward_z=%.3f\n",n,t60,n*dot(d60,c.f));
    // 两套矩阵相机覆盖旋转、平移、FOV和纵横比。全部像素对照解析方向，非GPU测试。
    double maxDirection=0,maxPlane=0,maxNearDirection=0;int pixels=0;
    for(int mode=0;mode<2;++mode){
        Camera cam=mode?camera({3,-2,1},{1,1,.5},{0,0,1}):c;
        unsigned w=mode?257:320,h=mode?257:180;Rect rr{37,19,double(w),double(h)};
        double fy=mode?50*XM_PI/180:60*XM_PI/180,a=rr.w/rr.h;
        XMMATRIX iv=inverse(XMMatrixMultiply(cam.view,projection(fy,a,n)));
        XMMATRIX fartherNear=inverse(XMMatrixMultiply(cam.view,projection(fy,a,1.0)));
        for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x){
            const double u=(x+.5)/w,v=(y+.5)/h;
            Ray r=deproject(cam,iv,rr,rr.x+x+.5,rr.y+y+.5,n);
            V3 expected=unit(cam.f+cam.r*((2*u-1)*a*std::tan(fy*.5))+cam.u*((1-2*v)*std::tan(fy*.5)));
            maxDirection=std::max(maxDirection,norm(r.direction-expected));
            V3 nearPoint=point(XMVector4Transform(XMVectorSet(float(2*u-1),float(1-2*v),1,1),iv));
            maxPlane=std::max(maxPlane,std::fabs(dot(nearPoint-cam.eye,cam.f)-n));
            Ray r2=deproject(cam,fartherNear,rr,rr.x+x+.5,rr.y+y+.5,1.0);
            maxNearDirection=std::max(maxNearDirection,norm(r.direction-r2.direction));++pixels;
        }
    }
    require(maxDirection<2e-5&&maxPlane<2e-6&&maxNearDirection<2e-5,"pixel ray references");
    std::printf("%d pixel rays: max_direction=%.3g max_near_plane=%.3g near_change_direction=%.3g PASS\n",pixels,maxDirection,maxPlane,maxNearDirection);
    // 可预期的坏输入必须显式失败；没有异步工作、堆资源或需要释放的GPU对象。
    rejected([&]{camera({0,0,0},{0,0,0},{0,0,1});},"zero forward");
    rejected([&]{camera({0,0,0},{0,0,1},{0,0,1});},"parallel up");
    rejected([&]{projection(0,1,n);},"zero FOV");
    rejected([&]{projection(XM_PI,1,n);},"180deg FOV");
    rejected([&]{projection(fov,0,n);},"zero aspect");
    rejected([&]{projection(fov,1,0);},"zero near");
    rejected([&]{valid_rect({0,0,0,100});},"empty rect");
    rejected([&]{inverse(XMMatrixSet(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0));},"singular input");
    std::printf("All %d grouped checks PASS (CPU DirectXMath; no GPU dispatch).\n",checks);return 0;
}catch(const std::exception& e){std::fprintf(stderr,"FAIL: %s\n",e.what());return 1;}}
