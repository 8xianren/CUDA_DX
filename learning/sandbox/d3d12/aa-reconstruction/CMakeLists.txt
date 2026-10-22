cmake_minimum_required(VERSION 3.24)
project(aa_reconstruction LANGUAGES CXX)
# F只复用C/D的低层设备/资源功能，不需要为光栅实验构建Assimp或人物模块。
add_library(f_core STATIC ../gltf-scene/src/gpu_upload.cpp src/gpu_resources.cpp src/scene.cpp src/post_chain.cpp src/sdk_upscalers.cpp)
target_compile_features(f_core PUBLIC cxx_std_17)
target_compile_definitions(f_core PUBLIC NOMINMAX WIN32_LEAN_AND_MEAN UNICODE _UNICODE)
target_compile_options(f_core PUBLIC /utf-8 /W3)
target_include_directories(f_core PUBLIC src ../gltf-scene/src external/nis/NIS
 build/deps/fidelityfx-source/FidelityFX-SDK-2.3.0/Kits/FidelityFX/api/include
 build/deps/fidelityfx-source/FidelityFX-SDK-2.3.0/Kits/FidelityFX/upscalers/include
 build/deps/xess/inc)
target_link_libraries(f_core PUBLIC d3d12 dxgi dxguid d3dcompiler windowscodecs ole32 user32)
add_executable(f_lessons src/main.cpp)
target_link_libraries(f_lessons PRIVATE f_core)
add_executable(f_sdk_probe src/sdk_probe.cpp)
target_link_libraries(f_sdk_probe PRIVATE f_core)
