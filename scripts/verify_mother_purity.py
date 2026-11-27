"""母片纯净契约自检（对齐安卓 vc114 MotherPurityContractTest）。

安卓曾因全局相框档位泄漏进 buildParamsJson，把齿孔烤进母片像素，编辑页选
无框也去不掉。iOS C16 的架构是「母片永远无框 + Framed/ 独立后处理」，
C19 把这个约定从口头纪律升级为静态断言 + 运行时自检：

  静态（本脚本）：
    1. Framed 渲染只能写 framedDirectory()，不得写 developedDirectory()/printsBackupDirectory()
    2. masterPrintURL 只能从 developed/backup 读，不得从 framedDirectory() 读
    3. 运行时母片自检 auditMother() 必须存在且被调用
  运行时（RelicPrintRenderer.auditMother）：
    母片一旦带 frame_style/date_imprint 的 EXIF 字段，拒绝生成带框版并报错。

用法：python phaseC/verify_mother_purity.py
"""

from pathlib import Path
import re
import sys

def find_sources() -> Path:
    """本地 phaseC/Sources 与仓库 ios/Silverphase/Sources 都能跑。"""
    here = Path(__file__).resolve().parent
    for base in (here, *here.parents):
        for rel in ("Sources", "phaseC/Sources",
                    "ios/Silverphase/Sources", "sources"):
            cand = base / rel
            if (cand / "RelicPrintFrame.swift").exists():
                return cand
    raise SystemExit("找不到 RelicPrintFrame.swift，无法执行契约自检")


ROOT = find_sources()
print(f"源码目录: {ROOT}")
FRAME = (ROOT / "RelicPrintFrame.swift").read_text(encoding="utf-8")
DARKROOM = (ROOT / "RelicDarkroomView.swift").read_text(encoding="utf-8")

failures: list[str] = []


def check(cond: bool, msg: str) -> None:
    print(("  OK   " if cond else "  FAIL ") + msg)
    if not cond:
        failures.append(msg)


def body_of(src: str, signature: str) -> str:
    """取函数体（简单花括号计数，源码为 Swift，注释已不影响本检查）。"""
    start = src.find(signature)
    if start < 0:
        return ""
    brace = src.find("{", start)
    if brace < 0:
        return ""
    depth = 0
    for i in range(brace, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[brace:i + 1]
    return ""


print("母片纯净契约自检")
print("-" * 60)

# 1. Framed 渲染不得写母片目录
render = body_of(FRAME, "private static func render(job: RelicRenderJob)")
check(bool(render), "找到 RelicPrintRenderer.render(job:)")
if render:
    check("job.outPath" in render, "渲染目标使用 job.outPath（Framed 目录）")
    writes_master = re.search(
        r"(write|writeWithExif|copyItem|createFile|replaceItem).{0,120}masterPath", render
    )
    check(writes_master is None, "渲染过程没有写入 masterPath")

write_exif = body_of(FRAME, "private static func writeWithExif")
check(bool(write_exif) and "to: url" in (write_exif or ""),
      "EXIF 写入目标是传入的带框成片 URL")

# 2. masterPrintURL 只从母片目录读
master = body_of(DARKROOM, "static func masterPrintURL")
check(bool(master), "找到 RelicPaths.masterPrintURL")
if master:
    check("developedDirectory()" in master and "printsBackupDirectory()" in master,
          "masterPrintURL 只查 developed/backup 两个母片目录")
    check("framedDirectory()" not in master,
          "masterPrintURL 不会回读 Framed 目录（防止带框版被当母片）")

framed = body_of(DARKROOM, "static func printURL")
check(bool(framed) and "framedDirectory()" in (framed or ""),
      "展示入口 printURL 优先带框版")
check(bool(framed) and "masterPrintURL" in (framed or ""),
      "展示入口 printURL 缺失带框版时回退母片")

# 3. 运行时自检存在且被调用
check("static func auditMother(path: String) -> String?" in FRAME,
      "运行时母片自检 auditMother() 已定义")
check(FRAME.count("auditMother(path:") >= 3,
      "auditMother() 在 rebuild/render 多处被调用")
check("invalidateAll()" in FRAME and "RelicFrameFailures.clearAll()" in FRAME,
      "切档时清空 Framed 与失败记录，母片不受影响")

# 4. discard 只删展示/母片文件，不碰卷记录契约
discard = body_of(FRAME, "static func discard")
check(bool(discard) and "RelicPaths.framedDirectory()" in (discard or "")
      and "RelicPaths.developedDirectory()" in (discard or "")
      and "RelicPaths.printsBackupDirectory()" in (discard or ""),
      "单帧删除同时清理 Framed / Developed / Backup")

print("-" * 60)
if failures:
    print(f"FAILED: {len(failures)} 项契约被破坏")
    sys.exit(1)
print("PASSED: 母片纯净契约成立")
