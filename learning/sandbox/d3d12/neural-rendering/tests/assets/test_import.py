"""G.9 独立格式测试：用精确已知系数构造输入，不依赖大资产恰巧能被读取。"""
from pathlib import Path
import contextlib
import hashlib
import importlib.util
import io
import json
import struct
import tempfile
import unittest
from unittest import mock
import numpy as np

ROOT = Path(__file__).resolve().parents[2]


def load_module(name):
    specification = importlib.util.spec_from_file_location(name, ROOT / "python/assets" / (name + ".py"))
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


converter = load_module("convert_ply")
fetcher = load_module("fetch_reference")


def properties(degree):
    # 故意不复用导入器的属性生成代码：独立声明GraphDeco字段布局。
    return (["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2"]
            + ["f_rest_" + str(i) for i in range(3 * ((degree + 1) ** 2 - 1))]
            + ["opacity", "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"])


def make_ply(path, degree=0, names=None, edits=None, suffix=b"", truncate=0):
    names = properties(degree) if names is None else names
    rows = []
    for index in range(2):
        values = {name: 0.0 for name in names}
        values.update(x=1.25 + index, y=-2.5, z=.75, f_dc_0=.1, f_dc_1=.2, f_dc_2=.3,
                      opacity=0 if index == 0 else 2, scale_0=np.log(.5), scale_1=np.log(2),
                      scale_2=np.log(3), rot_0=2, rot_1=0, rot_2=0, rot_3=0)
        for i in range(3 * ((degree + 1) ** 2 - 1)):
            values["f_rest_" + str(i)] = i + .125 + index * 100
        values.update(edits or {})
        rows.append([values.get(name, 0.0) for name in names])
    header = "ply\nformat binary_little_endian 1.0\nelement vertex 2\n"
    header += "".join("property float " + name + "\n" for name in names) + "end_header\n"
    payload = np.asarray(rows, dtype="<f4").tobytes()
    if truncate:
        payload = payload[:-truncate]
    path.write_bytes(header.encode("ascii") + payload + suffix)
    return path


class PlyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="cuda_dx_g9_test_")
        self.root = Path(self.directory.name)
        self.patch_root = mock.patch.object(converter, "ROOT", self.root)
        self.patch_root.start()

    def tearDown(self):
        self.patch_root.stop()
        self.directory.cleanup()

    def convert(self, degree=0, **options):
        source = make_ply(self.root / "input.ply", degree, **options)
        destination = self.root / "output.gsbin"
        with contextlib.redirect_stdout(io.StringIO()):
            converter.convert(source, destination)
        return destination

    def test_degree0_wire_header_and_numeric_decode(self):
        path = self.convert()
        data = path.read_bytes()
        self.assertEqual(struct.unpack("<8s4I", data[:24]), (b"GSBIN001", 2, 244, 0, 0))
        self.assertEqual(len(data), 24 + 2 * 244)
        first = struct.unpack("<59f2I", data[24:24 + 244])
        np.testing.assert_allclose(first[:3], [1.25, -2.5, .75])
        np.testing.assert_allclose(first[3:6], [.5, 2, 3], rtol=1e-6)
        np.testing.assert_array_equal(first[6:10], [1, 0, 0, 0])
        self.assertEqual(first[10], .5)
        np.testing.assert_allclose(first[11:14], [.1, .2, .3])
        self.assertTrue(all(value == 0 for value in first[14:59]))
        self.assertEqual(first[59:], (0, 0))
        second = struct.unpack("<59f2I", data[24 + 244:])
        self.assertAlmostEqual(second[10], 1 / (1 + np.exp(-2)), places=7)
        self.assertEqual(second[59:], (1, 0))

    def test_degree3_channel_to_basis_transpose(self):
        path = self.convert(3)
        data = path.read_bytes()
        self.assertEqual(struct.unpack("<8s4I", data[:24]), (b"GSBIN001", 2, 244, 3, 0))
        for row in range(2):
            fields = struct.unpack("<59f2I", data[24 + row * 244:24 + (row + 1) * 244])
            sh = np.array(fields[11:59]).reshape(16, 3)
            np.testing.assert_allclose(sh[0], [.1, .2, .3])
            for basis in range(1, 16):
                expected = [basis - 1 + channel * 15 + .125 + row * 100 for channel in range(3)]
                np.testing.assert_array_equal(sh[basis], expected)
            self.assertEqual(fields[59:], (row, 3))

    def test_reordered_properties_resolve_by_name(self):
        path = self.convert(3, names=list(reversed(properties(3))))
        first = struct.unpack("<59f2I", path.read_bytes()[24:268])
        self.assertEqual(first[0], 1.25)
        self.assertEqual(first[14:17], (.125, 15.125, 30.125))

    def test_missing_property(self):
        with self.assertRaisesRegex(ValueError, "missing=.*scale_2"):
            self.convert(names=[p for p in properties(0) if p != "scale_2"])

    def test_unknown_property(self):
        with self.assertRaisesRegex(ValueError, "unknown=.*mystery"):
            self.convert(names=properties(0) + ["mystery"])

    def test_wrong_sh_count(self):
        with self.assertRaisesRegex(ValueError, "SH rest count"):
            self.convert(names=properties(0) + ["f_rest_0"])

    def test_noncontiguous_sh_indices(self):
        names = ["f_rest_99" if p == "f_rest_8" else p for p in properties(1)]
        with self.assertRaisesRegex(ValueError, "property mismatch"):
            self.convert(1, names=names)

    def test_nan_parameter(self):
        with self.assertRaisesRegex(ValueError, "nonfinite"):
            self.convert(edits={"x": float("nan")})

    def test_infinite_parameter(self):
        with self.assertRaisesRegex(ValueError, "nonfinite"):
            self.convert(edits={"f_dc_1": float("inf")})

    def test_zero_quaternion(self):
        with self.assertRaisesRegex(ValueError, "quaternion"):
            self.convert(edits={"rot_0": 0})

    def test_short_payload(self):
        with self.assertRaisesRegex(ValueError, "truncated payload"):
            self.convert(truncate=1)

    def test_extra_payload(self):
        with self.assertRaisesRegex(ValueError, "unexpected trailing bytes"):
            self.convert(suffix=b"x")

    def test_duplicate_property(self):
        with self.assertRaisesRegex(ValueError, "duplicate property x"):
            self.convert(names=properties(0) + ["x"])

    def test_unrepresentable_float32_scale(self):
        with np.errstate(over="ignore"):
            with self.assertRaisesRegex(ValueError, "float32 runtime scale"):
                self.convert(edits={"scale_0": 100})

    def test_float32_scale_underflow(self):
        with self.assertRaisesRegex(ValueError, "float32 runtime scale"):
            self.convert(edits={"scale_0": -200})


