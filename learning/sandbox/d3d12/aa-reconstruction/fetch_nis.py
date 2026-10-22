"""F.6: 恢复锁定版本的官方 NIS 源文件；只下载编译所需小文件，逐个核验 SHA-256。

用法：python learning/sandbox/d3d12/aa-reconstruction/fetch_nis.py
external/ 不进个人仓库，官方文件携带 MIT 版权声明；失败不会留下未核验的目标文件。
"""
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parent


def main():
    lock = json.loads((ROOT / "nis.lock.json").read_text(encoding="utf-8"))
    for record in lock["files"]:
        destination = ROOT / "external" / "nis" / record["path"]
        if destination.is_file() and hashlib.sha256(destination.read_bytes()).hexdigest() == record["sha256"]:
            print(f"verified {record['path']}")
            continue
        url = f"https://raw.githubusercontent.com/NVIDIAGameWorks/NVIDIAImageScaling/{lock['commit']}/{record['path']}"
        payload = urllib.request.urlopen(url, timeout=60).read()
        if hashlib.sha256(payload).hexdigest() != record["sha256"]:
            raise RuntimeError(f"SHA-256 mismatch: {record['path']}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(payload)
        print(f"downloaded and verified {record['path']}")


if __name__ == "__main__":
    main()
