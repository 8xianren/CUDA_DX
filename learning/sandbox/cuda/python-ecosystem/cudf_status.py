"""检查当前 Python 环境是否具备 cuDF；不安装、不伪造 GPU 结果。"""

import importlib.util
import sys


print("Python:", sys.executable)
spec = importlib.util.find_spec("cudf")
if spec is None:
    print("cuDF: not installed")
    print("本机当前只做 API/安装路径说明，未声称 cuDF 真机运行结果。")
else:
    import cudf

    print("cuDF:", cudf.__version__)
    frame = cudf.DataFrame({"group": [0, 0, 1, 1], "value": [1, 2, 10, 20]})
    print(frame.groupby("group")["value"].sum())
