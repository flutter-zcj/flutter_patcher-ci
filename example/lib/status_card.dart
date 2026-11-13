import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

/// 圆角、轻阴影的分组卡片，风格同 iOS 设置页。
class Panel extends StatelessWidget {
  const Panel({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          if (light)
            const BoxShadow(
              color: Color(0x0F000000),
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
        ],
      ),
      child: child,
    );
  }
}

/// 本次冷启动实际运行的版本。打过补丁的启动会在第一帧时被记录，
/// 因此在那之前卡片显示加载状态。应用或回滚补丁会立即改变已安装的
/// 补丁，以及重启后运行的版本。
class StatusCard extends StatefulWidget {
  const StatusCard({required this.refresh, super.key});

  /// 每次更新或回滚后变化，用于重新读取已安装的补丁。
  final int refresh;

  @override
  State<StatusCard> createState() => _StatusCardState();
}

class _StatusCardState extends State<StatusCard> {
  PatchBootDiagnostic? _boot;
  List<(String, String)>? _rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(StatusCard old) {
    super.didUpdateWidget(old);
    if (old.refresh != widget.refresh) _load();
  }

  Future<void> _load() async {
    final boot = await FlutterPatcher.lastBootDiagnostic;
    final rows = [
      ('已安装补丁', await FlutterPatcher.currentVersion ?? '无'),
      ('版本号', '${await FlutterPatcher.appVersionCode ?? '-'}'),
      ('补丁文件', await _patchFile()),
      ('ABI', await FlutterPatcher.deviceAbi),
      if (boot?.message case final message? when message.isNotEmpty)
        ('详情', message),
    ];
    if (!mounted) return;
    setState(() {
      _boot = boot;
      _rows = rows;
    });
  }

  /// 本机可接受的补丁文件名；若应用不是由 flutter_patcher 构建的，
  /// 则没有对应文件。
  static Future<String> _patchFile() async {
    try {
      return (await FlutterPatcher.patchTarget).fileName;
    } on PatcherException {
      return '-';
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (color, icon, title) = switch (_boot?.status) {
      null => (Colors.grey, Icons.hourglass_empty, '尚未记录冷启动'),
      PatchBootStatus.patched => (
        dark ? const Color(0xFF30D158) : const Color(0xFF34C759),
        Icons.check_circle,
        '正在运行补丁 ${_boot!.patchVersion ?? ''}',
      ),
      PatchBootStatus.noPatch => (
        Colors.grey,
        Icons.circle_outlined,
        '正在运行已安装的版本',
      ),
      PatchBootStatus.droppedCircuitBreaker => (
        dark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30),
        Icons.error,
        '崩溃后已自动回滚补丁',
      ),
      final status => (
        dark ? const Color(0xFFFF9F0A) : const Color(0xFFFF9500),
        Icons.warning_rounded,
        status.name,
      ),
    };
    final text = Theme.of(context).textTheme;
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    final rows = _rows;
    return Panel(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: rows == null
            ? Row(
                key: const ValueKey('loading'),
                children: [
                  const SizedBox.square(
                    dimension: 36,
                    child: Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '正在检查本次启动…',
                    style: text.titleMedium?.copyWith(color: secondary),
                  ),
                ],
              )
            : Column(
                key: const ValueKey('status'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: color.withValues(alpha: 0.15),
                        child: Icon(icon, color: color, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(title, style: text.titleMedium)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final (label, value) in rows)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Text(label, style: text.bodyMedium),
                          const SizedBox(width: 16),
                          // 过长的值（例如补丁文件名）会自动换行。
                          Expanded(
                            child: Text(
                              value,
                              textAlign: TextAlign.end,
                              style: text.bodyMedium?.copyWith(
                                color: secondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
