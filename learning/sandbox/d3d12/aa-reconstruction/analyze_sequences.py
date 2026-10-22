"""F.10: 固定场景序列的数值评测，而非用单张截图/显示 FPS 代替时域质量。

默认要求 reference/noaa 和所有列出的模式各120帧；缺帧时显式失败并写 coverage.json。
输入是 D3D12 读回的 float32 RGBA（线性HDR），不含最后的UI。GPU计时另读 benchmark。
依赖：numpy、Pillow（只用来编码评测图的像素到PNG，不参与误差计算）。
"""
from __future__ import annotations
import argparse
import base64
import csv
import html
import io
import json
import math
from pathlib import Path
import tempfile
import numpy as np
from PIL import Image

ROOT=Path(__file__).resolve().parent
DEFAULT_METHODS=('reference,noaa,msaa4,fxaa,taa,taa-no-reprojection,taa-no-rejection,taa-no-clamp,'
                 'bilinear,bicubic,nis,fsr-native,fsr-quality,fsr-balanced,fsr-performance,'
                 'xess-native,xess-quality,xess-balanced,xess-performance')
LIMITATIONS=[
    'reference为4倍横纵分辨率真实光栅+4x4 box（16样本/输出像素），是有限参考，不是解析真值；alpha测试和高频纹理仍可能混叠。',
    '所有质量指标比较相同frame/time/camera/exposure；Camera Cut在frame60，时域差分不跨过该跳变。',
    'display域使用与DisplayPS一致的exposure=0、max(HDR,0)、Reinhard、sRGB编码；未量化为8位，UI未进入指标。',
    'error_temporal_delta_rms衡量重建误差的相邻帧变化，不是直接对场景颜色作差，也不等价于人眼闪烁或运动补偿后的感知质量。',
    '显露/ROI由noaa单采样guide估计，轮廓处存在分类误差；motion为不含jitter的previous-current UV。',
    'disocclusion只标记前帧深度明显更近的已有像素，不把所有depth mismatch或画面外位置都叫显露。',
    'transparent_particle_roi由最后写入guide的z≈3平面识别，是单层近似，不是多层透明的真实coverage/运动。',
    '性能与质量分离：这里的sequence启用调试与读回，正式GPU成本取benchmark模式；不把offscreen时间当端到端FPS。',
    '公平分组按实际render_width×render_height，不能假定不同SDK相同quality标签对应同一内部像素数。',
    'TAA捕获经过独立UnjitterCS回到固定输出格点，其成本计入重建GPU时间；history仍保留jittered格点，linear-clamp会影响最外圈像素。',
]


def display_transform(linear):
    value=np.maximum(linear,0)
    value=value/(1+value)
    return np.where(value<=.0031308,value*12.92,1.055*np.power(value,1/2.4)-.055)


def read_rgba(path,w,h):
    data=np.fromfile(path,dtype='<f4')
    if data.size!=w*h*4: raise ValueError(f'wrong byte length: {path}')
    result=data.reshape(h,w,4)
    if not np.isfinite(result).all(): raise ValueError(f'nonfinite GPU data: {path}')
    return result


def validate_coverage(sequence_root,methods,frames):
    summaries={};missing=[]
    for method in methods:
        directory=sequence_root/method
        try: summary=json.loads((directory/'summary.json').read_text())
        except (OSError,ValueError): missing.append({'method':method,'reason':'missing/invalid summary'});continue
        if not summary.get('pass') or summary.get('frames')!=frames or not summary.get('capture'):
            missing.append({'method':method,'reason':'summary must report pass/capture and exact requested frames','actual_frames':summary.get('frames')});continue
        # 单独运行分析也必须保护算法身份，不能依赖外层 verify.ps1：初始化失败的
        # bilinear 回退同样能生成完整帧，但这些像素不属于标题中的官方 SDK 算法。
        if method in DEFAULT_METHODS.split(',') and method.startswith(('fsr-','xess-')) and summary.get('fallback') is not False:
            missing.append({'method':method,'reason':'official SDK mode must explicitly report fallback=false'});continue
        w,h=summary['output_width'],summary['output_height']
        incomplete=[i for i in range(frames) if not (directory/f'frame-{i:03}.f32').is_file()
                    or (directory/f'frame-{i:03}.f32').stat().st_size!=w*h*16]
        if incomplete: missing.append({'method':method,'reason':'missing/truncated color frames','frames':incomplete});continue
        if method=='noaa':
            incomplete=[i for i in range(frames) if not (directory/f'frame-{i:03}-guide.f32').is_file()
                        or (directory/f'frame-{i:03}-guide.f32').stat().st_size!=w*h*16]
            if incomplete: missing.append({'method':method,'reason':'missing/truncated noaa guide','frames':incomplete});continue
        summaries[method]=summary
    if 'reference' in summaries:
        expected=(summaries['reference']['output_width'],summaries['reference']['output_height'])
        for method in list(summaries):
            if (summaries[method]['output_width'],summaries[method]['output_height'])!=expected:
                missing.append({'method':method,'reason':'output extent differs from reference'});del summaries[method]
    return summaries,missing


