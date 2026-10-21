#pragma once
#include "instance_data.h"
#include "raster.h"

std::vector<SharedInstance> Expected(const CpuScene& scene,unsigned frame);
struct PixelAudit { uint64_t checked=0,edges=0,covered=0,mismatch=0; };
PixelAudit AuditPixels(const CpuScene& scene,const InstanceCamera& camera,
                      const std::vector<SharedInstance>& records,const std::vector<float>& pixels);
void SaveImage(const std::filesystem::path& path,unsigned width,unsigned height,const std::vector<float>& pixels);
