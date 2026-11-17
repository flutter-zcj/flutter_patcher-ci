#!/usr/bin/env python3
"""在 runner 的工程副本上注入 iOS 手动签名设置（保持 pbxproj 的 OpenStep 文本格式）。

flutter_patcher 的 `build ios` 内部走 `flutter build ipa`，不会像旧 workflow 那样
先 `--no-codesign` 再自己 xcodebuild，所以签名必须在 build 之前就写进工程；
而它做 SPM 文本解析，pbxproj 不能转成 XML，只能做文本级注入。

用法：prepare_ios_signing.py <bundle_id> <team_id> <profile_name> [project_dir]
"""

import os
import re
import sys

bundle, team, profile = sys.argv[1], sys.argv[2], sys.argv[3]
project = sys.argv[4] if len(sys.argv) > 4 else os.getcwd()
pbx = os.path.join(project, "ios/Runner.xcodeproj/project.pbxproj")
src = open(pbx, encoding="utf-8").read()

# 1) 统一 bundle id（只改已有值的键，不动结构）
src, count = re.subn(
    r"(PRODUCT_BUNDLE_IDENTIFIER\s*=\s*)[^;]+;",
    lambda m: m.group(1) + bundle + ";",
    src,
)
print(f"PRODUCT_BUNDLE_IDENTIFIER -> {bundle}（{count} 处）")

# 2) 只给「带 bundle id 的 buildSettings 块」（即 Runner target 的 Debug/Release/Profile）
#    注入手动签名；CocoaPods 的 framework target 在 Pods 自己的工程里，不会被影响。
if 'PROVISIONING_PROFILE_SPECIFIER' not in src:
    keys = (
        "\n\t\t\t\tCODE_SIGN_STYLE = Manual;"
        f'\n\t\t\t\tDEVELOPMENT_TEAM = {team};'
        f'\n\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = "{profile}";'
        '\n\t\t\t\tCODE_SIGN_IDENTITY = "Apple Distribution";'
    )

    def inject(match):
        block = match.group(0)
        if "PRODUCT_BUNDLE_IDENTIFIER" not in block:
            return block
        if "PROVISIONING_PROFILE_SPECIFIER" in block:
            return block
        return block.replace("buildSettings = {", "buildSettings = {" + keys, 1)

    src = re.sub(r"buildSettings = \{.*?\n\t\t\t\};", inject, src, flags=re.S)

open(pbx, "w", encoding="utf-8").write(src)

remaining = src.count("CODE_SIGN_STYLE = Manual")
missing = src.count("PROVISIONING_PROFILE_SPECIFIER")
print(f"手动签名注入：CODE_SIGN_STYLE=Manual {remaining} 处，PROVISIONING_PROFILE_SPECIFIER {missing} 处")
if remaining == 0 or missing == 0:
    sys.exit("签名设置注入失败：pbxproj 结构可能已变")