def guide_masks(directory,w,h,frames,cut):
    """先在CPU为每帧重建一个保守显露标记，再用于所有模式，避免各算法选不同ROI。"""
    yy,xx=np.mgrid[:h,:w];old=None;masks=[];counts=[]
    for frame in range(frames):
        guide=read_rgba(directory/f'frame-{frame:03}-guide.f32',w,h)
        z=guide[:,:,2];expected=guide[:,:,3]
        sx=xx+.5+guide[:,:,0]*w;sy=yy+.5+guide[:,:,1]*h
        in_bounds=(sx>=0)&(sx<w)&(sy>=0)&(sy<h)
        ix=np.clip(np.floor(sx).astype(int),0,w-1);iy=np.clip(np.floor(sy).astype(int),0,h-1)
        valid_surface=(z>0)&(z<99)
        if old is None or frame==cut:
            exposed=np.zeros((h,w),dtype=bool);depth_mismatch=np.zeros_like(exposed)
        else:
            actual=old[iy,ix,2]
            tolerance=np.maximum(.001,np.abs(expected)*.02)
            exposed=in_bounds&valid_surface&(actual<expected-tolerance)
            depth_mismatch=in_bounds&valid_surface&(np.abs(actual-expected)>tolerance)
        transparent=np.abs(z-3)<.01
        # 透明guide只有一层，排除它，避免把alpha混合误解释为几何显露。
        exposed &= ~transparent
        groups={'static_background':(np.abs(z-7)<.01)&~exposed&in_bounds,
                'moving_occluder':np.abs(z-3.4)<.01,
                'disocclusion':exposed,'transparent_particle_roi':transparent,
                'depth_mismatch':depth_mismatch}
        masks.append(groups)
        counts.append({'frame':frame,**{key:int(mask.sum()) for key,mask in groups.items()}})
        old=guide
    return masks,counts


def statistics(error,display_error,mask=None):
    hdr=error if mask is None else error[mask]
    disp=display_error if mask is None else display_error[mask]
    if hdr.size==0: return {'count':0,'hdr_square_sum':0.,'display_square_sum':0.,'display_abs_sum':0.}
    return {'count':int(hdr.size),'hdr_square_sum':float(np.sum(hdr*hdr,dtype=np.float64)),
            'display_square_sum':float(np.sum(disp*disp,dtype=np.float64)),
            'display_abs_sum':float(np.sum(abs(disp),dtype=np.float64))}


def summarized(s):
    n=s['count']
    if not n:return {'rgb_component_samples':0,'hdr_mse':None,'display_mae':None,'display_mse':None,'display_psnr_db':None}
    mse=s['display_square_sum']/n
    return {'rgb_component_samples':n,'hdr_mse':s['hdr_square_sum']/n,
            'display_mae':s['display_abs_sum']/n,'display_mse':mse,
            'display_psnr_db':-10*math.log10(mse) if mse>0 else None,
            'psnr_is_infinite':mse==0}


def accumulate(total,s):
    for key,value in s.items():total[key]=total.get(key,0)+value


def write_csv(path,rows):
    if not rows:return
    with path.open('w',newline='',encoding='utf-8') as file:
        writer=csv.DictWriter(file,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)


