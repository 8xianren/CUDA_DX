"""资料导航与本地链接检查。默认只检查；--write按实际文件重新生成导航和JSON目录。

不扫描第三方构建缓存、下载资产或结果目录的内部文档，不把生成物计为课程源码。
检查区分仓内文件、清单声明的待生成产物和本机外部参考，不声称历史实验重新验收通过。
所有路径均从脚本定位仓库，运行目录无关；不会移动或删除文件。
"""
import argparse
import json
import os
import re
from pathlib import Path, PureWindowsPath
from urllib.parse import unquote

LEARNING = Path(__file__).resolve().parents[1]
REPO = LEARNING.parent
EXCLUDE = {'build', 'results', 'downloads', 'runtime', 'node_modules', '.git',
           '__pycache__', '.venv', 'venv', '_deps', 'plot_packages', 'third_party'}
LINES = [('cuda', 'CUDA'), ('particles', '粒子'), ('d3d12', 'D3D12 / DXR'),
         ('path_tracing', '路径追踪')]
CODE = {'.cu', '.cuh', '.cpp', '.h', '.hpp', '.hlsl', '.hlsli', '.py', '.ps1'}

def files(root):
    for folder, directories, names in os.walk(root):
        directories[:] = sorted(d for d in directories if d not in EXCLUDE)
        for name in sorted(names):
            yield Path(folder) / name

def title(path):
    text = path.read_text(encoding='utf-8-sig')
    return next((line.lstrip('# ').strip() for line in text.splitlines() if line.startswith('# ')), path.stem)

def catalog():
    courses = []
    for line, label in LINES:
        for folder in sorted((LEARNING / 'sandbox' / line).iterdir()):
            if not folder.is_dir() or folder.name in EXCLUDE or folder.name == 'common':
                continue
            readme = folder / 'README.md'
            code = [p for p in files(folder) if p.suffix.lower() in CODE]
            if not code:
                continue
            courses.append({'line': line, 'label': label, 'directory': folder.relative_to(LEARNING).as_posix(),
                            'title': title(readme) if readme.exists() else folder.name,
                            'readme': readme.relative_to(LEARNING).as_posix(), 'has_readme': readme.exists(),
                            'files': [p.relative_to(LEARNING).as_posix() for p in code]})
    notes = [p for p in (LEARNING / '笔记').rglob('*.md') if p.name != 'README.md']
    return {'course_count': len(courses), 'source_script_count': sum(len(c['files']) for c in courses),
            'note_count': len(notes), 'courses': courses,
            'notes': [p.relative_to(LEARNING).as_posix() for p in sorted(notes)]}

def write_catalog(data):
    (LEARNING / '资料目录.json').write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
    text = '# 全部学习资料导航\n\n由 `python learning/tools/catalog.py --write` 按实际目录生成。'
    text += '本页表示资料存在，课程是否完成请看[进度](进度.md)。\n\n'
    text += f"共 **{data['course_count']} 个程序课程目录、{data['source_script_count']} 个源码/脚本、{data['note_count']} 篇讲义**；不含构建缓存、资产下载和运行结果。\n\n"
    text += '- [当前Demo与快速入口](README.md)\n- [完整讲义索引](笔记/README.md)\n- [后续渲染器路线](规划/渲染器后续优化路线.md)\n- [环境与构建](环境与构建.md)\n\n'
    for line, label in LINES:
        text += f'## {label}\n\n[线路说明](sandbox/{line}/README.md) · [讲义](笔记/{line}/README.md)\n\n|课程程序|源码/脚本数|\n|---|---:|\n'
        for course in data['courses']:
            if course['line'] == line:
                text += f"|[{course['title']}]({course['readme']})|{len(course['files'])}|\n"
        text += '\n'
    text += '## 公共组件与历史\n\n- [单文件程序路径辅助](sandbox/common/README.md)\n- [D3D显示公共组件](sandbox/d3d12/common/README.md)\n- [整理与历史资料](归档/README.md)\n\n逐文件清单见[资料目录.json](资料目录.json)。\n'
    (LEARNING / '资料导航.md').write_text(text, encoding='utf-8')

