import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

import 'status_card.dart';

/// 修改这段文字，或替换 assets/patch_demo.png，然后运行
/// `dart run flutter_patcher patch android`：更新后冷启动即可看到变化。
const message = '这条文字来自已安装的应用';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init();
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  static ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF0071E3),
        brightness: brightness,
        primary: dark ? const Color(0xFF0A84FF) : const Color(0xFF0071E3),
        surface: dark ? const Color(0xFF1C1C1E) : Colors.white,
      ),
      scaffoldBackgroundColor: dark ? Colors.black : const Color(0xFFF5F5F7),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'flutter_patcher',
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    home: const Demo(),
  );
}

class Demo extends StatefulWidget {
  const Demo({super.key});

  @override
  State<Demo> createState() => _DemoState();
}

class _DemoState extends State<Demo> {
  // 在本机运行 `flutter_patcher serve`，再通过 adb reverse 走 USB 访问。
  final _url = TextEditingController();
  final _log = <String>[];
  var _busy = false;
  var _checks = 0;

  void _note(String line) => setState(() => _log.add(line));

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on PatcherException catch (e) {
      _note(e.message);
    } finally {
      setState(() {
        _busy = false;
        _checks++;
      });
    }
  }

  Future<void> _update() => _run(() async {
    final url = _url.text.trim();
    final check = await FlutterPatcher.checkUpdate(
      url: url.isEmpty ? null : url,
    );
    if (!check.hasUpdate) return _note('已是最新版本');
    PatchApplyPhase? phase;
    final result = await FlutterPatcher.applyPatch(
      check.patch!,
      onProgress: (p) {
        if (p.phase != phase) _note('${(phase = p.phase).name}…');
      },
    );
    _note(
      result.ok
          ? '安装完成：重启应用即可运行补丁 ${check.patch!.version}'
          : '安装失败：${result.error?.name} ${result.message ?? ''}',
    );
  });

  Future<void> _rollback() => _run(() async {
    await FlutterPatcher.rollback();
    _note('已回滚：重启应用即可运行已安装的版本');
  });

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 32, 16, 32),
          children: [
            Text(
              'flutter_patcher',
              style: text.headlineLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 24),
            Panel(
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset('assets/patch_demo.png', height: 160),
                  ),
                  const SizedBox(height: 16),
                  Text(message, style: text.titleMedium),
                ],
              ),
            ),
            const SizedBox(height: 16),
            StatusCard(refresh: _checks),
            const SizedBox(height: 16),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '更新地址',
                      helperText: '留空则使用构建此应用时的地址',
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _update,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      shape: const StadiumBorder(),
                    ),
                    child: Text(_busy ? '处理中…' : '检查更新'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _rollback,
                    child: const Text('回滚'),
                  ),
                ],
              ),
            ),
            if (_log.isNotEmpty) ...[
              const SizedBox(height: 16),
              Panel(
                child: Text(
                  _log.join('\n'),
                  style: text.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: secondary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
