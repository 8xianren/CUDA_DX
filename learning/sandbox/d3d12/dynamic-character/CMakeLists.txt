# 由gltf-scene父工程提供scene_model/scene_import/Assimp，H阶段只在本文件组织自己的模块。
enable_language(CUDA)
find_package(CUDAToolkit 13.3 REQUIRED)
set(H_MODEL_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/../gltf-scene/src")

# 动画运行时不链接导入库、CUDA或D3D12。依赖CPU场景值类型和核心数学。
add_library(h_animation STATIC src/animation/animation.cpp)
lesson_target(h_animation)
target_include_directories(h_animation PUBLIC src "${H_MODEL_INCLUDE}")
target_link_libraries(h_animation PUBLIC scene_model)

# Assimp只出现在资产适配层和原始探针，不泄漏到动画运行时的公共头文件。
add_library(h_character_assets STATIC src/assets/character_import.cpp src/assets/demo_scene.cpp)
lesson_target(h_character_assets)
target_link_libraries(h_character_assets PUBLIC h_animation PRIVATE scene_import assimp)

# GPU蒙皮属于渲染执行后端；角色控制器无权接触CUDA指针和显存生命周期。
add_library(h_skin_cuda STATIC src/render/cuda/skin_gpu.cu)
target_include_directories(h_skin_cuda PUBLIC src "${H_MODEL_INCLUDE}")
set_target_properties(h_skin_cuda PROPERTIES CUDA_ARCHITECTURES 120 CUDA_STANDARD 17 CUDA_RUNTIME_LIBRARY Shared)
target_compile_options(h_skin_cuda PRIVATE $<$<COMPILE_LANGUAGE:CUDA>:-Xcompiler=/utf-8>)
target_link_libraries(h_skin_cuda PUBLIC CUDA::cudart)

# 人物控制器可在无窗口、无GPU、无导入库的进程验收。
add_library(h_simulation STATIC src/simulation/character_controller.cpp)
lesson_target(h_simulation)
target_include_directories(h_simulation PUBLIC src)
add_executable(h_controller_test tests/controller_test.cpp)
lesson_target(h_controller_test)
target_link_libraries(h_controller_test PRIVATE h_simulation)
add_library(h_input STATIC src/input/window_input.cpp)
lesson_target(h_input)
target_include_directories(h_input PUBLIC src)
target_compile_definitions(h_input PUBLIC NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(h_input PRIVATE comctl32 user32)
add_executable(h_input_test tests/input_test.cpp)
lesson_target(h_input_test)
target_link_libraries(h_input_test PRIVATE h_input h_simulation)

add_library(h_renderer STATIC src/render/dxr/renderer.cpp src/render/dxr/temporal.cpp ../cuda-interop/src/external.cpp)
lesson_target(h_renderer)
target_include_directories(h_renderer PRIVATE ../cuda-interop/src ../common ../../path_tracing/dxr-path-tracer)
target_compile_definitions(h_renderer PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(h_renderer PUBLIC h_animation PRIVATE h_skin_cuda pbr_render)
add_executable(h_renderer_test tests/renderer_test.cpp)
lesson_target(h_renderer_test)
target_compile_definitions(h_renderer_test PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(h_renderer_test PRIVATE h_renderer h_character_assets h_simulation ole32)
add_executable(character_demo src/app/main.cpp src/app/startup.cpp)
lesson_target(character_demo)
target_include_directories(character_demo PRIVATE "${assimp_SOURCE_DIR}/contrib/rapidjson/include")
target_link_libraries(character_demo PRIVATE h_renderer h_character_assets h_simulation h_input ole32)
# 双击启动只需 EXE 旁的配置与运行库，无需 PowerShell 或预先设置 CUDA PATH。
find_file(H_CHARACTER_CUDART_DLL NAMES cudart64_13.dll
  HINTS "${CUDAToolkit_BIN_DIR}" "${CUDAToolkit_BIN_DIR}/x64"
        "${CUDAToolkit_LIBRARY_ROOT}/bin" "${CUDAToolkit_LIBRARY_ROOT}/bin/x64"
  NO_DEFAULT_PATH REQUIRED)
add_custom_command(TARGET character_demo POST_BUILD
  COMMAND ${CMAKE_COMMAND}
    "-DDEMO_DIR=$<TARGET_FILE_DIR:character_demo>"
    "-DCONFIG_SOURCE=${CMAKE_CURRENT_SOURCE_DIR}/config/character_demo.json"
    "-DCUDART_DLL=${H_CHARACTER_CUDART_DLL}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/deploy_runtime.cmake"
  VERBATIM)
add_executable(h_temporal_test tests/temporal_test.cpp)
lesson_target(h_temporal_test)
target_include_directories(h_temporal_test PRIVATE ../../path_tracing/dxr-path-tracer)
target_compile_definitions(h_temporal_test PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(h_temporal_test PRIVATE h_renderer h_character_assets h_simulation pbr_render ole32)
add_executable(h_performance_test tests/performance_test.cpp)
lesson_target(h_performance_test)
target_compile_definitions(h_performance_test PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(h_performance_test PRIVATE h_renderer h_character_assets h_simulation ole32)
add_executable(h_visual_test tests/visual_test.cpp)
lesson_target(h_visual_test)
target_compile_definitions(h_visual_test PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(h_visual_test PRIVATE h_renderer h_character_assets h_simulation ole32)

add_executable(h_asset_probe tests/asset_probe.cpp)
lesson_target(h_asset_probe)
target_link_libraries(h_asset_probe PRIVATE assimp)
add_executable(h_animation_test tests/animation_test.cpp)
lesson_target(h_animation_test)
target_link_libraries(h_animation_test PRIVATE h_character_assets h_skin_cuda)
foreach(target h_asset_probe h_animation_test h_controller_test h_input_test h_renderer_test h_temporal_test h_performance_test h_visual_test character_demo)
  set_target_properties(${target} PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/build")
endforeach()
