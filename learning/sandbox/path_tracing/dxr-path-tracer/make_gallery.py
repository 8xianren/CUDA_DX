"""生成本课glTF：两排粗糙度球、独立玻璃球、地面/背板与两块三角形面积灯。
只定义资产，不计算光照。球体法线由三角形几何决定，细分64×32；所有节点无变换。
teaching_glass是宿主显式覆盖的教学标签，文件不冒充实现glTF透射扩展。
"""
from pathlib import Path
import json, math, struct
out = Path(__file__).resolve().parent/'results/pt08'
out.mkdir(parents=True, exist_ok=True)
data=bytearray();views=[];accessors=[];meshes=[];materials=[]
def material(name, base, metal, rough, emission=None):
    m={'name':name,'pbrMetallicRoughness':{'baseColorFactor':[*base,1],'metallicFactor':metal,'roughnessFactor':rough}}
    if emission is not None: m['emissiveFactor']=emission
    materials.append(m);return len(materials)-1
def accessor(values, kind, components, format, component_type, positions=False):
    while len(data)%4:data.append(0)
    start=len(data)
    for v in values: data.extend(struct.pack('<'+format*components,*v))
    views.append({'buffer':0,'byteOffset':start,'byteLength':len(data)-start})
    a={'bufferView':len(views)-1,'componentType':component_type,'count':len(values),'type':kind}
    if positions:a.update(min=[min(v[k] for v in values) for k in range(3)],max=[max(v[k] for v in values) for k in range(3)])
    accessors.append(a);return len(accessors)-1
def mesh(name, positions, triangles, mat):
    # 本场景无纹理；显式保留UV0，几何法线由世界空间边重建，顶点法线不会偷偷改变曲面定义。
    p=accessor(positions,'VEC3',3,'f',5126,True)
    uv=accessor([(0.,0.)]*len(positions),'VEC2',2,'f',5126)
    idx=accessor([(i,) for t in triangles for i in t],'SCALAR',1,'I',5125)
    meshes.append({'name':name,'primitives':[{'attributes':{'POSITION':p,'TEXCOORD_0':uv},'indices':idx,'material':mat}]})
def cross(a,b):return (a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0])
def sub(a,b):return tuple(x-y for x,y in zip(a,b))
def dot(a,b):return sum(x*y for x,y in zip(a,b))
def sphere(name, center, radius, mat):
    n=64;rings=32;positions=[]
    for j in range(rings+1):
        theta=math.pi*j/rings
        for i in range(n):
            phi=2*math.pi*i/n
            positions.append((center[0]+radius*math.sin(theta)*math.cos(phi),center[1]+radius*math.cos(theta),center[2]+radius*math.sin(theta)*math.sin(phi)))
    triangles=[]
    for j in range(rings):
        for i in range(n):
            a=j*n+i;b=j*n+(i+1)%n;c=(j+1)*n+i;d=(j+1)*n+(i+1)%n
            for tri in [(a,c,b),(b,c,d)]:
                p,q,r=[positions[k] for k in tri];normal=cross(sub(q,p),sub(r,p))
                if dot(normal,normal)<1e-18:continue
                if dot(normal,sub(p,center))<0:tri=(tri[0],tri[2],tri[1])
                triangles.append(tri)
    mesh(name,positions,triangles,mat)
def quad(name, points, normal, mat):
    triangles=[(0,1,2),(0,2,3)]
    if dot(cross(sub(points[1],points[0]),sub(points[2],points[0])),normal)<0:triangles=[(a,c,b) for a,b,c in triangles]
    mesh(name,points,triangles,mat)
roughness=[0,.02,.08,.2,.4,.7,1]
for row,metal in enumerate([0,1]):
    for i,r in enumerate(roughness):
        base=[.55,.15,.06] if metal==0 else [.95,.64,.23]
        m=material(f'{"metal" if metal else "dielectric"}_r{r}',base,metal,r)
        sphere(f'row{row}_r{r}',(-6+2*i,.8+1.8*row,0),.72,m)
glass=material('teaching_glass',[1,1,1],0,0)
sphere('glass_left',(-7.8,1.1,1.0),.75,glass)
sphere('glass_right',(7.8,1.1,1.0),.75,glass)
floor=material('floor',[.55,.58,.62],0,.65)
back=material('back',[.3,.37,.5],0,.8)
quad('floor',[(-10,0,-5),(10,0,-5),(10,0,6),(-10,0,6)],(0,1,0),floor)
quad('back',[(-10,0,-4),(10,0,-4),(10,6,-4),(-10,6,-4)],(0,0,1),back)
warm=material('warm_light',[0,0,0],0,1,[1,.85,.65])
cool=material('cool_light',[0,0,0],0,1,[.5,.7,1])
quad('warm_light',[(-5,5,0),(0,5,0),(0,5,3),(-5,5,3)],(0,-1,0),warm)
quad('cool_light',[(2,5,-1),(6,5,-1),(6,5,2),(2,5,2)],(0,-1,0),cool)
scene={'asset':{'version':'2.0','generator':'PT.8 shared DXR gallery'},'buffers':[{'uri':'gallery.bin','byteLength':len(data)}],'bufferViews':views,'accessors':accessors,'materials':materials,'meshes':meshes,'nodes':[{'name':m['name'],'mesh':i} for i,m in enumerate(meshes)],'scenes':[{'nodes':list(range(len(meshes)))}],'scene':0}
(out/'gallery.bin').write_bytes(data)
(out/'gallery.gltf').write_text(json.dumps(scene,ensure_ascii=False),encoding='utf-8')
print(out/'gallery.gltf')
