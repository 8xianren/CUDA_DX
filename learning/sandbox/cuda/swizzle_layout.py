# 对比两种把 2D 坐标 (x,y) 映射到 1D 内存地址的排布

W = H = 8

# 1) 行主序(线性):最直觉,cudaMalloc 就是这样
def linear(x, y):
    return y * W + x

# 2) Morton / Z-order(一种 swizzle):交错 x、y 的二进制位
def morton(x, y):
    z = 0
    for i in range(4):                 # 8x8 需要 3 位,取 4 位够
        z |= ((x >> i) & 1) << (2 * i)     # x 的位放偶数位
        z |= ((y >> i) & 1) << (2 * i + 1) # y 的位放奇数位
    return z

def show(name, f):
    print(f"\n=== {name}:每个格子 (x向右, y向下) 存到的内存下标 ===")
    for y in range(H):
        print(" ".join(f"{f(x,y):3d}" for x in range(W)))

show("行主序 linear", linear)
show("Morton swizzle", morton)

# 正确指标:设一个 cache line = 4 个连续元素,统计一个 2x2 块要碰几条 line
LINE = 4
def cachelines_2x2(f, aligned):
    counts = []
    step = 2 if aligned else 1
    for y in range(0, H - 1, step):
        for x in range(0, W - 1, step):
            idx = [f(x,y), f(x+1,y), f(x,y+1), f(x+1,y+1)]
            lines = {i // LINE for i in idx}      # 落在哪几条 cache line
            counts.append(len(lines))
    return sum(counts) / len(counts)

print(f"\n一个 2x2 块平均要碰几条 cache line(LINE={LINE}元素,越少越好):")
print(f"  行主序 linear (对齐块) : {cachelines_2x2(linear, True):.2f}")
print(f"  Morton swizzle(对齐块) : {cachelines_2x2(morton, True):.2f}")

# 更大邻域看整体局部性:4x4 窗口的平均地址跨度
def span_win(f, k):
    spans = []
    for y in range(H - k + 1):
        for x in range(W - k + 1):
            a = [f(x+dx, y+dy) for dy in range(k) for dx in range(k)]
            spans.append(max(a) - min(a))
    return sum(spans) / len(spans)

print(f"\n4x4 窗口平均地址跨度(越小=越集中):")
print(f"  行主序 linear : {span_win(linear,4):.1f}")
print(f"  Morton swizzle: {span_win(morton,4):.1f}")
