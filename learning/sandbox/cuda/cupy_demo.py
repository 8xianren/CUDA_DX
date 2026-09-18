import time
import numpy as np
import cupy as cp

print("CuPy", cp.__version__, "| device:", cp.cuda.runtime.getDeviceProperties(0)["name"].decode())

N = 4000

# ---------- CPU: NumPy ----------
a_cpu = np.random.random((N, N)).astype(np.float32)
b_cpu = np.random.random((N, N)).astype(np.float32)
t0 = time.perf_counter()
c_cpu = a_cpu @ b_cpu          # 矩阵乘
t1 = time.perf_counter()
cpu_ms = (t1 - t0) * 1000
print(f"NumPy(CPU)  {N}x{N} matmul: {cpu_ms:8.1f} ms")

# ---------- GPU: CuPy ----------
a_gpu = cp.asarray(a_cpu)      # H2D 拷贝
b_gpu = cp.asarray(b_cpu)

# 先热身一次(第一次会触发 CUDA 上下文/内核编译,不计入)
cp.matmul(a_gpu, b_gpu); cp.cuda.Stream.null.synchronize()

start = cp.cuda.Event(); end = cp.cuda.Event()
start.record()
c_gpu = a_gpu @ b_gpu
end.record()
end.synchronize()             # 关键:等 GPU 真正算完
gpu_ms = cp.cuda.get_elapsed_time(start, end)
print(f"CuPy(GPU)   {N}x{N} matmul: {gpu_ms:8.1f} ms  ({cpu_ms/gpu_ms:.1f}x)")

# 验证两边结果一致
err = float(cp.max(cp.abs(c_gpu - cp.asarray(c_cpu))))
print(f"最大误差(float32 舍入): {err:.4f}")

# ---------- 演示“不同步计时”的假象 ----------
t0 = time.perf_counter()
_ = a_gpu @ b_gpu             # 只是发指令,没等
t1 = time.perf_counter()
print(f"\n不同步计时(错误示范): {(t1-t0)*1000:8.3f} ms  <- 这只是Python发指令的时间,不是GPU算的时间")
