"""G.9：下载公开参考训练资产；原始数据留在 downloads，不加入学习仓库。

此集合的作者明确说明由 GraphDeco 原始方法训练。本课不声称亲自完成了这
7000 次训练。锁定 Hugging Face revision 与 LFS SHA256，防止同名文件替换。
"""
from pathlib import Path
import hashlib
import json
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
REPO = "pjramg/gaussian_splatting"
FILE = "FO_dataset/train/point_cloud/iteration_7000/point_cloud.ply"
REVISION = "6aaba1b1dd0439c0db464842f8a6600a37e0eae9"
EXPECTED_SHA256 = "9f5c643fa18cb5ed6a11441f073133ed1034e3b0656bce5b7b5db3db49161366"


def get_json(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return json.load(response)


def main():
    metadata = get_json(f"https://huggingface.co/api/datasets/{REPO}")
    revision = REVISION
    entries = get_json(f"https://huggingface.co/api/datasets/{REPO}/tree/{revision}?recursive=true")
    item = next(x for x in entries if x["path"] == FILE)
    expected = item["lfs"]["oid"]
    if expected != EXPECTED_SHA256:
        raise RuntimeError("pinned reference LFS metadata changed")
    target = ROOT / "downloads/reference/train-7000.ply"
    target.parent.mkdir(parents=True, exist_ok=True)
    url = f"https://huggingface.co/datasets/{REPO}/resolve/{revision}/{FILE}"
    if not target.exists() or hashlib.sha256(target.read_bytes()).hexdigest() != expected:
        # 网络中断只留下 .partial，不能让下次运行把半文件当有效资产。
        partial = target.with_suffix(".partial")
        with urllib.request.urlopen(url, timeout=120) as response, partial.open("wb") as out:
            while block := response.read(1024 * 1024):
                out.write(block)
        if hashlib.sha256(partial.read_bytes()).hexdigest() != expected:
            raise RuntimeError("reference asset SHA256 mismatch")
        partial.replace(target)
    report = {"repository": REPO, "revision": revision, "url": url,
              "sha256": expected, "bytes": target.stat().st_size,
              "training": "GraphDeco method, iteration 7000; dataset-author provenance",
              "trained_locally": False, "metadata_license": metadata.get("cardData", {}).get("license"),
              "source_card": f"https://huggingface.co/datasets/{REPO}/blob/{revision}/README.md"}
    out = ROOT / "results/g9"
    out.mkdir(parents=True, exist_ok=True)
    (out / "provenance.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
