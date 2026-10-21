#!/usr/bin/env python3
"""离线原生解析验收：在临时 CODEX_HOME 恢复包，用 app-server 读取全部对话。

只调用 initialize、thread/list、thread/read；不发送 turn/start，不登录，不调用模型。
临时环境不继承 API key，且从临时工作目录启动，避免读取用户项目配置。
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time

import restore


class LocalAppServer:
    def __init__(self, exe: Path, home: Path):
        env = os.environ.copy()
        env["CODEX_HOME"] = str(home)
        # 测试不需要认证。去掉常见 provider key，防止临时子进程继承凭据。
        for key in list(env):
            if key.upper().endswith(("API_KEY", "ACCESS_TOKEN", "AUTH_TOKEN")):
                env.pop(key)
        self.process = subprocess.Popen([str(exe), "app-server", "--stdio"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, encoding="utf-8",
                                        env=env, cwd=home)
        self.responses = queue.Queue()
        self.errors = []
        self.request_id = 0

        def read_stdout():
            for line in self.process.stdout:
                try:
                    self.responses.put(json.loads(line))
                except ValueError:
                    self.errors.append("app-server 输出非 JSON 行")

        def read_stderr():
            # 及时排空 stderr，避免子进程因管道塞满而阻塞；不输出潜在本机路径。
            for _ in self.process.stderr:
                pass

        threading.Thread(target=read_stdout, daemon=True).start()
        threading.Thread(target=read_stderr, daemon=True).start()

    def send(self, value):
        self.process.stdin.write(json.dumps(value) + "\n")
        self.process.stdin.flush()

    def rpc(self, method: str, params: dict, timeout: int = 55):
        self.request_id += 1
        current = self.request_id
        self.send({"id": current, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            try:
                message = self.responses.get(timeout=max(.01, deadline - time.monotonic()))
            except queue.Empty as exc:
                raise RuntimeError(f"app-server {method} 超时") from exc
            if message.get("id") != current:
                continue
            if "error" in message:
                raise RuntimeError(f"app-server {method}: {message['error']}")
            return message["result"]

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.process.stdin.close()
        self.process.stdout.close()
        self.process.stderr.close()


def expected_messages(data: bytes) -> Counter:
    messages = Counter()
    for row in restore.parse_rollout(data, "native check"):
        payload = row["payload"]
        if row["type"] != "event_msg":
            continue
        if payload.get("type") == "user_message":
            messages[("userMessage", payload["message"])] += 1
        elif payload.get("type") == "agent_message":
            messages[("agentMessage", payload["message"])] += 1
    return messages


def run(bundle: Path, executable: Path) -> dict:
    manifest, members = restore.verify_bundle(bundle)
    report = {"pass": True, "tool": "Codex app-server stdio", "methods": ["initialize", "thread/list", "thread/read"],
              "isolated_temp_home": True, "model_calls": 0, "sessions": []}
    with tempfile.TemporaryDirectory(prefix="codex-native-migration-") as directory:
        home = Path(directory)
        project = home / "project"
        project.mkdir()
        restored = restore.restore_bundle(bundle, home, apply=True, project_root=str(project))
        assert len(restored["restored"]) == len(manifest["sessions"])
        server = LocalAppServer(executable, home)
        try:
            init = server.rpc("initialize", {"clientInfo": {"name": "migration_native_check", "version": "1"},
                                             "capabilities": {"experimentalApi": True}})
            report["native_version"] = init.get("userAgent")
            server.send({"method": "initialized"})
            listed = server.rpc("thread/list", {"limit": 100, "useStateDbOnly": False})
            found = {thread["id"] for thread in listed["data"]}
            for session in manifest["sessions"]:
                thread = server.rpc("thread/read", {"threadId": session["id"], "includeTurns": True})["thread"]
                expected = expected_messages(members[session["archive_path"]])
                actual = Counter()
                for turn in thread["turns"]:
                    for item in turn["items"]:
                        if item["type"] == "userMessage":
                            text = "\n".join(part["text"] for part in item.get("content", []) if part.get("type") == "text")
                            actual[("userMessage", text)] += 1
                        elif item["type"] == "agentMessage":
                            actual[("agentMessage", item["text"])] += 1
                missing = expected - actual
                unexpected = actual - expected
                passed = (session["id"] in found and not missing and not unexpected and bool(expected)
                          and thread["cwd"] == str(project) and thread.get("name") == session["title"])
                entry = {"id": session["id"], "listed": session["id"] in found,
                         "title_matches": thread.get("name") == session["title"], "cwd_remapped": thread["cwd"] == str(project),
                         "turns": len(thread["turns"]), "expected_visible_messages": sum(expected.values()),
                         "native_visible_messages": sum(actual.values()),
                         "missing_messages": sum(missing.values()), "extra_messages": sum(unexpected.values()), "pass": passed}
                report["sessions"].append(entry)
                report["pass"] = report["pass"] and passed
        finally:
            server.close()
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", type=Path, required=True, help="明确指定本机 Codex 可执行文件")
    parser.add_argument("--bundle", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    report = run(args.bundle, args.codex.resolve())
    output = json.dumps(report, ensure_ascii=False, indent=2)
    if args.report:
        args.report.write_text(output + "\n", encoding="utf-8")
    print(output)
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
