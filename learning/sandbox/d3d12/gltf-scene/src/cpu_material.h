#pragma once
#include <array>
#include <cstdint>
#include <string>
#include <vector>
struct aiScene;
enum class TextureRole { BaseColor, MetallicRoughness, Normal, Occlusion, Emissive };
enum class AlphaMode { Opaque, Mask, Blend };
struct CpuImage {
    std::string source;
    std::vector<uint8_t> encodedBytes; // PNG/JPEG等编码字节，不是已解码RGBA像素；D阶段再解码上传。
};
struct TextureBinding {
    int image=-1; // 无纹理时为-1，与引用存在但文件缺失严格区分。
    unsigned uvSet=0;
    bool srgbRGB=false; // 按用途决定RGB解释；alpha始终线性，不对它作sRGB转换。
    int wrapU=10497,wrapV=10497; // glTF数值：REPEAT/CLAMP_TO_EDGE/MIRRORED_REPEAT。
    int minFilter=0,magFilter=0; // 0表示源未指定，D阶段选择并记录渲染器策略。
};
struct CpuMaterial {
    std::string name;
    std::array<float,4> baseColor{1,1,1,1};
    std::array<float,3> emissive{0,0,0};
    float metallic=1,roughness=1,normalScale=1,occlusionStrength=1,alphaCutoff=.5f;
    AlphaMode alpha=AlphaMode::Opaque;
    bool doubleSided=false;
    std::array<TextureBinding,5> textures; // 顺序对应TextureRole；一槽一种用途，不等于五张独立图像。
};
struct MaterialAssets {std::vector<CpuMaterial> materials;std::vector<CpuImage> images;};
// 当前适配的是glTF核心metallic-roughness语义；不承诺任意FBX材质可无损映射。
MaterialAssets CopyMaterialAssets(const aiScene& source,const std::string& modelPath);
