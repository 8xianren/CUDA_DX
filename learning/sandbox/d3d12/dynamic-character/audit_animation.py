"""H2 独立参考：原始 glTF 秒时间、四元数短弧插值与 double 层级/蒙皮。
对照实际 CUDA 读回的 Walk 中点，避免 CPU/GPU 共用错误 palette 却互相判定正确。
"""
from audit_gltf import ROOT,read_glb,accessor,local
import json
import numpy as np

def interpolate(a,b,u,rotation):
    if not rotation:return (1-u)*a+u*b
    dot=float(a@b)
    if dot<0:b=-b;dot=-dot
    if dot>.9995:q=(1-u)*a+u*b
    else:
        theta=np.arccos(np.clip(dot,-1,1));q=(np.sin((1-u)*theta)*a+np.sin(u*theta)*b)/np.sin(theta)
    return q/np.linalg.norm(q)

def main():
    doc,blob=read_glb(ROOT/'assets/runtime/animation.glb')
    clip=next(a for a in doc['animations'] if a['name']=='Walk_Loop')
    duration=max(float(accessor(doc,blob,s['input'])[-1,0]) for s in clip['samplers']);time=duration*.5
    nodes=[dict(n) for n in doc['nodes']]
    for channel in clip['channels']:
        s=clip['samplers'][channel['sampler']];assert s.get('interpolation','LINEAR')=='LINEAR'
        t=accessor(doc,blob,s['input']).ravel();v=accessor(doc,blob,s['output']);path=channel['target']['path']
        if time<=t[0]:value=v[0]
        elif time>=t[-1]:value=v[-1]
        else:
            right=np.searchsorted(t,time,side='right');left=right-1;u=(time-t[left])/(t[right]-t[left])
            value=interpolate(v[left],v[right],u,path=='rotation')
        nodes[channel['target']['node']][path]=value
    world={}
    def visit(i,parent):
        world[i]=parent@local(nodes[i])
        for child in nodes[i].get('children',[]):visit(child,world[i])
    for i in doc['scenes'][doc.get('scene',0)]['nodes']:visit(i,np.eye(4))
    actual_world={}
    for row in (ROOT/'results/h2/walk-world.csv').read_text().splitlines():
        parts=row.split(',');actual_world[parts[0]]=np.array(list(map(float,parts[1:]))).reshape(4,4)
    differences=sorted([(float(np.abs(world[i]-actual_world[node['name']]).max()),node['name']) for i,node in enumerate(nodes)],reverse=True)
    print('largest world differences',differences[:8])
    errors=[];mesh_index=0
    for ni,node in enumerate(nodes):
        if 'skin' not in node:continue
        skin=doc['skins'][node['skin']];ib=accessor(doc,blob,skin['inverseBindMatrices'])
        palette=np.array([np.linalg.inv(world[ni])@world[j]@ib[k].reshape(4,4,order='F') for k,j in enumerate(skin['joints'])])
        normals=np.linalg.inv(palette[:,:3,:3]).transpose(0,2,1)
        for primitive in doc['meshes'][node['mesh']]['primitives']:
            a=primitive['attributes'];p=accessor(doc,blob,a['POSITION']);n=accessor(doc,blob,a['NORMAL'])
            j=accessor(doc,blob,a['JOINTS_0']).astype(int);w=accessor(doc,blob,a['WEIGHTS_0'])
            hp=np.column_stack([p,np.ones(len(p))]);result=np.zeros_like(hp);normal=np.zeros_like(n)
            for k in range(4):
                result+=w[:,k,None]*np.einsum('nij,nj->ni',palette[j[:,k]],hp)
                normal+=w[:,k,None]*np.einsum('nij,nj->ni',normals[j[:,k]],n)
            normal/=np.linalg.norm(normal,axis=1)[:,None]
            actual=np.loadtxt(ROOT/f'results/h2/walk-mid-mesh-{mesh_index}.csv',delimiter=',',skiprows=1)
            reference=np.column_stack([result[:,:3],normal])
            # 固定Assimp的glTF2Importer.cpp按索引首次出现顺序重排顶点（不是Triangulate触发）。
            # 从原始索引独立重建对应关系，不用最近点匹配掩盖重复位置/不同权重。
            indices=accessor(doc,blob,primitive['indices']).astype(int).ravel()
            remap=list(dict.fromkeys(indices.tolist()))
            reference=reference[remap]
            imported_bind=np.array([row.split(',')[:3] for row in (ROOT/f'results/h2/bind-mesh-{mesh_index}.csv').read_text().splitlines()],float)
            assert np.max(np.abs(imported_bind-p[remap]))<1e-8
            assert actual.shape==reference.shape
            error=float(np.max(np.abs(reference-actual)))
            print('mesh',mesh_index,'position error',float(np.abs(reference[:,:3]-actual[:,:3]).max()),'normal error',float(np.abs(reference[:,3:]-actual[:,3:]).max()))
            assert error<2e-5
            errors.append(error);mesh_index+=1
    output={'pass':True,'clip':'Walk_Loop','seconds':time,'per_mesh_max_error':errors,'reference':'raw glTF float64 independent sampling, hierarchy and skin'}
    (ROOT/'results/h2/independent.json').write_text(json.dumps(output,indent=2)+'\n',encoding='utf-8');print(output)

if __name__=='__main__':main()
