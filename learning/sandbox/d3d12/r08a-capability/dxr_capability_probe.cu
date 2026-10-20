// R.8 DXR capability probe。
// 本程序只查询 DXGI/D3D12 能力，不构建 BLAS/TLAS，不调用 DispatchRays。
// 目的：把“本机是否支持 DXR、支持到哪个 Tier”与后续真正的 DXR 管线分开。
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#pragma comment(lib, "d3d12.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dxguid.lib")

using Microsoft::WRL::ComPtr;

static const char* hr_name(HRESULT hr) {
    switch (hr) {
    case DXGI_ERROR_UNSUPPORTED: return "DXGI_ERROR_UNSUPPORTED";
    case E_INVALIDARG: return "E_INVALIDARG";
    case E_NOINTERFACE: return "E_NOINTERFACE";
    case E_OUTOFMEMORY: return "E_OUTOFMEMORY";
    default: return "HRESULT";
    }
}

static bool check_hr(HRESULT hr, const char* expression) {
    if (FAILED(hr)) {
        std::fprintf(stderr, "%s failed: %s 0x%08lx\n",
                     expression, hr_name(hr), static_cast<unsigned long>(hr));
        return false;
    }
    return true;
}

static bool is_software_adapter(IDXGIAdapter1* adapter) {
    DXGI_ADAPTER_DESC1 desc{};
    adapter->GetDesc1(&desc);
    return (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0;
}

static ComPtr<IDXGIAdapter1> find_hardware_adapter(IDXGIFactory6* factory) {
    for (UINT index = 0;; ++index) {
        ComPtr<IDXGIAdapter1> adapter;
        HRESULT hr = factory->EnumAdapterByGpuPreference(
            index, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
            IID_PPV_ARGS(&adapter));
        if (hr == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(hr) || is_software_adapter(adapter.Get())) continue;

        if (SUCCEEDED(D3D12CreateDevice(
                adapter.Get(), D3D_FEATURE_LEVEL_12_0,
                __uuidof(ID3D12Device), nullptr))) {
            return adapter;
        }
    }
    return {};
}

static const char* tier_name(D3D12_RAYTRACING_TIER tier) {
    switch (tier) {
    case D3D12_RAYTRACING_TIER_NOT_SUPPORTED: return "NOT_SUPPORTED";
    case D3D12_RAYTRACING_TIER_1_0: return "TIER_1_0";
    case D3D12_RAYTRACING_TIER_1_1: return "TIER_1_1";
    default: return "UNKNOWN";
    }
}

int main() {
    std::printf("R.8 DXR capability probe\n");
    std::printf("purpose: capability query only; no BLAS/TLAS/DispatchRays\n\n");

    UINT factory_flags = 0;
#if defined(_DEBUG)
    factory_flags |= DXGI_CREATE_FACTORY_DEBUG;
#endif

    ComPtr<IDXGIFactory6> factory;
    if (!check_hr(CreateDXGIFactory2(factory_flags, IID_PPV_ARGS(&factory)),
                  "CreateDXGIFactory2")) {
        return EXIT_FAILURE;
    }

    ComPtr<IDXGIAdapter1> adapter = find_hardware_adapter(factory.Get());
    if (!adapter) {
        std::fprintf(stderr, "No hardware adapter can create a D3D12 device\n");
        return EXIT_FAILURE;
    }

    DXGI_ADAPTER_DESC1 adapter_desc{};
    adapter->GetDesc1(&adapter_desc);
    std::wprintf(L"adapter: %ls\n", adapter_desc.Description);
    std::printf("vendor_id: 0x%04x  device_id: 0x%04x\n",
                adapter_desc.VendorId, adapter_desc.DeviceId);
    std::printf("dedicated_video_memory: %llu MiB\n\n",
                static_cast<unsigned long long>(adapter_desc.DedicatedVideoMemory / (1024ull * 1024ull)));

    ComPtr<ID3D12Device5> device5;
    HRESULT device_hr = D3D12CreateDevice(
        adapter.Get(), D3D_FEATURE_LEVEL_12_0,
        IID_PPV_ARGS(&device5));
    if (!check_hr(device_hr, "D3D12CreateDevice(ID3D12Device5)")) {
        std::fprintf(stderr, "DXR requires a device interface with ray-tracing support.\n");
        return EXIT_FAILURE;
    }

    D3D12_FEATURE_DATA_D3D12_OPTIONS5 options5{};
    if (!check_hr(device5->CheckFeatureSupport(
            D3D12_FEATURE_D3D12_OPTIONS5, &options5, sizeof(options5)),
                  "ID3D12Device::CheckFeatureSupport(OPTIONS5)")) {
        return EXIT_FAILURE;
    }

    D3D12_FEATURE_DATA_D3D12_OPTIONS options{};
    if (!check_hr(device5->CheckFeatureSupport(
            D3D12_FEATURE_D3D12_OPTIONS, &options, sizeof(options)),
                  "ID3D12Device::CheckFeatureSupport(OPTIONS)")) {
        return EXIT_FAILURE;
    }

    D3D12_FEATURE_DATA_SHADER_MODEL shader_model{
        D3D_SHADER_MODEL_6_7
    };
    HRESULT shader_hr = device5->CheckFeatureSupport(
        D3D12_FEATURE_SHADER_MODEL, &shader_model, sizeof(shader_model));
    if (FAILED(shader_hr)) {
        std::printf("shader_model: query failed (%s 0x%08lx)\n",
                    hr_name(shader_hr), static_cast<unsigned long>(shader_hr));
    } else {
        std::printf("shader_model: 0x%04x\n", shader_model.HighestShaderModel);
    }

    std::printf("raytracing_tier: %s (%d)\n",
                tier_name(options5.RaytracingTier),
                static_cast<int>(options5.RaytracingTier));
    std::printf("resource_binding_tier: %d\n",
                static_cast<int>(options.ResourceBindingTier));
    if (options5.RaytracingTier == D3D12_RAYTRACING_TIER_NOT_SUPPORTED) {
        std::printf("DXR result: NOT SUPPORTED\n");
        return EXIT_FAILURE;
    }

    std::printf("DXR result: SUPPORTED\n");
    std::printf("next dependency: R.9 BLAS -> R.10 TLAS -> R.11 Shader Table/DispatchRays\n");
    return EXIT_SUCCESS;
}
