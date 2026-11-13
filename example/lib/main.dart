import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

import 'status_card.dart';

/// 修改这段文字，或替换 assets/patch_demo.png，然后运行
/// `dart run flutter_patcher patch android`：更新后冷启动即可看到变化。
const message = '这条文字来自补丁 · 技能验证';

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
  // 本机跑 `flutter_patcher serve`（或任何静态服务）后填它的地址：留空是
  // http://127.0.0.1:8686；走 USB 时先 `adb reverse tcp:8686 tcp:8686`，
  // 走局域网时填 http://<本机IP>:<端口>/<目录>。
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

  /// 自己下载补丁文件，再交给库校验安装。
  ///
  /// `checkUpdate` 只接受 https 或回环地址，因为补丁是可执行代码。这里把
  /// “从哪儿下载、用什么协议”留在本项目里：用 [FlutterPatcher.patchTarget]
  /// 拿到本宿主的文件名，自己取前 146 字节判断是否新鲜，再整包下载交给
  /// [FlutterPatcher.applyPatchBytes]。指纹、SHA-256、签名与安装仍全部由库校验。
  Future<void> _update() => _run(() async {
    final base = _url.text.trim().isEmpty
        ? 'http://127.0.0.1:8686'
        : _url.text.trim();
    final target = await FlutterPatcher.patchTarget;
    final file = Uri.parse(
      '${base.replaceFirst(RegExp(r'/+$'), '')}/${target.fileName}',
    );
    _note('GET $file');

    final header = await _fetch(file, limit: 146);
    if (header == null) return _note('服务器上没有这个宿主的补丁');
    final inspection = await FlutterPatcher.inspectPatch(header);
    if (!inspection.fresh) {
      final why = inspection.reason ?? 'seq ${inspection.seq}';
      return _note('已是最新版本（$why）');
    }

    _note('downloading…');
    final bytes = await _fetch(file);
    if (bytes == null) return _note('下载失败：文件不见了');
    _note('verifying…');
    final result = await FlutterPatcher.applyPatchBytes(bytes);
    _note(
      result.ok
          ? '安装完成：重启应用即可运行补丁 ${inspection.seq}'
          : '安装失败：${result.error?.name} ${result.message ?? ''}',
    );
  });

  /// [uri] 的内容，或 null（404）；[limit] 表示只要前几个字节。
  ///
  /// 不限制 scheme：下载策略属于本项目，库的默认策略只用于它自己的下载器。
  Future<List<int>?> _fetch(Uri uri, {int? limit}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      if (limit != null) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${limit - 1}');
      }
      final response = await request.close();
      if (response.statusCode == HttpStatus.notFound) return null;
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw PatcherException('HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (limit != null && bytes.length >= limit) break;
      }
      return limit == null || bytes.length <= limit
          ? bytes
          : bytes.sublist(0, limit);
    } finally {
      client.close(force: true);
    }
  }

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
                      helperText: '留空则用 http://127.0.0.1:8686',
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
