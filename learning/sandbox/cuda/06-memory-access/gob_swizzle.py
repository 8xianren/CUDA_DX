# NVIDIA "block-linear" 纹理排布的 GOB 内部 swizzle
# 公式来自 Tegra X1 TRM / envytools / Mesa（Fermi~Maxwell 公开已知，桌面新架构官方不公开）
#
# 一个 GOB = 64 字节宽 x 8 行 = 512 字节。x 以“字节”计。
def gob_byte_offset(xb, yb):
    return (  ((xb % 64) // 32) * 256
            + ((yb % 8)  // 2 ) * 64
            + ((xb % 32) // 16) * 32
            + ( yb % 2        ) * 16
            +  (xb % 16) )

# 教科书 Morton（每一位都交错）作对照
def morton(x, y):
    z = 0
    for i in range(4):
        z |= ((x >> i) & 1) << (2*i)
        z |= ((y >> i) & 1) << (2*i + 1)
    return z

# 以 4 字节元素(如 float/RGBA8)看一个 GOB：16 元素宽 x 8 行
W, H = 16, 8
print("=== 真实 GOB 排布：每个 4字节元素 的“元素序号”(offset/4) ===")
for y in range(H):
    row = []
    for x in range(W):
        off = gob_byte_offset(x * 4, y)     # 元素 x -> 字节 x*4
        row.append(off // 4)
    print(" ".join(f"{v:3d}" for v in row))

print("\n=== 同尺寸 教科书Morton 对照 ===")
for y in range(H):
    print(" ".join(f"{morton(x,y):3d}" for x in range(W)))

# 看“同一行连续 4 个元素(=16字节)”是否地址连续
print("\n每行头 4 个元素的地址(元素序号):")
print("  GOB   :", [gob_byte_offset(x*4, 0)//4 for x in range(4)], "<- 连续!(16字节保持线性)")
print("  Morton:", [morton(x, 0) for x in range(4)], "<- 被打散")
