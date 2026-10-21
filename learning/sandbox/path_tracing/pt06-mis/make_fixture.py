"""生成本课已知的三平面glTF测试资产，不承担通用文件解析。"""
from pathlib import Path
import json,struct
root=Path(__file__).resolve().parent/'results'
for name,h in [('small',.25),('large',4.)]:
    out=root/name;out.mkdir(parents=True,exist_ok=True)
    data=bytearray();views=[];access=[];meshes=[]
    for material,(xmin,xmax,ymin,ymax,z) in enumerate([(-1,1,-1,1,0),(-h,h,-h,h,2),(0,.5,-.4,.4,1)]):
        vertices=[(xmin,ymin,z),(xmax,ymin,z),(xmax,ymax,z),(xmin,ymax,z)]
        start=len(data)
        for v in vertices:data.extend(struct.pack('<3f',*v))
        views.append(dict(buffer=0,byteOffset=start,byteLength=48,target=34962))
        access.append(dict(bufferView=len(views)-1,componentType=5126,count=4,type='VEC3',min=[xmin,ymin,z],max=[xmax,ymax,z]))
        start=len(data)
        # 发光平面朝-Z，其余朝+Z。当前DXR测试不剔除背面，单面光照由积分契约约束。
        indices=[0,2,1,0,3,2] if material==1 else [0,1,2,0,2,3]
        data.extend(struct.pack('<6H',*indices))
        views.append(dict(buffer=0,byteOffset=start,byteLength=12,target=34963))
        access.append(dict(bufferView=len(views)-1,componentType=5123,count=6,type='SCALAR'))
        meshes.append(dict(primitives=[dict(attributes={'POSITION':len(access)-2},indices=len(access)-1,material=material)]))
    materials=[]
    for name2,rho,le in [('Receiver',.8,0),('Emitter',0,1),('Blocker',0,0)]:
        materials.append(dict(name=name2,pbrMetallicRoughness=dict(baseColorFactor=[rho,rho,rho,1],metallicFactor=0,roughnessFactor=1),emissiveFactor=[le,le,le]))
    scene=dict(asset={'version':'2.0','generator':'PT.6 direct MIS fixture'},scene=0,scenes=[dict(nodes=[0,1,2])],
               nodes=[dict(mesh=i) for i in range(3)],meshes=meshes,materials=materials,
               buffers=[dict(uri='scene.bin',byteLength=len(data))],bufferViews=views,accessors=access)
    (out/'scene.bin').write_bytes(data);(out/'scene.gltf').write_text(json.dumps(scene,indent=2),encoding='utf-8')
