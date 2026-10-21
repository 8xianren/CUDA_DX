"""从迁移包查阅用户可见对话，不启动 Codex、不调用模型、不执行历史命令。

先校验整个包，再按 item_completed 中的 UserMessage/AgentMessage 提取文字。
兼容事件在原生恢复时使用，本工具不重复读取它们。序号在单会话内从 1 开始。
"""
import argparse
import json
from pathlib import Path

from restore import verify_bundle

PACKAGE = Path(__file__).resolve().parents[1]


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return '\n'.join(filter(None, (text_of(part) for part in content)))
    if isinstance(content, dict):
        return content.get('text', '')
    return ''


def visible_messages(data):
    for line in data.splitlines():
        record = json.loads(line)
        payload = record.get('payload', {})
        if record.get('type') != 'event_msg' or payload.get('type') != 'item_completed':
            continue
        item = payload.get('item', {})
        if item.get('type') not in {'UserMessage', 'AgentMessage'}:
            continue
        yield {'timestamp': record.get('timestamp'),
               'role': 'user' if item['type'] == 'UserMessage' else 'assistant',
               'phase': item.get('phase'), 'text': text_of(item.get('content'))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, default=PACKAGE)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('list', help='列出会话标题、ID和消息数')
    show = sub.add_parser('show', help='按消息序号或末尾条数读取')
    show.add_argument('--thread', required=True, help='完整ID或列表中的1开始序号')
    show.add_argument('--start', type=int, default=1)
    show.add_argument('--limit', type=int, default=20)
    show.add_argument('--tail', type=int)
    show.add_argument('--json', action='store_true', help='输出便于另一台Codex读取的逐条JSON')
    search = sub.add_parser('search', help='在可见对话中搜索文字，大小写不敏感')
    search.add_argument('query')
    search.add_argument('--limit', type=int, default=20)
    args = parser.parse_args()
    manifest, contents = verify_bundle(args.package)
    sessions = manifest['sessions']
    if args.command == 'list':
        for i, session in enumerate(sessions, 1):
            count = sum(1 for _ in visible_messages(contents[session['archive_path']]))
            print(f"{i}. {session['title']}\n   ID: {session['id']} | messages: {count}")
        return
    if args.command == 'show':
        candidates = [s for i, s in enumerate(sessions, 1) if args.thread in {str(i), s['id']}]
        if len(candidates) != 1:
            parser.error('会话不存在；先运行 list。')
        if args.start < 1 or args.limit < 1 or (args.tail is not None and args.tail < 1):
            parser.error('start/limit/tail 必须为正数。')
        session = candidates[0]
        messages = list(visible_messages(contents[session['archive_path']]))
        begin = max(0, len(messages) - args.tail) if args.tail is not None else args.start - 1
        end = len(messages) if args.tail is not None else begin + args.limit
        for i in range(begin, min(end, len(messages))):
            message = {'index': i + 1, **messages[i]}
            if args.json:
                print(json.dumps(message, ensure_ascii=False))
            else:
                print(f"\n[{i + 1}] {message['role']} {message['timestamp']}\n{message['text']}")
        return
    count = 0
    for session in sessions:
        for i, message in enumerate(visible_messages(contents[session['archive_path']]), 1):
            at = message['text'].casefold().find(args.query.casefold())
            if at < 0:
                continue
            excerpt = message['text'][max(0, at - 90):at + len(args.query) + 160].replace('\n', ' ')
            print(f"{session['id']} #{i} {message['role']}: {excerpt}")
            count += 1
            if count >= args.limit:
                return


if __name__ == '__main__':
    main()
