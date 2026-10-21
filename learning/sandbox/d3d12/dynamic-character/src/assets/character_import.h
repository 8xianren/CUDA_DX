#pragma once
#include "animation/animation.h"
namespace character {
// 同步文件I/O和CPU深拷贝；失败抛异常，不创建GPU资源。
Rig Load(const std::string& path);
}
