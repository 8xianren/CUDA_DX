import numpy as np
import cupy as cp


print("CuPy:", cp.__version__)
device = cp.cuda.Device()
print("device:", device.id, "compute capability:", device.compute_capability)

# RawKernel 把一段 CUDA C++ 源码交给 NVRTC 编译；这里的线程索引和 C++ kernel 完全相同。
source = r'''
extern "C" __global__
void add_bias(const float* x, float* y, float bias, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        y[i] = x[i] + bias;
    }
}
'''
add_bias = cp.RawKernel(source, "add_bias")

n = 1_000_003  # 故意不是 block size 的整数倍，验证边界保护
x = cp.arange(n, dtype=cp.float32)
y = cp.empty_like(x)
bias = np.float32(3.5)
threads = 256
blocks = (n + threads - 1) // threads

add_bias((blocks,), (threads,), (x, y, bias, np.int32(n)))
cp.cuda.Stream.null.synchronize()  # kernel 异步，验证前必须等待

expected = cp.arange(n, dtype=cp.float32) + bias
max_error = float(cp.max(cp.abs(y - expected)).get())
print(f"launch: grid=({blocks},), block=({threads},)")
print("result:", y[:3].get(), "...", y[-3:].get())
print("max error:", max_error)
print("correct:", bool(max_error == 0.0))
