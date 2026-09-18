import os
import numpy as np
from numba import cuda, float32

# 模拟器在 CPU 上逐线程跑,规模要小;真 GPU 用大规模
SIM = os.environ.get("NUMBA_ENABLE_CUDASIM") == "1"

print("CUDA available:", cuda.is_available())
_dev = cuda.get_current_device()
_name = getattr(_dev, "name", b"CUDA simulator (CPU)")
print("Device:", _name.decode() if isinstance(_name, bytes) else _name)


# ---------- 1. 逐元素 kernel:c = a + b ----------
@cuda.jit
def add_kernel(a, b, c):
    i = cuda.grid(1)                 # = blockIdx.x*blockDim.x + threadIdx.x
    if i < a.size:
        c[i] = a[i] + b[i]


n = 512 if SIM else (1 << 20)
a = np.arange(n, dtype=np.float32)
b = np.ones(n, dtype=np.float32)

d_a = cuda.to_device(a)             # H2D,等价 cudaMemcpy
d_b = cuda.to_device(b)
d_c = cuda.device_array_like(a)

threads = 256
blocks = (n + threads - 1) // threads
add_kernel[blocks, threads](d_a, d_b, d_c)   # 等价 <<<blocks, threads>>>
cuda.synchronize()

c = d_c.copy_to_host()             # D2H
print("add_kernel ok:", np.allclose(c, a + b), "| c[:5]=", c[:5])


# ---------- 2. 用 shared memory + syncthreads 做 block 内归约 ----------
BS = 256

@cuda.jit
def block_sum(data, partial):
    s = cuda.shared.array(BS, float32)      # = __shared__ float s[256]
    tid = cuda.threadIdx.x
    i = cuda.grid(1)
    s[tid] = data[i] if i < data.size else 0.0
    cuda.syncthreads()                       # = __syncthreads()
    stride = BS // 2
    while stride > 0:                        # 树规约,和你 C++ 手写的一样
        if tid < stride:
            s[tid] += s[tid + stride]
        cuda.syncthreads()
        stride //= 2
    if tid == 0:
        cuda.atomic.add(partial, 0, s[0])    # = atomicAdd(&partial[0], s[0])


data = np.ones(n, dtype=np.float32)
d_data = cuda.to_device(data)
d_part = cuda.to_device(np.zeros(1, dtype=np.float32))
block_sum[blocks, BS](d_data, d_part)
cuda.synchronize()
total = d_part.copy_to_host()[0]
print(f"block_sum(shared+sync+atomic): GPU={total:.0f}  期望={n}  ok={abs(total-n)<1}")
