#include "sdk_upscalers.h"
#include <Windows.h>
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <vector>
#include <ffx_api.h>
#include <dx12/ffx_api_dx12.h>
#include <ffx_upscale.h>
#include <xess/xess_d3d12.h>

namespace aa {
namespace {
template<class T> T Symbol(HMODULE dll, const char* name) {
    auto p = GetProcAddress(dll, name);
    if (!p) throw std::runtime_error(std::string("missing SDK export: ") + name);
    return reinterpret_cast<T>(p);
}
std::string XeVersion(const xess_version_t& v) {
    return std::to_string(v.major) + "." + std::to_string(v.minor) + "." +
           std::to_string(v.patch) + "." + std::to_string(v.reserved);
}
}

struct SdkUpscaler::Impl {
    SdkKind kind = SdkKind::Fsr;
    bool ready = false;
    uint32_t outW = 0, outH = 0, maxW = 0, maxH = 0, recW = 0, recH = 0;
    std::string status = "not initialized", provider;
    HMODULE dll = nullptr;
    HMODULE effectDll = nullptr;
    DLL_DIRECTORY_COOKIE dllDirectory = nullptr;
    ffxContext fsr = nullptr;
    PfnFfxCreateContext fsrCreate = nullptr;
    PfnFfxDestroyContext fsrDestroy = nullptr;
    PfnFfxDispatch fsrDispatch = nullptr;
    PfnFfxQuery fsrQuery = nullptr;
    // API要求传入的描述符引用持续有效，故 backend 与 context 创建链存为成员。
    ffxCreateBackendDX12Desc backend{};
    ffxCreateContextDescUpscale create{};
    ffxCreateContextDescUpscaleVersion headerVersion{};
    xess_context_handle_t xess = nullptr;
    decltype(&xessD3D12CreateContext) xeCreate = nullptr;
    decltype(&xessD3D12Init) xeInit = nullptr;
    decltype(&xessD3D12Execute) xeExecute = nullptr;
    decltype(&xessDestroyContext) xeDestroy = nullptr;
    decltype(&xessGetOptimalInputResolution) xeInputSize = nullptr;
    decltype(&xessGetVersion) xeVersion = nullptr;
    decltype(&xessSetVelocityScale) xeVelocityScale = nullptr;

