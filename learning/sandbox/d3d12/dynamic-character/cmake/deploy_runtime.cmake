# 只在首次构建时放置默认配置，重新编译不能覆盖用户已经编辑过的 JSON。
if(NOT EXISTS "${DEMO_DIR}/character_demo.json")
    file(COPY_FILE "${CONFIG_SOURCE}" "${DEMO_DIR}/character_demo.json")
endif()
# Windows 加载器在 main 之前查找 CUDA runtime；随 EXE 放置避免依赖终端的 PATH。
file(COPY_FILE "${CUDART_DLL}" "${DEMO_DIR}/cudart64_13.dll" ONLY_IF_DIFFERENT)