def load_artifacts():
    """只信任版本控制中的精确清单，不按图片后缀或 results 目录整体豁免。

    清单自身必须指向仓内路径，并且恢复说明必须存在；拼错新图片路径、
    删除课程 README 或清单损坏仍会使检查失败。外部参考也须逐项声明。
    """
    manifest = json.loads((Path(__file__).parent / 'generated-artifacts.json').read_text(encoding='utf-8'))
    if manifest.get('schema_version') != 1:
        raise ValueError('不支持的生成物清单版本')
    artifacts = {}
    for item in manifest['artifacts']:
        path, readme = item['path'], item['readme']
        for relative in (path, readme):
            if Path(relative).is_absolute() or not (REPO / relative).resolve().is_relative_to(REPO.resolve()):
                raise ValueError('清单路径必须在仓库内：' + relative)
        if path in artifacts or not (REPO / readme).is_file():
            raise ValueError('清单重复或课程 README 缺失：' + path)
        artifacts[path] = item
    # Windows 绝对路径是参考资料的位置，不是可迁移的仓库文件。这里按原始
    # 链接规范化匹配，即使在别的盘符或系统检查，也不会误当成仓内相对路径。
    external = {external_key(item['path']): item for item in manifest['external_resources']}
    return artifacts, external


def external_key(path):
    return str(PureWindowsPath(path)).casefold() if PureWindowsPath(path).is_absolute() else str(Path(path))


def check_links():
    artifacts, declared_external = load_artifacts()
    broken, pending, external, generated_present = [], [], [], []
    count, present = 0, 0
    documents = [p for p in files(LEARNING) if p.suffix == '.md']
    documents += [REPO / 'CUDA_DX.md']
    for document in documents:
        for match in re.finditer(r'!?\[[^\]\n]*\]\((<[^>]+>|[^)\n]+)\)', document.read_text(encoding='utf-8-sig')):
            target = match.group(1).strip().strip('<>')
            if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*://', target) or target.startswith(('#', 'mailto:')):
                continue
            target = unquote(target.split('#')[0])
            if not target or '<' in target or '{' in target:
                continue
            path = Path(target)
            resolved = (path if path.is_absolute() else document.parent / path).resolve()
            count += 1
            link = {'document': document.relative_to(REPO).as_posix(), 'target': target}
            # 两处教材/SDK 路径是明确声明的外部参考，缺失时提示本机准备；
            # 未声明的绝对路径或相对路径不会因此被一概忽略。
            reference = declared_external.get(external_key(target))
            if reference is not None:
                external.append({**link, **reference, 'exists': path.exists()})
                continue
            relative = resolved.relative_to(REPO.resolve()).as_posix() if resolved.is_relative_to(REPO.resolve()) else None
            artifact = artifacts.get(relative)
            if resolved.exists():
                present += 1
                if artifact is not None:
                    generated_present.append({**link, **artifact})
            elif artifact is not None:
                pending.append({**link, **artifact, 'status': 'pending_local_generation'})
            else:
                broken.append(link)
    return {'checked_links': count, 'local_links_present': present, 'broken_links': broken,
            'pending_generated': pending, 'external_resources': external,
            'known_generated_present': generated_present}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    data = catalog()
    if args.write:
        write_catalog(data)
    # 报告本身也是资料入口的链接目标。首次运行先建立目标文件，避免将即将
    # 生成的报告误判为断链；最终内容仍在全部检查完成后一次写入。
    out = LEARNING / '归档' / '资料检查.json'
    out.parent.mkdir(parents=True, exist_ok=True)
    if not out.exists():
        out.write_text('{}', encoding='utf-8')
    links = check_links()
    missing = [c['directory'] for c in data['courses'] if not c['has_readme']]
    # 这是当前检出目录的资料可用性报告。发布副本允许精确声明的生成物待恢复，
    # 不能把通过解释为图片已经存在或 GPU 实验重新通过；不修改历史验收摘要。
    report = {'pass': not links['broken_links'] and not missing,
              'scope': 'current_checkout_documentation', 'workspace_root': REPO.as_posix(),
              'generated_artifact_status': 'pending_local_generation' if links['pending_generated'] else 'all_declared_links_present',
              **links,
              'missing_course_readmes': missing, 'course_count': data['course_count'],
              'source_script_count': data['source_script_count'], 'note_count': data['note_count']}
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2))
    raise SystemExit(0 if report['pass'] else 1)

if __name__ == '__main__':
    main()