    bool fail(const std::string& at, int code) {
        status = at + " failed (code=" + std::to_string(code) + "); host must use spatial fallback";
        return false;
    }
};

SdkUpscaler::SdkUpscaler() : p_(std::make_unique<Impl>()) {}
SdkUpscaler::~SdkUpscaler() { Shutdown(); }
bool SdkUpscaler::Ready() const { return p_->ready; }
const std::string& SdkUpscaler::Status() const { return p_->status; }
const std::string& SdkUpscaler::Provider() const { return p_->provider; }
uint32_t SdkUpscaler::RecommendedWidth() const { return p_->recW; }
uint32_t SdkUpscaler::RecommendedHeight() const { return p_->recH; }
uint32_t SdkUpscaler::JitterPhaseCount(uint32_t renderWidth, uint32_t outputWidth) const {
    if (!p_->ready || !renderWidth || outputWidth != p_->outW)
        throw std::runtime_error("invalid SDK jitter phase query");
    if (p_->kind == SdkKind::Fsr) {
        int32_t phases = 0;
        ffxQueryDescUpscaleGetJitterPhaseCount q{};
        q.header.type = FFX_API_QUERY_DESC_TYPE_UPSCALE_GETJITTERPHASECOUNT;
        q.renderWidth = renderWidth; q.displayWidth = outputWidth; q.pOutPhaseCount = &phases;
        const auto code = p_->fsrQuery(&p_->fsr, &q.header);
        if (code != FFX_API_RETURN_OK || phases <= 0)
            throw std::runtime_error("ffxQuery jitter phase failed, code=" + std::to_string(code));
        return static_cast<uint32_t>(phases);
    }
    // Intel文档给的是下界，不给截断API；整数序列长度应ceil才能不低于该下界。
    // 使用实际像素尺寸，而非写死某quality品牌标签对应的倍率。
    const double ratio = double(outputWidth) / double(renderWidth);
    return static_cast<uint32_t>(std::ceil(8.0 * ratio * ratio));
}

void SdkUpscaler::Shutdown() {
    // 没有私自提交/等待宿主队列；宿主先 Fence，才能释放 SDK 的历史与临时资源。
    if (p_->fsr && p_->fsrDestroy) p_->fsrDestroy(&p_->fsr, nullptr);
    if (p_->xess && p_->xeDestroy) p_->xeDestroy(p_->xess);
    p_->fsr = nullptr; p_->xess = nullptr; p_->ready = false;
    if (p_->dll) FreeLibrary(p_->dll);
    if (p_->effectDll) FreeLibrary(p_->effectDll);
    if (p_->dllDirectory) RemoveDllDirectory(p_->dllDirectory);
    p_->dll = nullptr; p_->effectDll = nullptr; p_->dllDirectory = nullptr;
}

bool SdkUpscaler::Initialize(ID3D12Device* device, SdkKind kind, SdkQuality quality,
                            uint32_t outputWidth, uint32_t outputHeight,
                            uint32_t maxRenderWidth, uint32_t maxRenderHeight,
                            const std::filesystem::path& depsRoot) {
    Shutdown();
    p_->kind = kind; p_->outW = outputWidth; p_->outH = outputHeight;
    p_->maxW = maxRenderWidth; p_->maxH = maxRenderHeight;
    p_->provider.clear(); p_->recW = p_->recH = 0;
    if (!device || !outputWidth || !outputHeight || !maxRenderWidth || !maxRenderHeight)
        return p_->fail("invalid initialization input", -1);
    try {
        auto directory = kind == SdkKind::Fsr
            ? depsRoot / "fidelityfx/Samples/Upscalers/FidelityFX_FSR/dx12/x64/Release"
            : depsRoot / "xess/bin";
        directory = std::filesystem::absolute(directory);
        const auto dllPath = directory / (kind == SdkKind::Fsr
            ? L"amd_fidelityfx_loader_dx12.dll" : L"libxess.dll");
        // 绝对路径加载且仅加入已核hash的官方包目录。loader延迟加载effect DLL，目录
        // cookie需保留到Shutdown，不能只在LoadLibrary调用瞬间有效。
        p_->dllDirectory = AddDllDirectory(directory.c_str());
        if (kind == SdkKind::Fsr) {
            // loader会延迟按文件名寻找effect；官方DLL不放exe旁时，先以绝对路径加载
            // effect以确定其身份，并保持引用。仅AddDllDirectory不会改变旧LoadLibrary搜索规则。
            p_->effectDll = LoadLibraryExW((directory / L"amd_fidelityfx_upscaler_dx12.dll").c_str(), nullptr,
                LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
            if (!p_->effectDll) return p_->fail("LoadLibrary official FSR effect", static_cast<int>(GetLastError()));
        }
        p_->dll = LoadLibraryExW(dllPath.c_str(), nullptr,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if (!p_->dll) return p_->fail("LoadLibrary official SDK", static_cast<int>(GetLastError()));
        if (kind == SdkKind::Fsr) {
            p_->fsrCreate = Symbol<PfnFfxCreateContext>(p_->dll, "ffxCreateContext");
            p_->fsrDestroy = Symbol<PfnFfxDestroyContext>(p_->dll, "ffxDestroyContext");
            p_->fsrDispatch = Symbol<PfnFfxDispatch>(p_->dll, "ffxDispatch");
            p_->fsrQuery = Symbol<PfnFfxQuery>(p_->dll, "ffxQuery");
            p_->backend = {};
            p_->backend.header.type = FFX_API_CREATE_CONTEXT_DESC_TYPE_BACKEND_DX12;
            p_->backend.device = device;
            p_->headerVersion = {};
            p_->headerVersion.header.type = FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE_VERSION;
            p_->headerVersion.version = FFX_UPSCALER_VERSION;
            p_->backend.header.pNext = &p_->headerVersion.header;
            p_->create = {};
            p_->create.header = {FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE, &p_->backend.header};
            // 无倒深度/无限远/带jitter运动矢量标志，因为本课程输入均不采用这些约定。
            p_->create.flags = FFX_UPSCALE_ENABLE_HIGH_DYNAMIC_RANGE | FFX_UPSCALE_ENABLE_DYNAMIC_RESOLUTION;
            p_->create.maxRenderSize = {maxRenderWidth, maxRenderHeight};
            p_->create.maxUpscaleSize = {outputWidth, outputHeight};
            auto code = p_->fsrCreate(&p_->fsr, &p_->create.header, nullptr);
            if (code != FFX_API_RETURN_OK) return p_->fail("ffxCreateContext", code);
            ffxQueryGetProviderVersion version{};
            version.header.type = FFX_API_QUERY_DESC_TYPE_GET_PROVIDER_VERSION;
            code = p_->fsrQuery(&p_->fsr, &version.header);
            if (code != FFX_API_RETURN_OK || !version.versionName)
                return p_->fail("ffxQuery provider version", code);
            p_->provider = version.versionName; // 立即拷贝，SDK内部字符串不能长期借用。
            ffxQueryDescUpscaleGetRenderResolutionFromQualityMode size{};
            size.header.type = FFX_API_QUERY_DESC_TYPE_UPSCALE_GETRENDERRESOLUTIONFROMQUALITYMODE;
            size.displayWidth = outputWidth; size.displayHeight = outputHeight;
            size.qualityMode = static_cast<uint32_t>(quality); // 枚举0/1/2/3与官方对应。
            size.pOutRenderWidth = &p_->recW; size.pOutRenderHeight = &p_->recH;
            code = p_->fsrQuery(&p_->fsr, &size.header);
            if (code != FFX_API_RETURN_OK) return p_->fail("ffxQuery render resolution", code);
        } else {
            p_->xeCreate = Symbol<decltype(p_->xeCreate)>(p_->dll, "xessD3D12CreateContext");
            p_->xeInit = Symbol<decltype(p_->xeInit)>(p_->dll, "xessD3D12Init");
            p_->xeExecute = Symbol<decltype(p_->xeExecute)>(p_->dll, "xessD3D12Execute");
            p_->xeDestroy = Symbol<decltype(p_->xeDestroy)>(p_->dll, "xessDestroyContext");
            p_->xeInputSize = Symbol<decltype(p_->xeInputSize)>(p_->dll, "xessGetOptimalInputResolution");
            p_->xeVersion = Symbol<decltype(p_->xeVersion)>(p_->dll, "xessGetVersion");
            p_->xeVelocityScale = Symbol<decltype(p_->xeVelocityScale)>(p_->dll, "xessSetVelocityScale");
            auto code = p_->xeCreate(device, &p_->xess);
            if (code < XESS_RESULT_SUCCESS) return p_->fail("xessD3D12CreateContext", code);
            const xess_quality_settings_t modes[] = {XESS_QUALITY_SETTING_AA, XESS_QUALITY_SETTING_QUALITY,
                XESS_QUALITY_SETTING_BALANCED, XESS_QUALITY_SETTING_PERFORMANCE};
            xess_d3d12_init_params_t init{};
            init.outputResolution = {outputWidth, outputHeight};
            init.qualitySetting = modes[static_cast<unsigned>(quality)];
            // flags=0:低分辨率MV、普通深度、线性HDR、显式每帧exposureScale。
            // 本基线未启用响应mask标志；FSR reactive与XeSS RPM采样契约不同，不能盲传。
            code = p_->xeInit(p_->xess, &init);
            if (code < XESS_RESULT_SUCCESS) return p_->fail("xessD3D12Init", code);
            xess_2d_t input{}, minimum{}, maximum{};
            code = p_->xeInputSize(p_->xess, &init.outputResolution, init.qualitySetting, &input, &minimum, &maximum);
            if (code < XESS_RESULT_SUCCESS) return p_->fail("xessGetOptimalInputResolution", code);
            p_->recW = input.x; p_->recH = input.y;
            xess_version_t version{};
            code = p_->xeVersion(&version);
            if (code < XESS_RESULT_SUCCESS) return p_->fail("xessGetVersion", code);
            p_->provider = "XeSS-SR " + XeVersion(version) + " (official cross-vendor D3D12 runtime)";
            // low-res MV的像素单位属于输入网格，宿主已给该单位，故比例严格为1。
            code = p_->xeVelocityScale(p_->xess, 1.0f, 1.0f);
            if (code < XESS_RESULT_SUCCESS) return p_->fail("xessSetVelocityScale", code);
        }
        p_->ready = true; p_->status = "ready: " + p_->provider;
        return true;
    } catch (const std::exception& e) {
        p_->status = std::string(e.what()) + "; host must use spatial fallback";
        return false;
    }
}

bool SdkUpscaler::Dispatch(const SdkFrame& f) {
    if (!p_->ready) return p_->fail("SDK not initialized", -1);
    if (!f.commands || !f.color || !f.depth || !f.motion || !f.output ||
        !f.renderWidth || !f.renderHeight || f.renderWidth > p_->maxW || f.renderHeight > p_->maxH ||
        f.preExposure <= 0 || f.nearPlane <= 0 || f.farPlane <= f.nearPlane)
        return p_->fail("invalid dispatch input", -1);
    if (p_->kind == SdkKind::Fsr) {
        ffxDispatchDescUpscale d{};
        d.header.type = FFX_API_DISPATCH_DESC_TYPE_UPSCALE;
        d.commandList = f.commands;
        d.color = ffxApiGetResourceDX12(f.color);
        d.depth = ffxApiGetResourceDX12(f.depth);
        // R32_TYPELESS是D3D资源存储格式。SDK应创建R32_FLOAT SRV，而非TYPELESS SRV。
        d.depth.description.format = FFX_API_SURFACE_FORMAT_R32_FLOAT;
        d.motionVectors = ffxApiGetResourceDX12(f.motion);
        d.reactive = ffxApiGetResourceDX12(f.reactive);
        d.output = ffxApiGetResourceDX12(f.output, FFX_API_RESOURCE_STATE_UNORDERED_ACCESS);
        d.jitterOffset = {f.jitterX, f.jitterY};
        d.motionVectorScale = {1.0f, 1.0f};
        d.renderSize = {f.renderWidth, f.renderHeight};
        d.upscaleSize = {p_->outW, p_->outH};
        d.frameTimeDelta = f.deltaTimeMs;
        d.preExposure = f.preExposure;
        d.reset = f.reset;
        d.cameraNear = f.nearPlane; d.cameraFar = f.farPlane;
        d.cameraFovAngleVertical = f.verticalFovRadians;
        d.viewSpaceToMetersFactor = 1.0f;
        // 不打开RCAS，确保比较的是重建而非不同锐化强度；曝光纹理空等价1。
        auto code = p_->fsrDispatch(&p_->fsr, &d.header);
        if (code != FFX_API_RETURN_OK) return p_->fail("ffxDispatch", code);
    } else {
        xess_d3d12_execute_params_t d{};
        d.pColorTexture = f.color; d.pDepthTexture = f.depth;
        d.pVelocityTexture = f.motion; d.pOutputTexture = f.output;
        d.jitterOffsetX = f.jitterX; d.jitterOffsetY = f.jitterY;
        // FSR preExposure与XeSS exposureScale不是同一参数：前者描述颜色已乘P，
        // 后者将输入乘E/P。本课固定曝光E=1，所以必须取倒数，不能原样传P。
        d.exposureScale = 1.0f / f.preExposure; d.resetHistory = f.reset ? 1u : 0u;
        d.inputWidth = f.renderWidth; d.inputHeight = f.renderHeight;
        // 其余base坐标0、外部分配heap空，SDK拥有其内部资源与descriptor heap。
        auto code = p_->xeExecute(p_->xess, f.commands, &d);
        if (code < XESS_RESULT_SUCCESS) return p_->fail("xessD3D12Execute", code);
    }
    // 为宿主后续UAV读/转换建立写入排序。真正执行/跨队列等待仍由宿主Fence负责。
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV;
    barrier.UAV.pResource = f.output;
    f.commands->ResourceBarrier(1, &barrier);
    p_->status = "dispatch recorded: " + p_->provider;
    return true;
}
} // namespace aa
