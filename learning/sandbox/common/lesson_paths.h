#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <filesystem>
#include <stdexcept>
#include <vector>
namespace lesson_paths {
// 旧单文件课程仍把EXE生成在源码旁。运行结果以EXE目录为基准，
// 因而从仓库根、课程目录或资源管理器启动都写入同一课程results，不依赖__FILE__或cwd。
inline std::filesystem::path ResultDirectory(){
    std::vector<wchar_t> path(32768);
    DWORD length=GetModuleFileNameW(nullptr,path.data(),DWORD(path.size()));
    if(!length||length>=path.size())throw std::runtime_error("cannot locate lesson executable");
    auto result=std::filesystem::path(std::wstring(path.data(),length)).parent_path()/"results";
    std::filesystem::create_directories(result);return result;
}
}
