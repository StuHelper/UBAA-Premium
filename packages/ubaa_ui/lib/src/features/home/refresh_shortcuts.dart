import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Widget withRefreshShortcuts(
  Widget shell,
  Future<void> Function()? refreshPage,
) {
  // 桌面快捷键的父层级保持稳定，切页时只调整可用的绑定。
  void refresh() => unawaited(refreshPage?.call());
  return CallbackShortcuts(
    bindings: {
      if (refreshPage != null)
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true): refresh,
      if (refreshPage != null)
        const SingleActivator(LogicalKeyboardKey.keyR, control: true): refresh,
    },
    child: Focus(autofocus: true, child: shell),
  );
}
