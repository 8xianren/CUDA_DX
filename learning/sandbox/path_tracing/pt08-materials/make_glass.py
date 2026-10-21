"""单界面方向/权重fixture：z=0半宽16的界面，上下z=±2半宽8的单面灯。
ng=+Z，内部介质是z<0；并非有厚度闭合玻璃物体。Glass名称显式映射教学介质，IOR来自实验配置。
glTF只提供几何和灯的线性emissiveFactor；不使用尚未支持的KHR_materials_transmission扩展。
"""
from pathlib import Path
import json,struct
out=Path(__file__).resolve().parent/'results/glass';out.mkdir(parents=True,exist_ok=True)
data=bytearray();views=[];access=[];meshes=[]
for i,(z,h) in enumerate([(0,16),(2,8),(-2,8)]):
    points=[(-h,-h,z),(h,-h,z),(h,h,z),(-h,h,z)];start=len(data)
    for p in points:data.extend(struct.pack('<3f',*p))
    views.append(dict(buffer=0,byteOffset=start,byteLength=48,target=34962))
    access.append(dict(bufferView=len(views)-1,componentType=5126,count=4,type='VEC3',min=[-h,-h,z],max=[h,h,z]))
    start=len(data);data.extend(struct.pack('<6H',*([0,2,1,0,3,2] if i==1 else [0,1,2,0,2,3])))
    views.append(dict(buffer=0,byteOffset=start,byteLength=12,target=34963))
    access.append(dict(bufferView=len(views)-1,componentType=5123,count=6,type='SCALAR'))
    meshes.append(dict(primitives=[dict(attributes={'POSITION':2*i},indices=2*i+1,material=i)]))
materials=[]
for name,emission in [('Glass',[0,0,0]),('UpperLamp',[.8,.3,.1]),('LowerLamp',[.2,.6,1])]:
    materials.append(dict(name=name,emissiveFactor=emission,pbrMetallicRoughness=dict(baseColorFactor=[0,0,0,1],metallicFactor=0,roughnessFactor=0)))
scene=dict(asset={'version':'2.0','generator':'PT.8 single dielectric interface'},scene=0,scenes=[dict(nodes=[0,1,2])],nodes=[dict(mesh=i) for i in range(3)],meshes=meshes,materials=materials,
    buffers=[dict(uri='glass.bin',byteLength=len(data))],bufferViews=views,accessors=access)
(out/'glass.bin').write_bytes(data);(out/'glass.gltf').write_text(json.dumps(scene,indent=2),encoding='utf-8')
