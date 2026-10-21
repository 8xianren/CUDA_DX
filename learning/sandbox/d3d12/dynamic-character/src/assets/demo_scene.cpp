#include "assets/demo_scene.h"
#include <algorithm>
#include <initializer_list>
#include <limits>
namespace character {
static Matrix4 Convert(const Mat4& m){Matrix4 out;out.m=m.values;return out;}
static unsigned RegisterAsset(CpuScene& scene,const CpuScene& asset){
    unsigned meshBase=unsigned(scene.meshes.size()),materialBase=unsigned(scene.materialAssets.materials.size()),imageBase=unsigned(scene.materialAssets.images.size());
    scene.materialAssets.images.insert(scene.materialAssets.images.end(),asset.materialAssets.images.begin(),asset.materialAssets.images.end());
    for(auto material:asset.materialAssets.materials){for(auto& t:material.textures)if(t.image>=0)t.image+=imageBase;scene.materialAssets.materials.push_back(material);}
    for(auto mesh:asset.meshes){mesh.materialIndex+=materialBase;scene.meshes.push_back(std::move(mesh));}
    return meshBase;
}
static void PlaceAsset(CpuScene& scene,const CpuScene& asset,unsigned meshBase,Mat4 transform,const char* name="environment"){
    // 静态资产将节点世界矩阵展平为独立实例，保持共享网格；不烘焙顶点或复制每实例网格。
    for(const auto& instance:asset.instances){CpuNode node;node.name=name;node.local=Multiply(Convert(transform),asset.nodes[instance.nodeIndex].world);node.world=node.local;
        node.meshIndices={meshBase+instance.meshIndex};unsigned index=unsigned(scene.nodes.size());scene.nodes.push_back(node);scene.instances.push_back({index,meshBase+instance.meshIndex});}
}
static void Append(CpuScene& scene,const CpuScene& asset,Mat4 transform){PlaceAsset(scene,asset,RegisterAsset(scene,asset),transform);}
static void Quad(CpuScene& scene,const char* name,Vec3 a,Vec3 b,Vec3 c,Vec3 d,std::array<float,4> color,bool light=false,float metal=0){
    CpuMaterial material;material.name=name;material.baseColor=color;material.metallic=metal;material.roughness=metal>.5f?.12f:.7f;if(light)material.emissive={8,7.5f,6.5f};
    unsigned materialIndex=unsigned(scene.materialAssets.materials.size());scene.materialAssets.materials.push_back(material);
    CpuMesh mesh;mesh.materialIndex=materialIndex;mesh.hasNormals=true;mesh.hasUV=true;
    Vec3 e=b-a,f=c-a,n{e.y*f.z-e.z*f.y,e.z*f.x-e.x*f.z,e.x*f.y-e.y*f.x};n.Normalize();
    unsigned i=0;for(Vec3 p:{a,b,c,d}){Vertex v;v.position[0]=p.x;v.position[1]=p.y;v.position[2]=p.z;v.normal[0]=n.x;v.normal[1]=n.y;v.normal[2]=n.z;v.uv[0]=float(i==1||i==2);v.uv[1]=float(i>=2);mesh.vertices.push_back(v);++i;}
    mesh.indices={0,1,2,0,2,3};unsigned meshIndex=unsigned(scene.meshes.size());scene.meshes.push_back(mesh);
    CpuNode node;node.name=name;node.meshIndices={meshIndex};unsigned nodeIndex=unsigned(scene.nodes.size());scene.nodes.push_back(node);scene.instances.push_back({nodeIndex,meshIndex});
}
struct DecorationPlacement {float x,z,height,yaw;};
static void Decorate(CpuScene& scene,const std::filesystem::path& path,std::initializer_list<DecorationPlacement> placements){
    auto object=LoadCpuScene(path.string());float low=std::numeric_limits<float>::max(),high=-low;
    for(const auto& instance:object.instances)for(const auto& vertex:object.meshes[instance.meshIndex].vertices){
        auto p=TransformPoint(object.nodes[instance.nodeIndex].world,vertex.position);low=std::min(low,p[1]);high=std::max(high,p[1]);
    }
    if(!(high-low>1e-6f))throw std::runtime_error("flat decoration bounds");
    // 展示配色是本课明确的材质再创作：岩石用灰褐色、树冠用松绿和少量秋黄。
    // 金属度统一为0，不靠镜面黑块凑反射；粗糙度保持较高以呈现漫反射接地与间接照明。
    const bool rock=path.stem().string().find("rock_")==0;
    for(auto& material:object.materialAssets.materials){
        material.metallic=0;material.roughness=.82f;
        if(rock)material.baseColor=material.name=="grass"?std::array<float,4>{.28f,.33f,.21f,1}:std::array<float,4>{.38f,.34f,.27f,1};
        else if(material.name=="woodBirch")material.baseColor={.64f,.57f,.43f,1};
        else if(material.name=="woodBark")material.baseColor={.22f,.12f,.065f,1};
        else if(material.name=="leafsFall")material.baseColor={.58f,.31f,.08f,1};
        else material.baseColor={.16f,.30f,.12f,1};
    }
    // 一个源文件只加载、注册一次：后续每棵树只添加节点/实例，不重复顶点、材质或贴图。
    // 节点组合仍为placement * sourceWorld，保留源资产的坐标轴与单位转换。
    const unsigned meshBase=RegisterAsset(scene,object);const std::string name=path.stem().string();
    for(const auto& placement:placements){
        const float scale=placement.height/(high-low);
        const Quat rotation{0,std::sin(placement.yaw*.5f),0,std::cos(placement.yaw*.5f)};
        PlaceAsset(scene,object,meshBase,Compose({scale,scale,scale},rotation,{placement.x,-low*scale,placement.z}),name.c_str());
    }
}
CpuScene BuildDemoScene(const Rig& rig,const std::filesystem::path& assets,bool presentation){
    CpuScene scene=rig.scene;
    // 显式的demo配色覆盖，不宣称是原作者材质。角色原始骨架/权重与几何不变。
    // 作者角色标记doubleSided；首版显式重设为已有PT模型支持的单面不透明材质，需检查外表面朝向。
    // 这是本demo材质重创作，不是导入器声称支持双面输运；原始资产数据保持完整。
    for(size_t i=0;i<scene.materialAssets.materials.size();++i){auto& m=scene.materialAssets.materials[i];m.metallic=0;m.roughness=.45f;m.doubleSided=false;
        m.baseColor=i==0?std::array<float,4>{.08f,.16f,.22f,1}:std::array<float,4>{.8f,.22f,.06f,1};}
    if(presentation){
        // 500米宽的接地面让默认机位看到自然地平线，而不是一块悬在黑背景中的小平板。
        // 场景只负责几何与材质；天空辐射和太阳由渲染设置提供，因此这里没有隐藏的顶灯。
        Quad(scene,"meadow-ground",{-250,0,-250},{-250,0,250},{250,0,250},{250,0,-250},{.25f,.28f,.16f,1});
        const auto nature=assets/"nature";
        // 人物周围保留开放活动区域，较高树群退到两侧和后景。高度基于实际世界包围盒，
        // 不是假设每份glTF都以米为单位；小幅旋转/尺度差异减少重复实例的整齐感。
        Decorate(scene,nature/"tree_blocks.glb",{{-4.6f,-3.5f,4.4f,.2f},{-6.4f,-6.3f,5.7f,1.1f},{4.8f,-5.1f,4.6f,-.4f},{7.0f,-8.2f,6.2f,.6f},{-1.0f,-11.5f,4.6f,1.9f}});
        Decorate(scene,nature/"tree_cone_fall.glb",{{-6.6f,-3.9f,3.7f,.7f},{3.2f,-7.7f,4.3f,1.6f},{6.2f,-3.8f,3.5f,-.5f},{-4.0f,-10.0f,4.8f,2.3f}});
        Decorate(scene,nature/"rock_largeA.glb",{{-3.4f,-1.7f,.85f,.3f},{3.5f,-3.2f,1.1f,1.2f},{-5.5f,-5.5f,1.2f,2.5f}});
        Decorate(scene,nature/"rock_smallA.glb",{{-3.9f,1.1f,.35f,.9f},{-2.7f,-2.2f,.45f,2.0f},{2.6f,-3.0f,.4f,1.6f},{4.2f,-2.7f,.48f,-.5f}});
        // plant_bush包含薄片叶子，当前单面输运会出现黑背面；展示先不放入，
        // 待实现明确的双面叶片BSDF后再接入，不能把法线随意翻转冒充透射材质。
        return scene;
    }
    Quad(scene,"ground",{-14,0,-12},{-14,0,12},{22,0,12},{22,0,-12},{.25f,.32f,.20f,1});
    Quad(scene,"area-light",{-5,9,-4},{13,9,-4},{13,9,4},{-5,9,4},{1,1,1,1},true);
    Quad(scene,"reflection-panel",{-1,.01f,1},{-1,.01f,3},{2,.01f,3},{2,.01f,1},{.8f,.85f,.9f,1},false,1);
    auto nature=assets/"nature";unsigned index=0;std::vector<std::filesystem::path> files;
    for(const auto& file:std::filesystem::directory_iterator(nature))if(file.path().extension()==".glb")files.push_back(file.path());
    std::sort(files.begin(),files.end());const Vec3 placements[]={{-3,0,2},{3,0,2},{-3,0,-1},{-3,0,-4},{4,0,-4}};
    for(const auto& file:files){
        auto object=LoadCpuScene(file.string());float low=std::numeric_limits<float>::max(),high=-low;
        for(const auto& instance:object.instances)for(const auto& vertex:object.meshes[instance.meshIndex].vertices){auto p=TransformPoint(object.nodes[instance.nodeIndex].world,vertex.position);low=std::min(low,p[1]);high=std::max(high,p[1]);}
        // Kenney源节点含单位缩放：先量实际世界包围盒再指定布景高度，不能靠文件名猜单位。
        float target=file.filename().string().find("tree")==0?3.f:(file.filename().string().find("plant")==0?.7f:1.f);
        if(!(high-low>1e-6f))throw std::runtime_error("flat decoration bounds");float scale=target/(high-low);
        Vec3 location=placements[index%5];location.y=-low*scale;
        Append(scene,object,Compose({scale,scale,scale},{},location));++index;
    }
    return scene;
}
}
