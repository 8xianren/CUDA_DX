"""恢复工具回归：全部使用 tempfile，绝不读取或修改真实 CODEX_HOME。"""
import copy
import json
from pathlib import Path
import tempfile
import unittest
import uuid
import zipfile

import restore


class RestoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codex-restore-test-")
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        self.bundle.mkdir()
        self.home = self.root / "home"
        self.sid = str(uuid.uuid4())
        self.member = f"sessions/2026/10/21/rollout-2026-10-21T01-00-00-{self.sid}.jsonl"
        self.rows = [
            {"timestamp": "2026-10-21T01:00:00Z", "type": "session_meta",
             "payload": {"id": self.sid, "cwd": "C:\\old\\project", "history_mode": "legacy"}},
            {"timestamp": "2026-10-21T01:00:01Z", "type": "turn_context",
             "payload": {"cwd": "C:\\old\\project"}},
            {"timestamp": "2026-10-21T01:00:02Z", "type": "response_item",
             "payload": {"type": "message", "role": "user", "content": [
                 {"type": "input_text", "text": "原文路径 C:\\old\\project 必须保留"}]}}
        ]
        self.data = ("\n".join(json.dumps(r, ensure_ascii=False) for r in self.rows) + "\n").encode("utf-8")
        self.write_bundle()

    def tearDown(self):
        self.temp.cleanup()

    def write_bundle(self, *, member=None, data=None, extra=None):
        member = member or self.member
        data = self.data if data is None else data
        with zipfile.ZipFile(self.bundle / "conversations.zip", "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(member, data)
            if extra:
                archive.writestr(extra, "extra")
        manifest = {"schema_version": 1,
                    "archive": {"path": "conversations.zip", "sha256": restore.sha256((self.bundle / "conversations.zip").read_bytes())},
                    "sessions": [{"id": self.sid, "title": "迁移测试", "updated_at": "2026-10-21T01:00:00Z",
                                  "archive_path": member, "bytes": len(data), "sha256": restore.sha256(data), "kind": "main"}]}
        (self.bundle / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
        return manifest

    def test_verify_and_dry_run_do_not_create_target(self):
        manifest, members = restore.verify_bundle(self.bundle)
        self.assertEqual(members[self.member], self.data)
        report = restore.restore_bundle(self.bundle, self.home)
        self.assertEqual(report["planned"], [self.sid])
        self.assertFalse(self.home.exists())

    def test_apply_remaps_only_structured_cwd_and_is_idempotent(self):
        project = self.root / "new project"
        project.mkdir()
        report = restore.restore_bundle(self.bundle, self.home, apply=True, project_root=str(project))
        self.assertEqual(report["restored"], [self.sid])
        rows = restore.parse_rollout((self.home / self.member).read_bytes(), "restored")
        self.assertEqual(rows[0]["payload"]["cwd"], str(project.resolve()))
        self.assertEqual(rows[1]["payload"]["cwd"], str(project.resolve()))
        self.assertEqual(rows[2], self.rows[2])
        index_bytes = (self.home / "session_index.jsonl").read_bytes()
        report2 = restore.restore_bundle(self.bundle, self.home, apply=True)
        self.assertEqual(report2["restored"], [])
        self.assertEqual(len(report2["skipped"]), 1)
        self.assertEqual(index_bytes, (self.home / "session_index.jsonl").read_bytes())

    def test_same_id_other_path_is_conflict_even_without_index(self):
        alternative = self.home / "archived_sessions" / "old.jsonl"
        alternative.parent.mkdir(parents=True)
        alternative.write_bytes(self.data)
        with self.assertRaises(restore.MigrationError):
            restore.restore_bundle(self.bundle, self.home, apply=True, conflict="error")
        self.assertFalse((self.home / self.member).exists())
        self.assertEqual(alternative.read_bytes(), self.data)

    def test_existing_index_is_preserved_and_only_new_id_appended(self):
        self.home.mkdir()
        old = json.dumps({"id": str(uuid.uuid4()), "thread_name": "已有会话", "custom": "保留"}, ensure_ascii=False).encode("utf-8")
        index = self.home / "session_index.jsonl"
        index.write_bytes(old)  # 刻意不带末尾换行，验证追加时不粘连 JSON。
        restore.restore_bundle(self.bundle, self.home, apply=True)
        merged = index.read_bytes()
        self.assertTrue(merged.startswith(old + b"\n"))
        self.assertEqual(len(merged.splitlines()), 2)

    def test_compressed_rollout_id_conflicts_without_index_or_decompression(self):
        # 无需有效 zstd 数据：冲突识别仅使用标准 rollout 文件名中的 UUID。
        compressed = self.home / "archived_sessions" / f"rollout-2026-10-21T01-00-00-{self.sid}.jsonl.zst"
        compressed.parent.mkdir(parents=True)
        compressed.write_bytes(b"compressed-content-must-not-be-read")
        report = restore.restore_bundle(self.bundle, self.home, apply=True)
        self.assertEqual(report["restored"], [])
        self.assertEqual(report["skipped"][0]["id"], self.sid)
        with self.assertRaises(restore.MigrationError):
            restore.restore_bundle(self.bundle, self.home, apply=True, conflict="error")
        self.assertFalse((self.home / self.member).exists())
        self.assertFalse((self.home / "session_index.jsonl").exists())
        self.assertEqual(compressed.read_bytes(), b"compressed-content-must-not-be-read")

    def test_corrupted_archive_hash_rejected_without_writes(self):
        with (self.bundle / "conversations.zip").open("ab") as stream:
            stream.write(b"corruption")
        with self.assertRaisesRegex(restore.MigrationError, "ZIP SHA-256"):
            restore.restore_bundle(self.bundle, self.home, apply=True)
        self.assertFalse(self.home.exists())

    def test_member_hash_rejected(self):
        manifest = json.loads((self.bundle / "manifest.json").read_text(encoding="utf-8"))
        manifest["sessions"][0]["sha256"] = "0" * 64
        (self.bundle / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaisesRegex(restore.MigrationError, "会话 SHA-256"):
            restore.verify_bundle(self.bundle)

    def test_traversal_and_windows_absolute_paths_rejected(self):
        for path in ["sessions/../../outside.jsonl", "/outside.jsonl", "C:/outside.jsonl",
                     "sessions\\..\\outside.jsonl", "sessions/CON.jsonl", "sessions/a. /x.jsonl"]:
            with self.subTest(path=path):
                self.write_bundle(member=path)
                with self.assertRaises(restore.MigrationError):
                    restore.restore_bundle(self.bundle, self.home, apply=True)
                self.assertFalse(self.home.exists())

    def test_extra_zip_payload_rejected(self):
        self.write_bundle(extra="../outside.txt")
        with self.assertRaises(restore.MigrationError):
            restore.verify_bundle(self.bundle)

    def test_invalid_json_and_wrong_session_id_rejected(self):
        self.write_bundle(data=self.data + b"not-json\n")
        with self.assertRaisesRegex(restore.MigrationError, "非法 JSON"):
            restore.verify_bundle(self.bundle)
        rows = copy.deepcopy(self.rows)
        rows[0]["payload"]["id"] = str(uuid.uuid4())
        self.write_bundle(data=("\n".join(json.dumps(r) for r in rows) + "\n").encode())
        with self.assertRaisesRegex(restore.MigrationError, "不一致"):
            restore.verify_bundle(self.bundle)

    def test_invalid_existing_index_stops_before_any_session_write(self):
        self.home.mkdir()
        (self.home / "session_index.jsonl").write_text("bad-json\n")
        with self.assertRaises(restore.MigrationError):
            restore.restore_bundle(self.bundle, self.home, apply=True)
        self.assertFalse((self.home / self.member).exists())

    def test_target_symlink_escape_rejected(self):
        self.home.mkdir()
        outside = self.root / "outside"
        outside.mkdir()
        try:
            (self.home / "sessions").symlink_to(outside, target_is_directory=True)
        except OSError:
            self.skipTest("当前 Windows 账号未启用创建符号链接权限")
        with self.assertRaises(restore.MigrationError):
            restore.restore_bundle(self.bundle, self.home, apply=True)
        self.assertEqual(list(outside.iterdir()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
