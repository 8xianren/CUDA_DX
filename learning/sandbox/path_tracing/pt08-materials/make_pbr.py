"""十块并排的glTF材质平面；2x2纹理使GPU读到真实sRGB基础色、线性G粗糙度/B金属度和发光。
半宽1小平面避免把材质测试与大三角形求交误差混合；所有面法线+Z、UV0，OPAQUE单面。
PNG由标准库写出，不依赖额外图像库；结果直接保存results/pbr。
"""
from pathlib import Path
import json, struct, zlib, binascii, sys

# 可选参数是本次课程结果目录，避免新课生成资产时覆盖前课记录；默认保留旧入口。
out = Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).resolve().parent/'results/pbr'
out.mkdir(parents=True, exist_ok=True)
def png(name, colors):
    def chunk(tag, content):
        return struct.pack('>I', len(content))+tag+content+struct.pack('>I', binascii.crc32(tag+content)&0xffffffff)
    pixels = b''.join(b'\0'+bytes(sum(colors[row*2:row*2+2], [])) for row in range(2))
    image = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>2I5B',2,2,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(pixels))+chunk(b'IEND',b'')
    (out/name).write_bytes(image)

png('base.png', [[200,40,20,255],[40,200,20,255],[20,40,200,255],[220,180,100,255]])
png('mr.png', [[255,64,0,255],[0,128,85,255],[128,192,170,255],[64,255,255,255]])
png('emission.png', [[32,64,128,255],[64,128,32,255],[128,32,64,255],[255,255,255,255]])
cases = [([1,1,1],0,.25),([1,1,1],0,1),([.2,.6,.9],0,.5),([1,.766,.336],1,.25),
         ([.9,.6,.2],1,1),([.5,.3,.1],.5,.5),([.8,.9,1],1,0),([.6,.4,.2],0,0),([0,0,0],0,.5),([.8,.6,.4],.9,.8)]
data=bytearray();views=[];accessors=[];meshes=[];materials=[]
for i,(base,metal,rough) in enumerate(cases):
    left=-len(cases)+2*i;positions=[(left,-1,0),(left+2,-1,0),(left+2,1,0),(left,1,0)]
    attrs={}
    for semantic,values,size in [('POSITION',positions,3),('TEXCOORD_0',[(0,0),(1,0),(1,1),(0,1)],2),
                                ('COLOR_0',[((.5,.75,1,1) if i==9 else (1,1,1,1))]*4,4)]:
        start=len(data)
        for v in values:data.extend(struct.pack('<'+'f'*size,*v))
        views.append(dict(buffer=0,byteOffset=start,byteLength=len(data)-start,target=34962))
        accessor=dict(bufferView=len(views)-1,componentType=5126,count=4,type='VEC'+str(size))
        if semantic=='POSITION':accessor.update(min=[left,-1,0],max=[left+2,1,0])
        attrs[semantic]=len(accessors);accessors.append(accessor)
    start=len(data);data.extend(struct.pack('<6H',0,1,2,0,2,3))
    views.append(dict(buffer=0,byteOffset=start,byteLength=12,target=34963));accessors.append(dict(bufferView=len(views)-1,componentType=5123,count=6,type='SCALAR'))
    meshes.append(dict(primitives=[dict(attributes=attrs,indices=len(accessors)-1,material=i)]))
    pbr=dict(baseColorFactor=base+[1],metallicFactor=metal,roughnessFactor=rough)
    material=dict(name=f'm{i:02d}',pbrMetallicRoughness=pbr)
    if i==9:
        pbr.update(baseColorTexture={'index':0},metallicRoughnessTexture={'index':1})
        material.update(emissiveFactor=[.1,.2,.3],emissiveTexture={'index':2})
    materials.append(material)
scene=dict(asset={'version':'2.0','generator':'PT.8 GGX mixture fixture'},scene=0,scenes=[{'nodes':list(range(len(cases)))}],
           nodes=[{'mesh':i} for i in range(len(cases))],meshes=meshes,materials=materials,
           samplers=[dict(magFilter=9728,minFilter=9728,wrapS=33071,wrapT=33071)],
           images=[{'uri':n} for n in ['base.png','mr.png','emission.png']],textures=[dict(source=i,sampler=0) for i in range(3)],
           buffers=[dict(uri='pbr.bin',byteLength=len(data))],bufferViews=views,accessors=accessors)
(out/'pbr.bin').write_bytes(data)
(out/'pbr.gltf').write_text(json.dumps(scene,indent=2),encoding='utf-8')
