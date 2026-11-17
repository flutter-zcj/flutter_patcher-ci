#!/usr/bin/env python3
"""归一化「命名构造函数名 == 同类实例成员名」的声明。

背景
----
flutter_patcher 1.1.1 的 extract-surface 会把这类命名构造函数当成实例成员写进
dynamic_interface，`baseline-kernel` 阶段用 --dynamic-interface 校验时报：
    Build failed: Expected instance member <Class>.<ctor>
已知触发类（Flutter 3.47.9）：
    FilteringTextInputFormatter.allow / LinearBorder.bottom|top|start|end
    InteractiveViewer.builder / Shortcuts.manager / CupertinoContextMenu.builder
    CupertinoTextSelectionToolbarButton.text|buttonItem / ConstColorUint8.data …
上游 issue #14 仍 open，iOS 只能 bytecode 策略，没有 --strategy so 的退路。

做法
----
把所有「ctor 名与实例成员同名」的命名构造函数改名为 from<Ctor>，并把目标树里
所有 `Class.ctor(` 调用点同步改名。只改构建副本（runner 上的 SDK / pub-cache /
工程快照），不动用户本地源码。

用法
----
  python3 normalize_named_ctors.py --project <app> --sdk <managed-sdk> \
      [--report out.json] [--dry-run]
"""

import argparse
import json
import os
import re
import sys

CLASS_RE = re.compile(r"^class\s+([A-Za-z_][A-Za-z0-9_]*)[^;{]*\{", re.M)
FIELD_RE = re.compile(
    r"^  (?:@override\s+)?(?:final|const|var|late)\s+[A-Za-z_][\w<>?,\s]*\s+([a-zA-Z_]\w*)\s*(?:=|;)",
    re.M,
)
GETTER_RE = re.compile(r"^  (?:@override\s+)?[A-Za-z_][\w<>?,\s]*\s+get\s+([a-zA-Z_]\w*)", re.M)
SETTER_RE = re.compile(r"^  (?:@override\s+)?set\s+([a-zA-Z_]\w*)\s*\(", re.M)
METHOD_RE = re.compile(
    r"^  (?:@override\s+)?[A-Za-z_][\w<>?,\s]*\s+([a-zA-Z_]\w*)\s*\([^;]*$", re.M
)


def class_body(text, brace_index):
    depth = 0
    for i in range(brace_index, len(text)):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[brace_index + 1 : i]
    return ""


def new_name(ctor):
    """data -> fromData；text -> fromText；已有 from 前缀则加 _2 避免重名。"""
    if ctor.startswith("_"):
        return "_from" + ctor[1:]
    cap = ctor[0].upper() + ctor[1:]
    return "from" + cap


def scan_file(path):
    try:
        src = open(path, encoding="utf-8", errors="replace").read()
    except Exception:
        return []
    hits = []
    for m in CLASS_RE.finditer(src):
        cls = m.group(1)
        body = class_body(src, m.end() - 1)
        if not body:
            continue
        members = set()
        for regex in (FIELD_RE, GETTER_RE, SETTER_RE, METHOD_RE):
            members.update(regex.findall(body))
        ctors = re.findall(
            r"^  (?:const\s+|factory\s+)?" + re.escape(cls) + r"\.([A-Za-z_]\w*)\s*\(",
            body,
            re.M,
        )
        for ctor in sorted(set(ctors) & members):
            hits.append((cls, ctor))
    return hits


def hosted_libs(cache):
    """pub-cache 目录下的所有包 lib（hosted/*/* 结构）。"""
    out = []
    hosted = os.path.join(cache, "hosted")
    if not os.path.isdir(hosted):
        return out
    for server in sorted(os.listdir(hosted)):
        server_dir = os.path.join(hosted, server)
        if not os.path.isdir(server_dir):
            continue
        for pkg in sorted(os.listdir(server_dir)):
            lib = os.path.join(server_dir, pkg, "lib")
            if os.path.isdir(lib):
                out.append(lib)
    return out


def tree_roots(project, sdk, pub_cache):
    """返回要扫描/改写的 lib 目录列表。"""
    libs = [os.path.join(project, "lib")]
    if pub_cache:
        libs.extend(hosted_libs(pub_cache))

    cfg = os.path.join(project, ".dart_tool/package_config.json")
    if os.path.exists(cfg):
        data = json.load(open(cfg))
        base = os.path.join(project, ".dart_tool")
        for pkg in data.get("packages", []):
            uri = pkg.get("rootUri", "")
            if uri.startswith("file://"):
                root = uri[len("file://") :]
            elif uri.startswith("..") or uri.startswith("./"):
                root = os.path.normpath(os.path.join(base, uri))
            else:
                continue
            lib = os.path.join(root, "lib")
            if os.path.isdir(lib):
                libs.append(lib)

    if sdk:
        packages = os.path.join(sdk, "packages")
        if os.path.isdir(packages):
            for name in sorted(os.listdir(packages)):
                lib = os.path.join(packages, name, "lib")
                if os.path.isdir(lib):
                    libs.append(lib)
        sky = os.path.join(sdk, "bin/cache/pkg/sky_engine/lib")
        if os.path.isdir(sky):
            libs.append(sky)

    seen, unique = set(), []
    for lib in libs:
        real = os.path.realpath(lib)
        if real in seen:
            continue
        seen.add(real)
        unique.append(lib)
    return unique