def analyze_method(sequence_root,method,summary,masks,frames,cut,out):
    w,h=summary['output_width'],summary['output_height']
    totals={name:{} for name in ('full','static_background','moving_occluder','disocclusion','transparent_particle_roi','depth_mismatch')}
    rows=[];previous_error=None;temporal_square=0.;temporal_count=0
    for frame in range(frames):
        color=read_rgba(sequence_root/method/f'frame-{frame:03}.f32',w,h)[:,:,:3].astype(np.float64)
        reference=read_rgba(sequence_root/'reference'/f'frame-{frame:03}.f32',w,h)[:,:,:3].astype(np.float64)
        hdr_error=color-reference;error=display_transform(color)-display_transform(reference)
        full=statistics(hdr_error,error);accumulate(totals['full'],full)
        metrics=summarized(full)
        row={'frame':frame,'camera_cut':int(frame==cut),'hdr_mse':metrics['hdr_mse'],
             'display_mae':metrics['display_mae'],'display_psnr_db':metrics['display_psnr_db'],
             'error_temporal_delta_rms':None}
        # 对“相对于同帧参考的误差”作差，真实运动颜色变化已由reference消去。
        # 误差图案本身随运动移动仍会影响此数值，所以它不是感知flicker的同义词。
        if previous_error is not None and frame!=cut:
            change=error-previous_error;square=float(np.sum(change*change,dtype=np.float64))
            temporal_square+=square;temporal_count+=change.size
            row['error_temporal_delta_rms']=math.sqrt(square/change.size)
        for name,mask in masks[frame].items():
            stats=statistics(hdr_error,error,mask);accumulate(totals[name],stats);values=summarized(stats)
            row[name+'_pixels']=int(mask.sum());row[name+'_display_mae']=values['display_mae'];row[name+'_hdr_mse']=values['hdr_mse']
        previous_error=error;rows.append(row)
    directory=out/'per-method';directory.mkdir(parents=True,exist_ok=True)
    write_csv(directory/(method+'.csv'),rows)
    result={'method':method,'frames':frames,'render_width':summary['render_width'],
            'render_height':summary['render_height'],'output_width':w,'output_height':h,
            'render_pixel_ratio':summary['render_width']*summary['render_height']/(w*h),
            'provider':summary.get('provider','none'),**summarized(totals['full']),
            'error_temporal_delta_rms':math.sqrt(temporal_square/temporal_count) if temporal_count else None,
            'temporal_frame_pairs':frames-1-int(0<cut<frames),
            'roi':{name:summarized(value) for name,value in totals.items() if name!='full'},
            'cut_frame_metrics':{str(i):rows[i] for i in range(max(0,cut-1),min(frames,cut+4))},
            'worst_display_error_frame':max(range(frames),key=lambda i:rows[i]['display_mae'])}
    return result,rows


def image_png_data(rgb,max_width=320):
    image=Image.fromarray(np.round(np.clip(rgb,0,1)*255).astype(np.uint8))
    if image.width>max_width:
        image=image.resize((max_width,round(image.height*max_width/image.width)),Image.Resampling.LANCZOS)
    buffer=io.BytesIO();image.save(buffer,format='PNG')
    return 'data:image/png;base64,'+base64.b64encode(buffer.getvalue()).decode('ascii')


def contact_sheet(sequence_root,summaries,out,frames,cut):
    preferred=['reference','noaa','msaa4','fxaa','taa','taa-no-reprojection','taa-no-rejection','taa-no-clamp',
               'bilinear','bicubic','nis','fsr-quality','xess-quality']
    methods=[m for m in preferred if m in summaries]
    samples=sorted(set(min(frames-1,max(0,i)) for i in (30,cut-1,cut,frames-1)))
    tile_width=320;tile_height=180;left=210;top=70;gap=10
    width=left+len(samples)*(tile_width+gap)+20;height=top+len(methods)*(tile_height+gap)+45
    svg=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
         '<rect width="100%" height="100%" fill="#101820"/>',
         '<g font-family="Segoe UI,Arial,sans-serif" fill="#e8edf4">',
         '<text x="16" y="25" font-size="20">F.10 fixed-scene reconstruction: display transform, exposure=0</text>',
         '<text x="16" y="48" font-size="13">Same frame/time/camera; frame 60 = camera cut; images are previews, metrics use full float data.</text>']
    for column,frame in enumerate(samples):svg.append(f'<text x="{left+column*(tile_width+gap)}" y="65" font-size="14">frame {frame:03}</text>')
    for row,method in enumerate(methods):
        summary=summaries[method];y=top+row*(tile_height+gap)
        svg.append(f'<text x="12" y="{y+28}" font-size="15">{html.escape(method)}</text>')
        svg.append(f'<text x="12" y="{y+50}" font-size="13">{summary["render_width"]} x {summary["render_height"]}</text>')
        for column,frame in enumerate(samples):
            rgb=read_rgba(sequence_root/method/f'frame-{frame:03}.f32',summary['output_width'],summary['output_height'])[:,:,:3]
            data=image_png_data(display_transform(rgb),tile_width)
            svg.append(f'<image x="{left+column*(tile_width+gap)}" y="{y}" width="{tile_width}" height="{tile_height}" href="{data}"/>')
    svg.extend(['</g>','</svg>']);(out/'contact-sheet.svg').write_text('\n'.join(svg),encoding='utf-8')


