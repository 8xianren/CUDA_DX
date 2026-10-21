"""将当前项目的主会话导出成可公开保存、可重新索引的 Codex JSONL 包。

源目录只读：仅查询线程元数据、读取该项目的 rollout（包括 zstd 压缩），
不会复制认证、配置、数据库或其它项目。输出与源文件分离。
保留用户可见消息、工具轨迹及必要生命周期；内部指令、推理、压缩上下文
不进入包。凭据规则是额外防线，不代表任意隐私信息均能自动识别。
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import zipfile

PACKAGE = Path(__file__).resolve().parents[1]
REPO = PACKAGE.parent
META_KEYS = {'id', 'session_id', 'timestamp', 'cwd', 'originator', 'cli_version',
             'source', 'thread_source', 'model_provider', 'history_mode', 'git'}
ITEM_TYPES = {'UserMessage', 'AgentMessage', 'CommandExecution', 'FileChange',
              'McpToolCall', 'ImageView'}
CALL_TYPES = {'function_call', 'custom_tool_call'}
OUTPUT_TYPES = {'function_call_output', 'custom_tool_call_output'}
DROP_KEYS = {'internal_chat_message_metadata_passthrough', 'encrypted_content',
             'creator_user_id', 'creator_account_id', 'turn_attribution'}
SECRET_KEYS = {'access_token', 'refresh_token', 'id_token', 'api_key', 'apikey',
               'client_secret', 'authorization', 'password'}
# 不输出命中值。统计仅保存规则名称与次数，避免脱敏报告反而泄露凭据。
RULES = [
    ('openai_key', re.compile(r'\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}')),
    ('github_token', re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})')),
    ('jwt', re.compile(r'\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}')),
    ('slack_token', re.compile(r'\bxox[baprs]-[A-Za-z0-9-]{20,}')),
    ('aws_access_key', re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b')),
    ('url_credentials', re.compile(r'(?<=://)[^\s/@:]{1,100}:[^\s/@]{6,}@')),
    ('private_key', re.compile(r'-----BEGIN (?:[A-Z ]+)?PRIVATE KEY-----.*?-----END (?:[A-Z ]+)?PRIVATE KEY-----', re.S)),
    ('bearer', re.compile(r'(?i)\bBearer\s+[A-Za-z0-9._~+/-]{20,}=*')),
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def plain(content):
    """仅提取界面文本；图片仍留在原始 content，不伪造其文字内容。"""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return '\n'.join(plain(part) for part in content if plain(part))
    if isinstance(content, dict):
        return content.get('text', '')
    return ''


def scrub(value, counts):
    if isinstance(value, dict):
        out = {}
        for key, child in value.items():
            if key in DROP_KEYS:
                continue
            if key.lower() in SECRET_KEYS and isinstance(child, str) and len(child) >= 12:
                out[key] = '[REDACTED_CREDENTIAL]'
                counts['credential_field'] += 1
            else:
                out[key] = scrub(child, counts)
        return out
    if isinstance(value, list):
        return [scrub(child, counts) for child in value]
    if isinstance(value, str):
        for label, pattern in RULES:
            value, n = pattern.subn('[REDACTED_' + label.upper() + ']', value)
            counts[label] += n
        return value
    return value


def read_snapshot(path):
    """先读有限字节快照，避免把正在追加的活动会话读成无限增长文件。"""
    raw = path.read_bytes()
    if path.suffix == '.zst':
        try:
            from compression import zstd  # 本机 Python 3.14；恢复端不依赖此模块。
            raw = zstd.decompress(raw)
        except ImportError:
            import zstandard
            raw = zstandard.ZstdDecompressor().decompress(raw)
    records = []
    partial = 0
    lines = raw.splitlines(keepends=True)
    for i, line in enumerate(lines):
        try:
            records.append(json.loads(line))
        except (json.JSONDecodeError, UnicodeDecodeError):
            # 只允许活动文件最后一行尚未写完；中间坏行不能悄悄跳过。
            if i == len(lines) - 1 and not line.endswith(b'\n'):
                partial = len(line)
            else:
                raise
    return records, len(raw), partial


def filter_records(records):
    """事件是界面可见消息的依据；响应记录用于原生 Codex 上下文重建。

    同一文本会在 response_item 与 item_completed 中各出现一次。两种都保留，
    但查阅工具只读界面事件，因此不会把一条对话显示两遍。
    """
    visible = {'user': set(), 'assistant': set()}
    available_outputs = set()
    available_calls = set()
    for record in records:
        p = record.get('payload', {})
        if record.get('type') == 'event_msg' and p.get('type') == 'item_completed':
            item = p.get('item', {})
            role = {'UserMessage': 'user', 'AgentMessage': 'assistant'}.get(item.get('type'))
            if role:
                visible[role].add(plain(item.get('content')))
        if record.get('type') == 'response_item' and p.get('type') in OUTPUT_TYPES:
            available_outputs.add(p.get('call_id'))
        if record.get('type') == 'response_item' and p.get('type') in CALL_TYPES:
            available_calls.add(p.get('call_id'))
    complete_calls = (available_calls & available_outputs) - {None}
    kept, dropped, redacted, messages = [], Counter(), Counter(), Counter()
    for record in records:
        p = record.get('payload', {})
        outer, inner = record.get('type'), p.get('type')
        keep = False
        if outer == 'session_meta':
            record = {**record, 'payload': {k: v for k, v in p.items() if k in META_KEYS}}
            # 分页历史依赖本机投影库。迁移副本使用已实测的 legacy 读取路径，
            # 由下面补充的可见消息事件恢复 UI；源会话完全不改。
            record['payload']['history_mode'] = 'legacy'
            keep = True
        elif outer == 'response_item':
            if inner == 'message':
                role = p.get('role')
                keep = role in visible and plain(p.get('content')) in visible[role]
                keep = keep and p.get('channel') not in {'analysis', 'justify', 'confidence'}
            elif inner in CALL_TYPES | OUTPUT_TYPES:
                # 活动快照不保留尚未返回的孤立调用，避免迁移后等待不存在的调用。
                keep = p.get('call_id') in complete_calls
        elif outer == 'event_msg':
            if inner in {'task_started', 'task_complete', 'turn_aborted'}:
                keep = True
            elif inner == 'item_completed':
                item = p.get('item', {})
                keep = item.get('type') in ITEM_TYPES
                if keep and item.get('type') in {'UserMessage', 'AgentMessage'}:
                    if item.get('phase') == 'analysis':
                        keep = False
                    else:
                        messages[item['type']] += 1
        if keep:
            kept.append(scrub(record, redacted))
            if outer == 'event_msg' and inner == 'item_completed':
                item = p.get('item', {})
                if item.get('type') == 'UserMessage':
                    event = {'type': 'user_message', 'message': plain(item.get('content')),
                             'images': [], 'local_images': [], 'text_elements': []}
                elif item.get('type') == 'AgentMessage':
                    event = {'type': 'agent_message', 'message': plain(item.get('content')),
                             'phase': item.get('phase')}
                else:
                    event = None
                if event:
                    kept.append(scrub({'timestamp': record.get('timestamp'), 'type': 'event_msg',
                                       'payload': event}, redacted))
        else:
            dropped[str(outer) + '/' + str(inner)] += 1
    encoded = ''.join(json.dumps(r, ensure_ascii=False, separators=(',', ':')) + '\n' for r in kept).encode('utf-8')
    return encoded, {'input_records': len(records), 'exported_records': len(kept),
                     'visible_messages': dict(messages), 'omitted_record_counts': dict(dropped),
                     'credential_redactions': {k: v for k, v in redacted.items() if v}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex-home', type=Path, default=Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))))
    parser.add_argument('--project-root', type=Path, default=REPO)
    args = parser.parse_args()
    codex_root = args.codex_home.resolve()
    # URI 的 mode=ro 保证源线程库只读。只查询项目主会话，不包含子代理/其它项目。
    db = sqlite3.connect((codex_root / 'state_5.sqlite').as_uri() + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    rows = db.execute('SELECT id,title,cwd,rollout_path,updated_at,created_at,cli_version FROM threads WHERE agent_path IS NULL ORDER BY created_at').fetchall()
    normalized = lambda s: str(s).removeprefix('\\\\?\\').replace('\\', '/').rstrip('/').casefold()
    rows = [dict(row) for row in rows if normalized(row['cwd']) == normalized(args.project_root.resolve())]
    db.close()
    if not rows:
        raise SystemExit('没有找到本项目的主会话，未生成空包。')
    now = datetime.now(timezone.utc).isoformat()
    manifest = {'schema_version': 1, 'exported_at': now, 'project': '8xianren/CUDA_DX',
                'source_project_root': str(args.project_root.resolve()),
                'scope': 'project_main_threads_only',
                'format': 'sanitized_native_codex_rollout_jsonl',
                'compatibility_conversion': 'legacy history_mode with visible user_message/agent_message events',
                'not_a_byte_identical_backup': True,
                'sessions': []}
    archive = PACKAGE / 'conversations.zip'
    temporary = PACKAGE / 'conversations.building.zip'
    with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for row in rows:
            path = Path(row['rollout_path'].removeprefix('\\\\?\\'))
            if not path.exists() and Path(str(path) + '.zst').exists():
                path = Path(str(path) + '.zst')
            if not path.exists():
                raise FileNotFoundError('项目会话文件缺失：' + row['id'])
            records, source_bytes, partial = read_snapshot(path)
            payload, audit = filter_records(records)
            relative = path.relative_to(codex_root).as_posix().removesuffix('.zst')
            if not relative.startswith('sessions/'):
                # 归档会话在目标机作为可查询历史恢复，时间与ID保持不变。
                timestamp = records[0]['payload']['timestamp'][:10].replace('-', '/')
                relative = 'sessions/' + timestamp + '/' + path.name.removesuffix('.zst')
            bundle.writestr(relative, payload)
            manifest['sessions'].append({'id': row['id'], 'title': row['title'], 'kind': 'main',
                'archive_path': relative, 'sha256': sha(payload), 'bytes': len(payload),
                'created_at': datetime.fromtimestamp(row['created_at'], timezone.utc).isoformat(),
                'updated_at': datetime.fromtimestamp(row['updated_at'], timezone.utc).isoformat(),
                'source_cli_version': row['cli_version'], 'source_decoded_bytes': source_bytes,
                'source_was_compressed': path.suffix == '.zst', 'partial_tail_bytes_skipped': partial,
                **audit})
    temporary.replace(archive)
    manifest['archive'] = {'path': archive.name, 'sha256': sha(archive.read_bytes()), 'bytes': archive.stat().st_size}
    (PACKAGE / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'threads': len(rows), 'archive_bytes': archive.stat().st_size,
                      'messages': sum(sum(s['visible_messages'].values()) for s in manifest['sessions']),
                      'credential_redactions': [s['credential_redactions'] for s in manifest['sessions']]}, ensure_ascii=False))


if __name__ == '__main__':
    main()
