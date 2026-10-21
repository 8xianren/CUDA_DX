// 全程只用 Driver API（cu 前缀），手动加载 8.3 生成的 asm_demo.cubin 并启动其中的 kernel。
// 对照：Runtime API 会自动 cuInit/建 context/从 fatbin 找 kernel；这里全部手动做。
#include <cstdio>
#include <filesystem>
#include <vector>
#define NOMINMAX
#include <windows.h>
#include <cuda.h>   // Driver API 头（不是 cuda_runtime.h）

#define DRV(x) do{ CUresult r=(x); if(r!=CUDA_SUCCESS){ const char* s; cuGetErrorString(r,&s); \
    printf("Driver API err %s:%d -> %s\n", __FILE__, __LINE__, s); return 1; } }while(0)

int main(int argc, char** argv) {
    // cubin 默认与 exe 同目录，不能依赖调用者的工作目录；目录整理后，从仓库根目录
    // 启动也必须加载本课产物。可选第一个参数指定另一份 cubin/PTX，用于 JIT 对照。
    // GetModuleFileNameW 的缓冲区包含终止零；返回长度等于容量意味着截断，明确失败。
    wchar_t executable[32768]{};
    const DWORD length = GetModuleFileNameW(nullptr, executable, 32768);
    if (length == 0 || length >= 32768) {
        std::fprintf(stderr, "cannot locate executable directory\n");
        return 1;
    }
    const auto module_path = argc > 1 ? std::filesystem::path(argv[1])
        : std::filesystem::path(executable).parent_path() / "asm_demo.cubin";
    if (!std::filesystem::is_regular_file(module_path)) {
        std::fprintf(stderr, "missing module: %s; run this lesson's build.ps1 first\n",
                     module_path.string().c_str());
        return 1;
    }
    // 1) 初始化 Driver API（Runtime 会替你隐式做这步）
    DRV(cuInit(0));

    CUdevice dev; DRV(cuDeviceGet(&dev, 0));
    char name[128]; DRV(cuDeviceGetName(name, sizeof(name), dev));
    printf("设备: %s\n", name);

    // 2) 手动创建 context（Runtime 里这叫“primary context”，自动帮你建）
    CUcontext ctx; DRV(cuCtxCreate(&ctx, nullptr, 0, dev));  // CUDA 13 的 _v4 签名：多了 params 指针

    // 3) 手动加载 module（一个 cubin/PTX/fatbin 文件）——这是 Driver API 的灵魂
    CUmodule mod; DRV(cuModuleLoad(&mod, module_path.string().c_str()));

    // 4) 按“名字”从 module 里取出 kernel（注意是 C++ mangled 名）
    CUfunction fma; DRV(cuModuleGetFunction(&fma, mod, "_Z10fma_kernelPKfS0_S0_Pfi"));
    printf("已从 cubin 载入 kernel: fma_kernel\n");

    // 5) 设备内存：cuMemAlloc（对应 cudaMalloc）
    const int N = 1 << 20;
    size_t bytes = N * sizeof(float);
    std::vector<float> ha(N, 2.0f), hb(N, 3.0f), hc(N, 1.0f), hout(N, 0.0f);

    CUdeviceptr da, db, dc, dout;
    DRV(cuMemAlloc(&da, bytes)); DRV(cuMemAlloc(&db, bytes));
    DRV(cuMemAlloc(&dc, bytes)); DRV(cuMemAlloc(&dout, bytes));
    DRV(cuMemcpyHtoD(da, ha.data(), bytes));   // 对应 cudaMemcpy H2D
    DRV(cuMemcpyHtoD(db, hb.data(), bytes));
    DRV(cuMemcpyHtoD(dc, hc.data(), bytes));

    // 6) 手动打包参数 + cuLaunchKernel（对应 <<<grid,block>>>）
    int n = N, block = 256, grid = (N + block - 1) / block;
    void* args[] = { &da, &db, &dc, &dout, &n };
    DRV(cuLaunchKernel(fma,
                       grid, 1, 1,      // gridDim
                       block, 1, 1,     // blockDim
                       0, 0,            // sharedMem, stream
                       args, nullptr)); // 参数数组
    DRV(cuCtxSynchronize());            // 对应 cudaDeviceSynchronize

    DRV(cuMemcpyDtoH(hout.data(), dout, bytes));
    // 期望 out = a*b+c = 2*3+1 = 7
    int wrong = 0; for (int i = 0; i < N; ++i) if (hout[i] != 7.0f) wrong++;
    printf("out = a*b+c，结果错误 %d 个（应为0）；out[0]=%.1f\n", wrong, hout[0]);

    // 7) 手动清理（Driver API 什么都得自己收）
    cuMemFree(da); cuMemFree(db); cuMemFree(dc); cuMemFree(dout);
    cuModuleUnload(mod);
    cuCtxDestroy(ctx);
    return 0;
}
