#include "cpu_material.h"
#include <assimp/scene.h>
#include <assimp/material.h>
#include <assimp/GltfMaterial.h>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <unordered_map>
#include <cmath>
#include <utility>
static int Wrap(aiTextureMapMode mode) {
    if(mode==aiTextureMapMode_Wrap) return 10497;
    if(mode==aiTextureMapMode_Clamp) return 33071;
    if(mode==aiTextureMapMode_Mirror) return 33648;
    throw std::runtime_error("unsupported texture address mode");
}
MaterialAssets CopyMaterialAssets(const aiScene& scene,const std::string& modelPath) {
    MaterialAssets out;
    std::unordered_map<std::string,int> imageIds;
    const aiTextureType types[]={aiTextureType_BASE_COLOR,aiTextureType_METALNESS,aiTextureType_NORMALS,aiTextureType_LIGHTMAP,aiTextureType_EMISSIVE};
    for(unsigned i=0;i<scene.mNumMaterials;++i) {
        const aiMaterial& src=*scene.mMaterials[i]; CpuMaterial m;
        aiString name; if(src.Get(AI_MATKEY_NAME,name)==AI_SUCCESS) m.name=name.C_Str();
        aiColor4D base(1,1,1,1); src.Get(AI_MATKEY_BASE_COLOR,base); m.baseColor={base.r,base.g,base.b,base.a};
        aiColor3D emission(0,0,0); src.Get(AI_MATKEY_COLOR_EMISSIVE,emission); m.emissive={emission.r,emission.g,emission.b};
        // Get返回失败时保持自有默认值；因子已是线性参数，不再做sRGB解码。
        src.Get(AI_MATKEY_METALLIC_FACTOR,m.metallic); src.Get(AI_MATKEY_ROUGHNESS_FACTOR,m.roughness);
        src.Get(AI_MATKEY_GLTF_ALPHACUTOFF,m.alphaCutoff);
        src.Get(AI_MATKEY_GLTF_TEXTURE_SCALE(aiTextureType_NORMALS,0),m.normalScale);
        // 6.0.2导入器实际写入$tex.file.strength；先尝试标准宏，再兼容固定版本实际键。
        if(src.Get(AI_MATKEY_GLTF_TEXTURE_STRENGTH(aiTextureType_LIGHTMAP,0),m.occlusionStrength)!=AI_SUCCESS)
            src.Get("$tex.file.strength",aiTextureType_LIGHTMAP,0,m.occlusionStrength);
        int sided=0; src.Get(AI_MATKEY_TWOSIDED,sided); m.doubleSided=sided!=0;
        aiString alpha; if(src.Get(AI_MATKEY_GLTF_ALPHAMODE,alpha)==AI_SUCCESS) {
            const std::string mode=alpha.C_Str();
            if(mode=="MASK") m.alpha=AlphaMode::Mask;
            else if(mode=="BLEND") m.alpha=AlphaMode::Blend;
            else if(mode!="OPAQUE") throw std::runtime_error("unknown alpha mode");
        }
        for(int slot=0;slot<5;++slot) {
            auto& binding=m.textures[slot]; binding.srgbRGB=(slot==0||slot==4);
            const auto type=types[slot];
            if(src.GetTextureCount(type)==0) continue;
            if(src.GetTextureCount(type)>1) throw std::runtime_error("multiple texture layers unsupported");
            aiString path; aiTextureMapping mapping=aiTextureMapping_UV;
            aiTextureMapMode modes[3]={aiTextureMapMode_Wrap,aiTextureMapMode_Wrap,aiTextureMapMode_Wrap};
            // type/0选择用途的第一层；path和uvSet为输出；blend/op不用；mapmode预留三个轴。
            if(src.GetTexture(type,0,&path,&mapping,&binding.uvSet,nullptr,nullptr,modes)!=AI_SUCCESS)
                throw std::runtime_error("texture lookup failed");
            if(mapping!=aiTextureMapping_UV || binding.uvSet!=0) throw std::runtime_error("C.5 only supports UV0");
            aiUVTransform transform;
            if(src.Get(AI_MATKEY_UVTRANSFORM(type,0),transform)==AI_SUCCESS)
                throw std::runtime_error("texture transform extension deferred; cannot silently ignore");
            binding.wrapU=Wrap(modes[0]); binding.wrapV=Wrap(modes[1]);
            src.Get(AI_MATKEY_GLTF_MAPPINGFILTER_MIN(type,0),binding.minFilter);
            src.Get(AI_MATKEY_GLTF_MAPPINGFILTER_MAG(type,0),binding.magFilter);
            const std::string reference=path.C_Str();
            auto found=imageIds.find(reference);
            if(found==imageIds.end()) {
                CpuImage image; image.source=reference;
                if(const aiTexture* embedded=scene.GetEmbeddedTexture(reference.c_str())) {
                    if(embedded->mHeight!=0) throw std::runtime_error("raw embedded texels deferred");
                    if(embedded->mWidth>64u*1024u*1024u) throw std::runtime_error("encoded image exceeds adapter limit 64 MiB");
                    // mHeight==0时mWidth是压缩/编码数据字节数，不是图像像素宽度。
                    const auto* bytes=reinterpret_cast<const uint8_t*>(embedded->pcData);
                    image.encodedBytes.assign(bytes,bytes+embedded->mWidth);
                } else {
                    auto absolute=(std::filesystem::path(modelPath).parent_path()/std::filesystem::path(reference)).lexically_normal();
                    std::ifstream file(absolute,std::ios::binary);
                    if(!file) throw std::runtime_error("missing referenced image: "+absolute.string());
                    file.seekg(0,std::ios::end);
                    auto length=file.tellg();
                    if(length<0 || length>64ll*1024*1024) throw std::runtime_error("encoded image size invalid or exceeds 64 MiB");
                    file.seekg(0);
                    image.encodedBytes.assign(std::istreambuf_iterator<char>(file),{});
                    if(file.bad()) throw std::runtime_error("image read failed: "+absolute.string());
                }
                if(image.encodedBytes.empty()) throw std::runtime_error("empty image");
                binding.image=static_cast<int>(out.images.size()); imageIds.emplace(reference,binding.image);
                out.images.push_back(std::move(image));
            } else binding.image=found->second;
        }
        for(float x:m.baseColor) if(!std::isfinite(x)) throw std::runtime_error("nonfinite baseColor");
        for(float x:m.emissive) if(!std::isfinite(x)) throw std::runtime_error("nonfinite emissive");
        for(float x:{m.metallic,m.roughness,m.normalScale,m.occlusionStrength,m.alphaCutoff})
            if(!std::isfinite(x)) throw std::runtime_error("nonfinite material scalar");
        // 当前glTF核心参数的语义检查。有限数仍可能超出合法范围，不静默clamp美术输入。
        for(float x:m.baseColor) if(x<0||x>1) throw std::runtime_error("baseColor outside [0,1]");
        for(float x:{m.metallic,m.roughness,m.occlusionStrength})
            if(x<0||x>1) throw std::runtime_error("material factor outside [0,1]");
        if(m.alphaCutoff<0) throw std::runtime_error("negative alpha cutoff");
        out.materials.push_back(std::move(m));
    }
    return out; // 所有编码字节、字符串与因子已独立复制；没有aiMaterial/aiTexture借用指针。
}