def dart_files(roots):
    for lib in roots:
        for dirpath, _, files in os.walk(lib):
            for name in files:
                if name.endswith(".dart"):
                    yield os.path.join(dirpath, name)


def class_body_span(text, brace):
    """brace 指向类体 '{'，返回 (body, 结尾 '}' 的下标)。"""
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1:i], i
    return "", brace


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True, help="Flutter 工程根目录")
    ap.add_argument("--sdk", default="", help="flutter_patcher managed SDK 根目录")
    ap.add_argument("--pub-cache", default="", help="额外的 pub-cache 目录（patcher 自带的 .flutter_patcher/pub-cache）")
    ap.add_argument("--report", default="", help="把结果写成 JSON")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    roots = tree_roots(os.path.abspath(args.project), args.sdk, args.pub_cache)
    print(f"扫描 {len(roots)} 个 lib 目录")

    found = {}
    files = 0
    for path in dart_files(roots):
        files += 1
        for cls, ctor in scan_file(path):
            found.setdefault((cls, ctor), []).append(path)

    print(f"扫描 {files} 个 dart 文件，命中 {len(found)} 处冲突：")
    for (cls, ctor), paths in sorted(found.items()):
        print(f"  {cls}.{ctor}  x{len(paths)}  ({paths[0]})")

    if not found:
        print("没有需要改名的构造函数")
        if args.report:
            json.dump({"collisions": [], "files_scanned": files}, open(args.report, "w"))
        return

    if args.dry_run:
        return

    renames = []
    for (cls, ctor) in sorted(found):
        renames.append((cls, ctor, new_name(ctor)))

    # 每个文件要处理三类位置：
    #   1) 声明本身          —— Class.ctor(   （也覆盖 factory 重定向、tear-off）
    #   2) 外部调用点        —— Class.ctor(
    #   3) 子类里的超类调用  —— super.ctor(   （漏了这处就会出现
    #      "Superclass has no constructor named 'ConstColorUint8.data'"）
    call_patterns = [
        (cls, ctor, nn, re.compile(r"\b" + re.escape(cls) + r"\." + re.escape(ctor) + r"\b"))
        for (cls, ctor, nn) in renames
    ]
    ctor_map = {cls: {} for cls in {c for (c, _, _) in renames}}
    for cls, ctor, nn in renames:
        ctor_map[cls][ctor] = nn

    total_edits = 0
    for path in dart_files(roots):
        try:
            src = open(path, encoding="utf-8", errors="replace").read()
        except Exception:
            continue
        new = src

        # (1)(2) Class.ctor 的声明与调用
        for cls, ctor, nn, pattern in call_patterns:
            new = pattern.sub(lambda m, _cls=cls, _nn=nn: f"{_cls}.{_nn}", new)

        # (3) 子类里的 super.ctor(
        for m in re.finditer(r"^class\s+[A-Za-z_]\w*[^{;]*?\bextends\s+([\w.]+)", new, re.M):
            sup = m.group(1).split(".")[-1]
            pairs = ctor_map.get(sup)
            if not pairs:
                continue
            brace = new.find("{", m.end())
            if brace < 0:
                continue
            body, end = class_body_span(new, brace)
            if not body:
                continue
            replaced = body
            for ctor, nn in pairs.items():
                replaced = re.sub(
                    r"\bsuper\." + re.escape(ctor) + r"\b",
                    f"super.{nn}",
                    replaced,
                )
            if replaced != body:
                new = new[:brace + 1] + replaced + new[end:]

        if new != src:
            if not args.dry_run:
                open(path, "w", encoding="utf-8").write(new)
            total_edits += 1

    # 复查：改名之后是否还有残留（含 super.ctor( 漏改）
    leftovers = []
    for path in dart_files(roots):
        try:
            src = open(path, encoding="utf-8", errors="replace").read()
        except Exception:
            continue
        for cls, ctor, nn, pattern in call_patterns:
            if re.search(r"\b" + re.escape(cls) + r"\." + re.escape(ctor) + r"\b", src):
                leftovers.append(f"{cls}.{ctor}  {path}")
        for cls, pairs in ctor_map.items():
            for ctor in pairs:
                if re.search(r"\bsuper\." + re.escape(ctor) + r"\b", src):
                    leftovers.append(f"super.{ctor}  {path}")

    print(f"改写 {total_edits} 个文件；改名 {len(renames)} 个构造函数")
    for cls, ctor, nn in renames:
        print(f"  {cls}.{ctor} -> {cls}.{nn}")
    if leftovers:
        print("⚠️ 仍残留（可能需要手工处理）：")
        for item in leftovers[:20]:
            print("  " + item)

    if args.report:
        json.dump(
            {
                "collisions": [{"class": c, "ctor": k, "new": n} for c, k, n in renames],
                "files_scanned": files,
                "files_rewritten": total_edits,
                "leftovers": leftovers,
            },
            open(args.report, "w"),
            ensure_ascii=False,
            indent=2,
        )


if __name__ == "__main__":
    sys.exit(main())
