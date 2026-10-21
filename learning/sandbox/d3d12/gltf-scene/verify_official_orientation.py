"""固定官方BoxTextured资产的独立方向验收，不是通用glTF解析器。
只读固定样本已知的float32 accessor，验证源UV/父矩阵，再检查实际GPU正面PNG。
"""
from pathlib import Path
import json, struct, math
from PIL import Image
root=Path(__file__).resolve().parent/'results'/'d03'
asset=root/'BoxTextured'
g=json.loads((asset/'BoxTextured.gltf').read_text())
data=(asset/'BoxTextured0.bin').read_bytes()
def floats(index,components):
    a=g['accessors'][index];v=g['bufferViews'][a['bufferView']]
    assert a['componentType']==5126
    start=v.get('byteOffset',0)+a.get('byteOffset',0)
    return [struct.unpack_from('<'+'f'*components,data,start+i*v.get('byteStride',components*4)) for i in range(a['count'])]
pos=floats(2,3);uv=floats(3,2)
assert g['nodes'][0]['matrix']==[1,0,0,0,0,0,-1,0,0,1,0,0,0,0,0,1]
# 源局部坐标经父矩阵变成world=(x,z,-y)。正面从左到右u=4→3，必然水平镜像。
assert [pos[i] for i in (12,13,14,15)]==[(.5,-.5,.5),(-.5,-.5,.5),(.5,-.5,-.5),(-.5,-.5,-.5)]
assert [uv[i] for i in (12,13,14,15)]==[(3,0),(4,0),(3,1),(4,1)]
# 检查这些顶点确实组成表面，而不只是在buffer中存在。
a=g['accessors'][0];b=g['bufferViews'][a['bufferView']]
indices=struct.unpack_from('<36H',data,b.get('byteOffset',0)+a.get('byteOffset',0))
assert set(indices[18:24])=={12,13,14,15}
def decode(x):return x/12.92 if x<=.04045 else ((x+.055)/1.055)**2.4
def encode(x):return 12.92*x if x<=.0031308 else 1.055*x**(1/2.4)-.055
source=Image.open(asset/'CesiumLogoFlat.png').convert('RGB')
actual=Image.open(root/'official'/'box-front.png').convert('RGB')
assert source.size==(256,256) and actual.size==(128,128)
maximum=0
for y in range(128):
    for x in range(128):
        # glTF原始UV→repeat→双线性→显示编码；不借用Assimp或GPU表。
        u=4-(x+.5)/128;v=(y+.5)/128
        tx=u*256-.5;ty=v*256-.5;ix=math.floor(tx);iy=math.floor(ty);fx=tx-ix;fy=ty-iy
        expected=[]
        for k in range(3):
            linear=sum(decode(source.getpixel(((ix+dx)%256,(iy+dy)%256))[k]/255)*
                       (fx if dx else 1-fx)*(fy if dy else 1-fy) for dy in (0,1) for dx in (0,1))
            expected.append(round(255*encode(linear)))
        maximum=max(maximum,max(abs(a-b) for a,b in zip(actual.getpixel((x,y)),expected)))
assert maximum<=2,maximum
message=f'PASS official front 16384 pixels: max RGB code error={maximum}; source UV left=4 right=3, top v=0 bottom v=1; horizontal mirror is authored in asset, not a loader flip.'
(root/'official'/'orientation.txt').write_text(message+'\n',encoding='utf-8')
print(message)
