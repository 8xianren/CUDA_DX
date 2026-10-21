"""H1 可复现资产准备：只选择本课所需文件，不执行下载包中的脚本。

这里只解析 JSON 元数据选资源；运行时依然由固定版本 Assimp 解码网格与动画。
归档哈希用于识别作者更新，并非声称未来下载永远返回相同版本。
"""
from pathlib import Path
import hashlib
import json
import shutil
import zipfile

ROOT = Path(__file__).resolve().parent
CACHE = ROOT / 'assets/downloads'
OUT = ROOT / 'assets/runtime'
OUT.mkdir(parents=True, exist_ok=True)
SOURCES = {
    'animations': ('universal-animation-library.zip', 'https://quaternius.com/packs/universalanimationlibrary.html'),
    'characters': ('universal-base-characters.zip', 'https://quaternius.com/packs/universalbasecharacters.html'),
    'nature': ('kenney_nature-kit.zip', 'https://kenney.nl/assets/nature-kit'),
}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def unique(folder, pattern):
    matches = list(folder.rglob(pattern))
    if len(matches) != 1:
        raise ValueError(f'Expected one {pattern}, got {len(matches)}')
    return matches[0]

def main():
    manifest = {'date': '2026-10-21', 'license': 'CC0-1.0', 'archives': {}, 'files': {}}
    for key, (archive, url) in SOURCES.items():
        destination = CACHE / key
        destination.mkdir(exist_ok=True)
        with zipfile.ZipFile(CACHE / archive) as z:
            # 解压前检查每个规范路径，避免第三方归档写到课程目录之外。
            for entry in z.infolist():
                if not (destination / entry.filename).resolve().is_relative_to(destination.resolve()):
                    raise ValueError('Archive path escapes destination')
            z.extractall(destination)
        manifest['archives'][key] = {'source': url, 'filename': archive, 'sha256': digest(CACHE / archive)}
    def copy(source, name):
        target = OUT / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        manifest['files'][name] = {'sha256': digest(target), 'bytes': target.stat().st_size,
                                  'source_member': str(source.relative_to(CACHE)).replace('\\', '/')}
    # 无 RM 后缀的动画是作者提供的原地版本，避免世界运动与根运动重复叠加。
    copy(unique(CACHE / 'animations', 'UAL1_Standard.glb'), 'animation.glb')
    model = unique(CACHE / 'characters', 'Superhero_Male_FullBody.gltf')
    copy(model, 'character/character.gltf')
    doc = json.loads(model.read_text(encoding='utf-8'))
    for item in doc.get('buffers', []) + doc.get('images', []):
        uri = item.get('uri')
        if uri and not uri.startswith('data:'):
            src = (model.parent / uri).resolve()
            if not src.is_relative_to(model.parent.resolve()):
                raise ValueError('External asset escapes model folder')
            # 此版本作者 glTF 的两张法线图 URI 多了 _png；仅修复已核对的精确映射。
            # 保留 glTF URI，在输出端复制为它要求的名字，清单记录真实来源，禁止任意模糊匹配。
            aliases = {'T_Hair_1_Normal_png.png': 'T_Hair_1_Normal.png',
                       'T_Eye_Normal_png.png': 'T_Eye_Normal.png'}
            if not src.exists() and uri in aliases:
                src = model.parent / aliases[uri]
            copy(src, 'character/' + uri)
    nature = CACHE / 'nature/Models/GLTF format'
    selected = ['rock_largeA.glb', 'rock_smallA.glb', 'plant_bush.glb']
    trees = sorted(nature.glob('tree*.glb'))
    if not trees:
        raise ValueError('No tree assets')
    selected += [trees[0].name, trees[min(5, len(trees)-1)].name]
    for name in selected:
        copy(nature / name, 'nature/' + name)
    for key in SOURCES:
        copy(unique(CACHE / key, 'License*.txt'), 'licenses/' + key + '.txt')
    # 仓库保存许可和清单，较大原始素材由脚本恢复。
    licenses = ROOT / 'assets/licenses'
    licenses.mkdir(exist_ok=True)
    for source in (OUT / 'licenses').iterdir():
        shutil.copy2(source, licenses / source.name)
    (ROOT / 'assets/manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print('Prepared', len(manifest['files']), 'files; manifest:', ROOT / 'assets/manifest.json')

if __name__ == '__main__':
    main()
