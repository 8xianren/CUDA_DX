"""独立于 Assimp 的 H1 数值审计：直接读取原始 glTF accessor，验证绑定方程。

本工具只支持选定 GLB 使用的紧凑/交错、非 sparse 数据，不替代完整 glTF Validator。
运行时不使用此解析器。列主序矩阵在这里显式转成 NumPy 数学矩阵。
"""
from pathlib import Path
import json
import struct
import numpy as np

ROOT=Path(__file__).resolve().parent

def read_glb(path):
    raw=path.read_bytes()
    magic,version,length=struct.unpack_from('<III',raw)
    if magic!=0x46546c67 or version!=2 or length!=len(raw):
        raise ValueError('Invalid GLB header')
    chunks={};offset=12
    while offset<len(raw):
        size,kind=struct.unpack_from('<II',raw,offset);offset+=8
        if offset+size>len(raw):raise ValueError('GLB chunk bounds')
        chunks[kind]=raw[offset:offset+size];offset+=size
    return json.loads(chunks[0x4e4f534a]),chunks[0x004e4942]

def accessor(doc,blob,index):
    a=doc['accessors'][index];v=doc['bufferViews'][a['bufferView']]
    if 'sparse' in a or v.get('buffer',0)!=0:raise ValueError('Unsupported audit accessor')
    dtype={5126:'<f4',5125:'<u4',5123:'<u2',5121:'u1'}[a['componentType']]
    count={'SCALAR':1,'VEC2':2,'VEC3':3,'VEC4':4,'MAT4':16}[a['type']]
    item=np.dtype(dtype).itemsize;stride=v.get('byteStride',count*item)
    local=a.get('byteOffset',0);start=v.get('byteOffset',0)+local
    end=local+(a['count']-1)*stride+item*count
    if end>v['byteLength'] or v.get('byteOffset',0)+end>len(blob):raise ValueError('Accessor out of range')
    out=np.ndarray((a['count'],count),dtype=dtype,buffer=blob,offset=start,strides=(stride,item)).astype(np.float64)
    if a.get('normalized'):out/=np.iinfo(np.dtype(dtype)).max
    if not np.isfinite(out).all():raise ValueError('Nonfinite accessor')
    return out

def local(node):
    if 'matrix' in node:return np.array(node['matrix']).reshape(4,4,order='F')
    x,y,z,w=node.get('rotation',[0,0,0,1]);r=np.array([
        [1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],
        [2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],
        [2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]])
    m=np.eye(4);m[:3,:3]=r@np.diag(node.get('scale',[1,1,1]));m[:3,3]=node.get('translation',[0,0,0]);return m

def main():
    doc,blob=read_glb(ROOT/'assets/runtime/animation.glb')
    nodes=doc['nodes'];world={}
    def visit(index,parent):
        if index in world:raise ValueError('Duplicate/cyclic node')
        world[index]=parent@local(nodes[index])
        for child in nodes[index].get('children',[]):visit(child,world[index])
    for index in doc['scenes'][doc.get('scene',0)]['nodes']:visit(index,np.eye(4))
    bind_error=0;wrong_error=0;vertices=0;max_weight_error=0;bounds=[]
    for ni,node in enumerate(nodes):
        if 'skin' not in node:continue
        skin=doc['skins'][node['skin']];ib=accessor(doc,blob,skin['inverseBindMatrices'])
        matrices=np.array([np.linalg.inv(world[ni])@world[joint]@ib[i].reshape(4,4,order='F') for i,joint in enumerate(skin['joints'])])
        wrong=np.array([np.linalg.inv(world[ni])@world[joint] for joint in skin['joints']])
        for primitive in doc['meshes'][node['mesh']]['primitives']:
            attr=primitive['attributes'];p=accessor(doc,blob,attr['POSITION']);j=accessor(doc,blob,attr['JOINTS_0']).astype(int);w=accessor(doc,blob,attr['WEIGHTS_0'])
            if j.min()<0 or j.max()>=len(matrices):raise ValueError('Joint out of range')
            if (w<0).any():raise ValueError('Negative weight')
            hp=np.column_stack([p,np.ones(len(p))]);result=np.zeros_like(hp);bad=np.zeros_like(hp)
            for k in range(4):
                result+=w[:,k,None]*np.einsum('nij,nj->ni',matrices[j[:,k]],hp)
                bad+=w[:,k,None]*np.einsum('nij,nj->ni',wrong[j[:,k]],hp)
            bind_error=max(bind_error,float(np.abs(result-hp).max()));wrong_error=max(wrong_error,float(np.abs(bad-hp).max()))
            max_weight_error=max(max_weight_error,float(np.abs(w.sum(axis=1)-1).max()));vertices+=len(p)
            wp=(world[ni]@hp.T).T[:,:3];bounds.append([wp.min(axis=0).tolist(),wp.max(axis=0).tolist()])
    clips=[]
    for animation in doc['animations']:
        duration=0;interpolations=set()
        for sampler in animation['samplers']:
            times=accessor(doc,blob,sampler['input']).ravel()
            if not (np.diff(times)>0).all():raise ValueError('Nonincreasing animation time')
            duration=max(duration,float(times[-1]));interpolations.add(sampler.get('interpolation','LINEAR'))
        clips.append({'name':animation['name'],'seconds':duration,'interpolation':sorted(interpolations)})
    assert bind_error<1e-5 and max_weight_error<1e-5 and wrong_error>0.01
    output={'pass':True,'selected_character':'UAL1 embedded Mannequin; exact shared skeleton and animation',
            'vertices':vertices,'joints':len(doc['skins'][0]['joints']),'bind_position_error':bind_error,
            'omitted_inverse_bind_negative_control_error':wrong_error,'weight_error':max_weight_error,
            'world_bounds_per_primitive':bounds,'clips':clips}
    (ROOT/'results/h1/gltf-audit.json').write_text(json.dumps(output,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in output.items() if k not in ('clips','world_bounds_per_primitive')}))

if __name__=='__main__':main()
