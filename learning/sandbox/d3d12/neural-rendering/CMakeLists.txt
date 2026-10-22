cmake_minimum_required(VERSION 3.24)
project(neural_rendering LANGUAGES CXX CUDA)
find_package(CUDAToolkit REQUIRED)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_ARCHITECTURES 120)
# CUDA核心不依赖窗口/SDK。CPU参考独立翻译单元，app只通过头文件契约调用。
add_library(g_volume STATIC src/volume/volume.cu src/volume/volume_cpu.cpp)
target_include_directories(g_volume PUBLIC src/volume)
target_link_libraries(g_volume PUBLIC CUDA::cudart)
add_library(g_gaussian STATIC src/gaussian/gaussian.cu src/gaussian/gaussian_cpu.cpp)
target_include_directories(g_gaussian PUBLIC src/gaussian)
target_link_libraries(g_gaussian PUBLIC CUDA::cudart)
add_library(g_graphics STATIC ../gltf-scene/src/gpu_upload.cpp
  ../aa-reconstruction/src/gpu_resources.cpp ../cuda-interop/src/external.cpp
  src/interop/shared_texture.cpp src/app/graphics.cpp src/app/window.cpp)
target_include_directories(g_graphics PUBLIC ../gltf-scene/src ../aa-reconstruction/src
  ../cuda-interop/src src/interop src/app)
target_compile_definitions(g_graphics PUBLIC NOMINMAX WIN32_LEAN_AND_MEAN UNICODE _UNICODE)
target_link_libraries(g_graphics PUBLIC CUDA::cudart d3d12 dxgi dxguid d3dcompiler windowscodecs ole32 user32)
add_executable(g_demo src/app/main.cpp src/app/passes.cpp src/app/bridge.cu)
target_link_libraries(g_demo PRIVATE g_graphics g_volume g_gaussian)
add_executable(g_volume_validate tests/volume/volume_validate.cu)
target_link_libraries(g_volume_validate PRIVATE g_volume)
add_executable(g_gaussian_validate tests/gaussian/verify_gaussian.cpp)
target_link_libraries(g_gaussian_validate PRIVATE g_gaussian)
foreach(target g_volume g_gaussian g_graphics g_demo g_volume_validate g_gaussian_validate)
  target_compile_options(${target} PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:/utf-8;/Zc:preprocessor>
    $<$<COMPILE_LANGUAGE:CUDA>:-Xcompiler=/utf-8;-Xcompiler=/Zc:preprocessor;--extended-lambda;-lineinfo>)
endforeach()