class FetchTests(unittest.TestCase):
    """无网络测试下载的SHA校验与原子替换，不接受不完整文件。"""
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="cuda_dx_g9_download_")
        self.root = Path(self.directory.name)
        self.payload = b"known reference fixture bytes"
        self.sha = hashlib.sha256(self.payload).hexdigest()
        self.revision = getattr(fetcher, "REVISION", "1" * 40)
        self.metadata = {"sha": self.revision, "cardData": {"license": "fixture"}}
        self.entries = [{"path": fetcher.FILE, "lfs": {"oid": self.sha}}]
        self.root_patch = mock.patch.object(fetcher, "ROOT", self.root)
        self.root_patch.start()
        self.sha_patch = mock.patch.object(fetcher, "EXPECTED_SHA256", self.sha)
        self.sha_patch.start()

    def tearDown(self):
        self.sha_patch.stop()
        self.root_patch.stop()
        self.directory.cleanup()

    def run_fetch(self, response):
        with mock.patch.object(fetcher, "get_json", side_effect=[self.metadata, self.entries]):
            with mock.patch.object(fetcher.urllib.request, "urlopen", return_value=response) as request:
                with contextlib.redirect_stdout(io.StringIO()):
                    fetcher.main()
                return request

    def test_verified_download_and_provenance(self):
        request = self.run_fetch(io.BytesIO(self.payload))
        target = self.root / "downloads/reference/train-7000.ply"
        self.assertEqual(target.read_bytes(), self.payload)
        self.assertFalse(target.with_suffix(".partial").exists())
        provenance = json.loads((self.root / "results/g9/provenance.json").read_text(encoding="utf-8"))
        self.assertEqual(provenance["sha256"], self.sha)
        self.assertIn("/resolve/" + self.revision + "/", request.call_args[0][0])

    def test_hash_mismatch_never_creates_valid_asset(self):
        with self.assertRaisesRegex(RuntimeError, "SHA256 mismatch"):
            self.run_fetch(io.BytesIO(b"wrong data"))
        self.assertFalse((self.root / "downloads/reference/train-7000.ply").exists())

    def test_latest_revision_does_not_replace_pinned_revision(self):
        self.metadata["sha"] = "9" * 40
        request = self.run_fetch(io.BytesIO(self.payload))
        self.assertIn("/resolve/" + self.revision + "/", request.call_args[0][0])

    def test_changed_lfs_metadata_rejected_before_download(self):
        self.entries[0]["lfs"]["oid"] = "0" * 64
        with self.assertRaisesRegex(RuntimeError, "pinned reference LFS metadata changed"):
            self.run_fetch(io.BytesIO(self.payload))
        self.assertFalse((self.root / "downloads/reference/train-7000.ply").exists())

    def test_existing_verified_asset_skips_download(self):
        target = self.root / "downloads/reference/train-7000.ply"
        target.parent.mkdir(parents=True)
        target.write_bytes(self.payload)
        request = self.run_fetch(io.BytesIO(b"should not read"))
        request.assert_not_called()
        self.assertEqual(target.read_bytes(), self.payload)

    def test_network_failure_keeps_existing_file(self):
        target = self.root / "downloads/reference/train-7000.ply"
        target.parent.mkdir(parents=True)
        target.write_bytes(b"old asset")
        class Interrupted(io.BytesIO):
            def read(self, size=-1):
                if self.tell() > 0:
                    raise OSError("simulated network interruption")
                return super().read(5)
        with self.assertRaisesRegex(OSError, "network interruption"):
            self.run_fetch(Interrupted(self.payload))
        self.assertEqual(target.read_bytes(), b"old asset")
        self.assertEqual(target.with_suffix(".partial").read_bytes(), self.payload[:5])


if __name__ == "__main__":
    suite = unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(PlyTests),
                                unittest.defaultTestLoader.loadTestsFromTestCase(FetchTests)])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    report = {"status": "PASS" if result.wasSuccessful() else "FAIL", "tests": result.testsRun,
              "failures": len(result.failures), "errors": len(result.errors),
              "scope": "synthetic degree0/3 wire layout + malformed PLY + download integrity; no network"}
    destination = ROOT / "results/g9/import-tests.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2), encoding="utf-8")
    raise SystemExit(0 if result.wasSuccessful() else 1)
