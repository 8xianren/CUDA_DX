#!/usr/bin/env python3
"""校验并恢复迁移包；默认预览，只有 --apply 才会写入明确指定的目标。

本工具只使用 Python 标准库。不读取登录凭据、不复制 SQLite、不调用模型。
先完整检查 ZIP/JSONL/冲突，再以独占创建方式写会话，避免覆盖已有记录。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import uuid
import zipfile


class MigrationError(ValueError):
    """输入损坏、路径不安全或目标冲突；调用者可显示此错误而不继续写入。"""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _json(data: str | bytes, label: str):
    try:
        return json.loads(data)
    except (ValueError, UnicodeError) as exc:
        raise MigrationError(f"非法 JSON：{label}: {exc}") from exc


def _relative_path(value: str, *, session: bool = False) -> PurePosixPath:
    # ZIP 使用 POSIX 分隔符；同时拒绝 Windows 盘符、ADS、反斜杠和保留名。
    if not isinstance(value, str) or not value or "\\" in value or ":" in value:
        raise MigrationError(f"不安全的相对路径：{value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or any(p in ("", ".", "..") for p in value.split("/")):
        raise MigrationError(f"不安全的相对路径：{value!r}")
    for part in path.parts:
        if part.endswith((" ", ".")) or any(ord(c) < 32 for c in part):
            raise MigrationError(f"不安全的路径片段：{part!r}")
        if re.fullmatch(r"(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?", part):
            raise MigrationError(f"Windows 保留文件名：{part!r}")
    if session and (path.parts[0] != "sessions" or path.suffix != ".jsonl"):
        raise MigrationError(f"会话必须位于 sessions/ 并使用 .jsonl：{value}")
    return path


def _inside(root: Path, relative: str) -> Path:
    relative_path = _relative_path(relative)
    target = root.joinpath(*relative_path.parts)
    try:
        target.resolve().relative_to(root.resolve())
    except ValueError as exc:
        raise MigrationError(f"目标路径逃逸（可能含符号链接）：{relative}") from exc
    # 拒绝目标链中的符号链接/junction，即使当前指向目录内部也不使用它。
    cursor = target
    while cursor != root and cursor != cursor.parent:
        if cursor.is_symlink() or (hasattr(cursor, "is_junction") and cursor.is_junction()):
            raise MigrationError(f"目标包含链接：{cursor}")
        cursor = cursor.parent
    return target


def parse_rollout(data: bytes, label: str, expected_id: str | None = None) -> list[dict]:
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeError as exc:
        raise MigrationError(f"会话不是 UTF-8：{label}") from exc
    rows = []
    for number, line in enumerate(lines, 1):
        if not line.strip():
            raise MigrationError(f"JSONL 含空行：{label}:{number}")
        row = _json(line, f"{label}:{number}")
        if not isinstance(row, dict) or not isinstance(row.get("payload"), dict):
            raise MigrationError(f"JSONL 行缺少对象 payload：{label}:{number}")
        if not isinstance(row.get("timestamp"), str) or not isinstance(row.get("type"), str):
            raise MigrationError(f"JSONL 行缺少 type/timestamp：{label}:{number}")
        rows.append(row)
    if not rows or rows[0].get("type") != "session_meta":
        raise MigrationError(f"会话第一行必须是 session_meta：{label}")
    if sum(row["type"] == "session_meta" for row in rows) != 1:
        raise MigrationError(f"会话必须恰好有一个 session_meta：{label}")
    session_id = rows[0]["payload"].get("id")
    try:
        uuid.UUID(session_id)
    except (ValueError, TypeError, AttributeError) as exc:
        raise MigrationError(f"非法会话 UUID：{label}") from exc
    if expected_id is not None and session_id != expected_id:
        raise MigrationError(f"manifest 与 session_meta.id 不一致：{label}")
    return rows


def verify_bundle(bundle: Path) -> tuple[dict, dict[str, bytes]]:
    """返回 (manifest, 已验证的 ZIP 成员字节)，任何校验失败都不写目标目录。"""
    bundle = Path(bundle).resolve()
    manifest = _json((bundle / "manifest.json").read_bytes(), "manifest.json")
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1:
        raise MigrationError("仅支持 manifest schema_version=1")
    archive = manifest.get("archive")
    sessions = manifest.get("sessions")
    if not isinstance(archive, dict) or not isinstance(sessions, list) or not sessions:
        raise MigrationError("manifest 缺少 archive 或非空 sessions")
    archive_path = _inside(bundle, archive.get("path"))
    if archive_path.suffix != ".zip":
        raise MigrationError("archive.path 必须是 ZIP 文件")
    digest = hashlib.sha256()
    with archive_path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != archive.get("sha256"):
        raise MigrationError("ZIP SHA-256 校验失败")
    expected = {}
    seen_ids = set()
    seen_paths = set()
    for session in sessions:
        if not isinstance(session, dict):
            raise MigrationError("manifest.sessions 元素必须是对象")
        sid = session.get("id")
        try:
            uuid.UUID(sid)
        except (ValueError, TypeError, AttributeError) as exc:
            raise MigrationError("manifest 包含非法会话 UUID") from exc
        path = str(_relative_path(session.get("archive_path"), session=True))
        if sid in seen_ids or path.casefold() in seen_paths:
            raise MigrationError("manifest 包含重复会话 ID 或大小写冲突路径")
        if not isinstance(session.get("bytes"), int) or session["bytes"] <= 0:
            raise MigrationError(f"非法会话字节数：{path}")
        if not isinstance(session.get("title"), str) or not isinstance(session.get("updated_at"), str):
            raise MigrationError(f"会话缺少 title/updated_at：{path}")
        expected[path] = session
        seen_ids.add(sid)
        seen_paths.add(path.casefold())
    members = {}
    try:
        with zipfile.ZipFile(archive_path) as zip_stream:
            infos = zip_stream.infolist()
            # 防止重复条目、链接条目、路径穿越以及未列入 manifest 的额外载荷。
            if len(infos) != len(expected) or {i.filename for i in infos} != set(expected):
                raise MigrationError("ZIP 成员与 manifest 不一致（缺失、额外或重复条目）")
            total = 0
            for info in infos:
                _relative_path(info.filename, session=True)
                if info.is_dir() or stat.S_ISLNK(info.external_attr >> 16):
                    raise MigrationError(f"ZIP 不允许目录或链接条目：{info.filename}")
                total += info.file_size
                if info.file_size > 1024 ** 3 or total > 2 * 1024 ** 3:
                    raise MigrationError("解压大小超出迁移工具上限（单文件 1 GiB、总计 2 GiB）")
                session = expected[info.filename]
                if info.file_size != session["bytes"]:
                    raise MigrationError(f"会话字节数不一致：{info.filename}")
                data = zip_stream.read(info)
                if sha256(data) != session.get("sha256"):
                    raise MigrationError(f"会话 SHA-256 校验失败：{info.filename}")
                parse_rollout(data, info.filename, session["id"])
                members[info.filename] = data
    except zipfile.BadZipFile as exc:
        raise MigrationError(f"ZIP 损坏：{exc}") from exc
    return manifest, members


def remap_cwd(data: bytes, project_root: str | None) -> bytes:
    """只修改 session_meta/turn_context 的 cwd；不替换历史正文或工具命令。"""
    if project_root is None:
        return data
    rows = parse_rollout(data, "cwd remap")
    for row in rows:
        if row["type"] in ("session_meta", "turn_context") and "cwd" in row["payload"]:
            row["payload"]["cwd"] = project_root
    return ("\n".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) for row in rows) + "\n").encode("utf-8")


def existing_ids(home: Path) -> tuple[set[str], list[dict], bytes]:
    """从现有索引和 rollout 首行查冲突，也覆盖未进入索引的归档会话。"""
    ids: set[str] = set()
    entries = []
    index = _inside(home, "session_index.jsonl")
    old_index = index.read_bytes() if index.exists() else b""
    for number, line in enumerate(old_index.splitlines(), 1):
        if not line.strip():
            continue
        row = _json(line, f"目标 session_index.jsonl:{number}")
        if not isinstance(row, dict) or not isinstance(row.get("id"), str):
            raise MigrationError("目标索引格式无效；请先修复，工具不会重写它")
        entries.append(row)
        ids.add(row["id"])
    for directory in ("sessions", "archived_sessions"):
        root = _inside(home, directory)
        if not root.exists():
            continue
        # 不跟随链接，避免扫描目标 CODEX_HOME 之外的文件。
        for current, dirs, files in os.walk(root, followlinks=False):
            dirs[:] = [name for name in dirs if not Path(current, name).is_symlink()
                       and not (hasattr(Path(current, name), "is_junction") and Path(current, name).is_junction())]
            for name in files:
                path = Path(current, name)
                if path.is_symlink():
                    continue
                # Codex 可能将旧 rollout 压缩为 .jsonl.zst，且索引尚未列出它。
                # 冲突检查只需标准文件名末尾的 UUID，无需引入 zstd 或读取正文。
                compressed = re.fullmatch(
                    r"rollout-.+-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl\.zst",
                    name, re.IGNORECASE)
                if compressed:
                    ids.add(str(uuid.UUID(compressed.group(1))))
                    continue
                if path.suffix != ".jsonl":
                    continue
                with path.open("rb") as stream:
                    first = stream.readline(4 * 1024 * 1024)
                row = _json(first, f"目标会话首行 {path.name}")
                if isinstance(row, dict) and row.get("type") == "session_meta":
                    sid = row.get("payload", {}).get("id")
                    if isinstance(sid, str):
                        ids.add(sid)
    return ids, entries, old_index


def restore_bundle(bundle: Path, codex_home: Path, *, apply: bool = False,
                   project_root: str | None = None, conflict: str = "skip") -> dict:
    """预检查全部输入；apply=False 完全不创建目录或文件。"""
    manifest, members = verify_bundle(bundle)
    home = Path(codex_home).expanduser().absolute()
    if home.is_symlink() or (hasattr(home, "is_junction") and home.is_junction()):
        raise MigrationError("CODEX_HOME 不能是符号链接或 junction")
    home = home.resolve()
    if home.exists() and not home.is_dir():
        raise MigrationError("CODEX_HOME 必须是目录")
    if project_root is not None:
        project = Path(project_root).expanduser()
        if not project.is_absolute() or not project.is_dir():
            raise MigrationError("--project-root 必须是已经存在的绝对目录")
        project_root = str(project.resolve())
    if conflict not in ("skip", "error"):
        raise MigrationError("conflict 只能是 skip 或 error")
    ids, _, old_index = existing_ids(home)
    planned, skipped = [], []
    for session in manifest["sessions"]:
        target = _inside(home, session["archive_path"])
        if session["id"] in ids or target.exists():
            skipped.append({"id": session["id"], "reason": "目标已有相同 ID 或路径"})
            continue
        planned.append((session, target, remap_cwd(members[session["archive_path"]], project_root)))
    if skipped and conflict == "error":
        raise MigrationError(f"检测到 {len(skipped)} 个冲突，未写入任何文件")
    report = {"mode": "apply" if apply else "dry-run", "verified_sessions": len(members),
              "codex_home": str(home), "project_root": project_root,
              "planned": [s["id"] for s, _, _ in planned], "skipped": skipped,
              "restored": [], "index_entries_added": 0}
    if not apply or not planned:
        return report
    home.mkdir(parents=True, exist_ok=True)
    lock_path = _inside(home, ".codex-chat-migration.lock")
    try:
        lock = lock_path.open("x", encoding="utf-8")
    except FileExistsError as exc:
        raise MigrationError("发现迁移锁；先确认没有另一个恢复进程，再处理锁文件") from exc
    created = []
    try:
        with lock:
            lock.write(f"pid={os.getpid()}\n")
        # 不与正在运行的 Codex 争用索引；用户应先关闭 Codex。
        index = _inside(home, "session_index.jsonl")
        if (index.read_bytes() if index.exists() else b"") != old_index:
            raise MigrationError("预检查后索引发生变化；请关闭 Codex 后重试")
        for session, target, data in planned:
            _inside(home, session["archive_path"])
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("xb") as stream:
                created.append(target)
                stream.write(data)
        additions = b"".join((json.dumps({"id": session["id"], "thread_name": session["title"],
                                        "updated_at": session["updated_at"]}, ensure_ascii=False)
                               + "\n").encode("utf-8") for session, _, _ in planned)
        if old_index and not old_index.endswith(b"\n"):
            additions = b"\n" + additions
        # 保留已有索引字节，只在末尾添加新 ID。异常时新会话回滚；索引写入前再次检查。
        with index.open("a+b") as stream:
            stream.seek(0)
            if stream.read() != old_index:
                raise MigrationError("写入前索引发生变化；请关闭 Codex 后重试")
            stream.seek(0, os.SEEK_END)
            try:
                stream.write(additions)
                stream.flush()
                os.fsync(stream.fileno())
            except BaseException:
                stream.truncate(len(old_index))
                raise
        report["restored"] = [session["id"] for session, _, _ in planned]
        report["index_entries_added"] = len(planned)
    except BaseException:
        for path in created:
            path.unlink(missing_ok=True)
        raise
    finally:
        lock_path.unlink(missing_ok=True)
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=Path(__file__).resolve().parents[1], help="含 manifest.json 的包目录")
    parser.add_argument("--verify", action="store_true", help="只校验迁移包，不读取目标 CODEX_HOME")
    parser.add_argument("--codex-home", type=Path, help="明确指定目标 Codex 数据目录；不会自动读取环境变量")
    parser.add_argument("--project-root", help="新电脑上已经存在的项目绝对路径，只重映射结构化 cwd")
    parser.add_argument("--apply", action="store_true", help="实际恢复；使用前关闭目标电脑的 Codex")
    parser.add_argument("--conflict", choices=("skip", "error"), default="skip", help="相同 ID/路径冲突策略，永不覆盖")
    args = parser.parse_args(argv)
    if args.verify and (args.apply or args.codex_home or args.project_root):
        parser.error("--verify 不与恢复参数同时使用")
    if not args.verify and args.codex_home is None:
        parser.error("恢复预览也需要显式 --codex-home；只校验请使用 --verify")
    try:
        if args.verify:
            manifest, members = verify_bundle(args.bundle)
            report = {"mode": "verify", "verified_sessions": len(members),
                      "verified_bytes": sum(len(data) for data in members.values()),
                      "archive": manifest["archive"]["path"]}
        else:
            report = restore_bundle(args.bundle, args.codex_home, apply=args.apply,
                                    project_root=args.project_root, conflict=args.conflict)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0
    except (MigrationError, OSError, RuntimeError) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