def error_plot(rows_by_method,out,cut):
    chosen=[m for m in ('noaa','fxaa','taa','taa-no-reprojection','taa-no-rejection','taa-no-clamp','fsr-quality','xess-quality') if m in rows_by_method]
    if not chosen:return
    colors=['#aeb8c5','#f9cc6c','#67d1b2','#e17da3','#ff9261','#a991e3','#67bdf1','#e5e57b']
    width,height=1100,430;left,top,pw,ph=75,55,770,310
    maximum=max(row['display_mae'] for m in chosen for row in rows_by_method[m])*1.05
    maximum=max(maximum,1e-8);frames=len(rows_by_method[chosen[0]])
    svg=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">',
         '<rect width="100%" height="100%" fill="#101820"/>',
         '<g font-family="Segoe UI,Arial,sans-serif" fill="#e8edf4">',
         '<text x="20" y="28" font-size="20">Per-frame display MAE relative to the same-frame 4x raster reference</text>']
    for i in range(6):
        y=top+ph-i*ph/5;value=maximum*i/5
        svg.extend([f'<path d="M{left},{y}h{pw}" stroke="#34404c"/>',
                    f'<text x="8" y="{y+5}" font-size="12">{value:.4f}</text>'])
    for i in range(0,frames,20):
        x=left+i/(frames-1)*pw;svg.append(f'<text x="{x}" y="{top+ph+24}" font-size="12">{i}</text>')
    for index,method in enumerate(chosen):
        points=' '.join(f'{left+i/(frames-1)*pw:.2f},{top+ph-row["display_mae"]/maximum*ph:.2f}' for i,row in enumerate(rows_by_method[method]))
        svg.append(f'<polyline points="{points}" fill="none" stroke="{colors[index]}" stroke-width="1.8"/>')
        svg.append(f'<text x="870" y="{65+index*24}" fill="{colors[index]}" font-size="13">{html.escape(method)}</text>')
    if 0<=cut<frames:
        x=left+cut/(frames-1)*pw;svg.append(f'<path d="M{x},{top}v{ph}" stroke="#eee" stroke-dasharray="5 5"/>')
        svg.append(f'<text x="{x+5}" y="{top+15}" font-size="12">camera cut</text>')
    svg.extend(['<text x="25" y="420" font-size="12">No shared-quality-label inference: inspect actual input extents in metrics.csv. This plot measures error, not FPS.</text>','</g></svg>'])
    (out/'error-over-time.svg').write_text('\n'.join(svg),encoding='utf-8')


