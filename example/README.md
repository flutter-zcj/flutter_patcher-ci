# flutter_patcher 示例

> 将示例应用构建为宿主（host），修改其中的文字或图片，然后在手机上以补丁（patch）的形式运行这处改动。
>
> 你已经检出了这个仓库，想在把 flutter_patcher 集成到自己项目中之前，先看一次补丁真实跑起来的效果。Android 通过 USB 运行，不需要服务器，也不需要密钥；iOS 需要一台 Mac，以及一条隧道（tunnel）。
>
> 你自己项目首次接入的完整流程见 [Getting Started](../doc/getting-started.md)。

## 前置条件

你需要：

- Flutter 3.47.0 到 3.47.9（可用 `dart run flutter_patcher doctor` 检查版本）；
- 一台 `arm64-v8a` 手机，系统为 Android 9 或更高版本，通过 USB 连接并开启 USB 调试。

## Android：通过 USB 运行

1. 构建宿主（host）并安装：

   ```bash
   cd example
   dart run flutter_patcher build android --out build/host
   adb install build/host/app-release.apk
   ```

   构建过程会打印 `UNSIGNED` 和 `BASELINE_STORE_LOCAL` 两条警告；在这里这两条都是预期内的。
   应用打开后显示 **Running the installed version**（正在运行已安装的版本）。
   `--out` 必须指向一个不存在的目录，所以再次构建前要先删除 `build/host`。

2. 在第二个终端里，于 `example` 目录启动 `serve`，并让它保持运行：

   ```bash
   dart run flutter_patcher serve
   # 通过 adb reverse，把最新的补丁在 127.0.0.1:8686 上提供给手机
   ```

3. 改动一点东西：编辑 `lib/main.dart` 中的 `message`，或者把 `assets/patch_demo_patched.png` 覆盖到 `assets/patch_demo.png`。然后生成补丁：

   ```bash
   dart run flutter_patcher patch android
   ```

4. 在应用里点击 **Check for update**（检查更新），然后关闭应用并重新打开。
   屏幕上会显示你的改动，以及 **Running patch <seq>**（正在运行补丁 <序号>）。

每做一次改动，重复第 3、4 步；`serve` 会在约 2 秒内拾取到每个新补丁。

要恢复到已安装的版本，生成一个撤回（withdrawal）文件，并用同样的方式下发：

```bash
dart run flutter_patcher patch android --withdraw
```

点击 **Check for update** 并重启应用：屏幕上又显示 **Running the installed version**（正在运行已安装的版本）了。

**Roll back（回滚）** 只在这台手机上移除补丁，不需要撤回文件。

## 自定义下发（Custom delivery）

一个补丁就是一个文件；`patch` 会以 `file` 的形式打印出它的路径。`serve` 只是把补丁交给手机的其中一种方式。应用也可以通过自己的渠道获取该文件，例如你自己的服务器、一条消息或本地存储，然后安装它：

```dart
// 校验并安装应用自行获取的补丁文件。
final result = await FlutterPatcher.applyPatchBytes(bytes);
```

`(await FlutterPatcher.patchTarget).fileName` 是这个宿主所接受的文件的名称。参见 [Custom Delivery from Your Own Server](../doc/advanced.md#custom-delivery-from-your-own-server)。

## iOS

你需要一台 Apple Silicon Mac，在 Xcode 中为示例应用配置好签名（Team 和 Bundle ID），并且有一台已在该 Team 下注册的 iPhone。

1. 在 Mac 桌面会话的终端窗口里构建，因为代码签名只有在那个环境下才能访问钥匙串：

   ```bash
   dart run flutter_patcher build ios --export-method development --out build/host
   ```

   `development` 会让生成的应用可以被你已注册的 iPhone 安装；默认的 `app-store` 则需要分发证书。

2. 把 `build/host/app-release.ipa` 安装到 iPhone，例如在 Xcode 的 Devices and Simulators（设备与模拟器）窗口中安装。

3. iPhone 无法访问 Mac 的 `127.0.0.1`。启动 `serve`，用一条隧道以 HTTPS 对外暴露它，再把隧道的地址填入应用里的 **Update address**（更新地址）字段：

   ```bash
   cloudflared tunnel --url http://127.0.0.1:8686
   # 会打印一个 https:// 地址，它将请求转发给 serve
   ```

4. 用 `dart run flutter_patcher patch ios` 生成补丁，然后和在 Android 上一样，点击 **Check for update** 并重启应用。

iOS 上的其他差异列在 [Differences on iOS](../doc/getting-started.md#differences-on-ios) 中。

## 走向生产（Going to production）

在构建你要发布的正式版本之前：

- 把提供补丁文件的 HTTPS 地址传给 `checkUpdate(url: …)`，或者使用自定义下发；
- 把 `baseline_store` 设置为持久化存储，因为某个构建的每个补丁都需要它的 baseline（基线）；
- 运行 `dart run flutter_patcher init`，并在 `flutter_patcher.yaml` 中设置 `trust.enabled: true`，这样应用只接受你签名过的补丁。

具体步骤见 [Production Deployment Guide](../doc/production-playbook.md)。