def self_test():
    """只验评测数学：已知常量误差/显露/缺帧。绝不将这些合成数据纳入GPU质量报告。"""
    with tempfile.TemporaryDirectory(prefix='f10-analysis-') as temporary:
        root=Path(temporary)
        for method,value in [('reference',.5),('noaa',.25)]:
            folder=root/method;folder.mkdir()
            summary={'pass':True,'frames':3,'capture':True,'render_width':8 if method=='reference' else 2,
                     'render_height':8 if method=='reference' else 2,'output_width':2,'output_height':2}
            (folder/'summary.json').write_text(json.dumps(summary))
            for frame in range(3):
                pixels=np.ones((2,2,4),dtype='<f4');pixels[:,:,:3]=value;pixels.tofile(folder/f'frame-{frame:03}.f32')
                if method=='noaa':
                    guide=np.zeros((2,2,4),dtype='<f4');guide[:,:,2:]=7
                    if frame==1:guide[:,:,2]=2
                    guide.tofile(folder/f'frame-{frame:03}-guide.f32')
        summaries,missing=validate_coverage(root,['reference','noaa'],3);assert not missing
        masks,counts=guide_masks(root/'noaa',2,2,3,1)
        assert counts[2]['disocclusion']==4 and counts[1]['disocclusion']==0
        out=root/'out';out.mkdir()
        result,rows=analyze_method(root,'noaa',summaries['noaa'],masks,3,1,out)
        assert result['hdr_mse']==.0625 and result['error_temporal_delta_rms']==0
        assert result['temporal_frame_pairs']==1 and rows[1]['error_temporal_delta_rms'] is None
        assert result['roi']['disocclusion']['rgb_component_samples']==12
        (root/'noaa'/'frame-002.f32').unlink()
        _,missing=validate_coverage(root,['reference','noaa'],3);assert missing[0]['frames']==[2]
        # 帧文件齐全、pass=true 仍不能把回退包装成 SDK 质量；再改为真实身份
        # 检查合法模式不会被误拒绝。这里仍只有CPU合成数据，不进入正式报告。
        sdk=root/'fsr-quality';sdk.mkdir()
        sdk_summary={'pass':True,'frames':3,'capture':True,'fallback':True,
                     'render_width':1,'render_height':1,'output_width':2,'output_height':2}
        for frame in range(3):np.ones((2,2,4),dtype='<f4').tofile(sdk/f'frame-{frame:03}.f32')
        (sdk/'summary.json').write_text(json.dumps(sdk_summary))
        found,missing=validate_coverage(root,['fsr-quality'],3)
        assert not found and missing[0]['reason']=='official SDK mode must explicitly report fallback=false'
        sdk_summary['fallback']=False;(sdk/'summary.json').write_text(json.dumps(sdk_summary))
        found,missing=validate_coverage(root,['fsr-quality'],3);assert 'fsr-quality' in found and not missing
    return {'pass':True,'execution':'CPU analysis mathematics only',
            'checks':['known_HDR_MSE_0.0625','constant_error_has_zero_temporal_delta','cut_pair_excluded',
                      'depth_disocclusion_4_pixels','ROI_sample_count_12','missing_frame_rejected',
                      'official_SDK_fallback_rejected_despite_complete_frames']}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sequences',type=Path,default=ROOT/'results/f10/sequences')
    parser.add_argument('--output',type=Path,default=ROOT/'results/f10/quality')
    parser.add_argument('--methods',default=DEFAULT_METHODS)
    parser.add_argument('--frames',type=int,default=120)
    parser.add_argument('--camera-cut-frame',type=int,default=60)
    parser.add_argument('--allow-incomplete',action='store_true',help='只评完整方法，报告仍pass=false且退出2；不隐藏缺项')
    parser.add_argument('--self-test',action='store_true',help='验证评测数学与缺帧保护，不运行GPU')
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    if args.self_test:
        result=self_test();target=ROOT/'results/f10/analysis-unit.json';target.parent.mkdir(parents=True,exist_ok=True)
        target.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result));return 0
    if args.frames<2:raise ValueError('at least two frames are required')
    methods=list(dict.fromkeys(['reference','noaa']+args.methods.split(',')))
    summaries,missing=validate_coverage(args.sequences,methods,args.frames)
    coverage={'pass':not missing,'required_frames':args.frames,'complete_methods':list(summaries),'missing':missing}
    (args.output/'coverage.json').write_text(json.dumps(coverage,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    if ('reference' not in summaries or 'noaa' not in summaries) or (missing and not args.allow_incomplete):
        print(json.dumps(coverage,ensure_ascii=False));return 2
    w,h=summaries['reference']['output_width'],summaries['reference']['output_height']
    masks,mask_counts=guide_masks(args.sequences/'noaa',w,h,args.frames,args.camera_cut_frame)
    write_csv(args.output/'roi-mask-counts.csv',mask_counts)
    empty_rois=[name for name in ('static_background','moving_occluder','disocclusion','transparent_particle_roi')
                if sum(row[name] for row in mask_counts)==0]
    if empty_rois:raise ValueError('required scene ROI was never observed: '+', '.join(empty_rois))
    results=[];rows_by_method={}
    for method,summary in summaries.items():
        print('analyzing '+method,flush=True)
        result,rows=analyze_method(args.sequences,method,summary,masks,args.frames,args.camera_cut_frame,args.output)
        results.append(result);rows_by_method[method]=rows
    groups={}
    for result in results:groups.setdefault(f'{result["render_width"]}x{result["render_height"]}',[]).append(result['method'])
    final={'pass':not missing,'reference':'4x per axis real raster + 4x4 box (16 finite samples/output pixel)',
           'frames':args.frames,'camera_cut_frame':args.camera_cut_frame,'limitations':LIMITATIONS,
           'same_input_pixel_groups':groups,'missing':missing,'methods':results}
    (args.output/'summary.json').write_text(json.dumps(final,ensure_ascii=False,indent=2,allow_nan=False)+'\n',encoding='utf-8')
    fields=['method','render_width','render_height','render_pixel_ratio','hdr_mse','display_mae','display_psnr_db',
            'error_temporal_delta_rms','worst_display_error_frame']
    write_csv(args.output/'metrics.csv',[{key:record[key] for key in fields} for record in results])
    contact_sheet(args.sequences,summaries,args.output,args.frames,args.camera_cut_frame)
    error_plot(rows_by_method,args.output,args.camera_cut_frame)
    print(json.dumps({'pass':not missing,'complete_methods':len(results),'output':str(args.output)}))
    return 0 if not missing else 2


if __name__=='__main__':raise SystemExit(main())
