import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ubaa_domain/ubaa_domain.dart';

import '../../common/tag.dart';
import '../../shared/dialogs/confirmation.dart';
import '../home/todo_card.dart';

class CampusCardHome {
  CampusCardHome(this.changed);

  final VoidCallback changed;
  CampusCardService? service;
  CampusAccountService? portal;
  Future<CampusCardSettings?> Function()? readSettings;
  Future<void> Function(CampusCardSettings)? saveSettings;
  bool connecting = false;
  bool _disposed = false;
  CampusCardSettings? settings;
  int? _balance;
  int _generation = 0;
  Future<void>? _refresh;
  bool paying = false;
  bool needsReview = false;
  String? message;

  void update({
    required CampusCardService? service,
    required CampusAccountService? portal,
    required Future<CampusCardSettings?> Function()? readSettings,
    required Future<void> Function(CampusCardSettings)? saveSettings,
    required bool connecting,
    bool reset = false,
    bool accountChanged = false,
  }) {
    final reload =
        reset ||
        !identical(this.service, service) ||
        !identical(this.portal, portal) ||
        (this.connecting && !connecting);
    this.service = service;
    this.portal = portal;
    this.readSettings = readSettings;
    this.saveSettings = saveSettings;
    this.connecting = connecting;
    if (!reload) return;
    _generation++;
    _balance = null;
    _refresh = null;
    if (accountChanged) {
      settings = null;
      message = null;
      needsReview = false;
      paying = false;
    } else if (paying) {
      paying = false;
      needsReview = true;
      message = '充值结果待核对。请先查看航财通交费记录。';
    }
    _start();
  }

  void dispose() => _disposed = true;

  void _mutate(VoidCallback apply) {
    apply();
    changed();
  }

  void _start() {
    if (service == null) return;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!_current(generation)) return;
      try {
        final stored = await readSettings?.call();
        if (!_current(generation)) return;
        _mutate(() => settings ??= stored);
      } on Object {
        // 损坏或不可读的偏好不会启用一键付款。
      }
      if (_current(generation)) await refresh();
    });
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> save(CampusCardSettings value) async {
    final generation = _generation;
    await saveSettings?.call(value);
    if (!_current(generation)) return;
    _mutate(() => settings = value);
    await refresh();
  }

  Future<void> refresh() {
    final portal = this.portal;
    if (service == null ||
        portal == null ||
        connecting ||
        settings == null ||
        paying) {
      return Future.value();
    }
    final existing = _refresh;
    if (existing != null) return existing;
    final generation = _generation;
    late final Future<void> pending;
    pending = (() async {
      int? balance;
      try {
        final metrics = await portal.metrics();
        if (metrics.cardBalance case CampusMetricValue<CampusAmount>(
          :final value,
        )) {
          if (value.unit.isEmpty || value.unit == '元') {
            balance = campusCardCents(value.value);
          }
        }
      } on Object {
        // 查询失败不当作零余额，也不使用旧余额触发充值。
      }
      if (_current(generation) && identical(_refresh, pending)) {
        _mutate(() {
          _balance = balance;
          _refresh = null;
        });
      }
    })();
    _mutate(() {
      _balance = null;
      _refresh = pending;
    });
    return pending;
  }

  Future<void> recharge(int cents, String wallet) async {
    final service = this.service;
    if (service == null || connecting || paying || needsReview) return;
    final generation = _generation;
    _mutate(() {
      paying = true;
      message = null;
    });
    try {
      final result = await service.recharge(cents, wallet);
      if (!_current(generation)) return;
      _mutate(() {
        // 等用户下次刷新首页，避免门户同步前再次出现旧余额的充值按钮。
        _balance = null;
        _refresh = null;
        message = switch (result) {
          CampusCardPayment.paid => '已支付 ¥${campusCardYuan(cents)}。',
          CampusCardPayment.syncing => '已支付 ¥${campusCardYuan(cents)}，等待校园卡同步。',
        };
        needsReview = result == CampusCardPayment.syncing;
      });
    } on UiError catch (error) {
      if (!_current(generation)) return;
      _mutate(() {
        message = error.message;
        needsReview = error.code == UbaaErrorCode.outcomeUnknown;
      });
    } on Object {
      if (!_current(generation)) return;
      _mutate(() {
        message = '充值结果待核对。请先查看航财通交费记录。';
        needsReview = true;
      });
    } finally {
      if (_current(generation)) {
        _mutate(() => paying = false);
      }
    }
  }

  Future<void> confirmReview(BuildContext context) async {
    final generation = _generation;
    final reviewed = await uiConfirmIrreversible(
      context,
      title: '已核对交费记录？',
      message: '请先在航财通确认上一笔充值的状态，再决定是否继续充值。',
      action: '已核对',
    );
    if (!reviewed || !_current(generation)) return;
    _mutate(() {
      needsReview = false;
      message = null;
    });
    await refresh();
  }

  Widget? reminder(VoidCallback open) {
    if (service == null) return null;
    final settings = this.settings;
    final balance = _balance;
    final low = settings?.promptsFor(balance) ?? false;
    final message = this.message;
    if (!low && message == null && !paying) return null;
    final action = needsReview
        ? TextButton(onPressed: open, child: const Text('查看'))
        : low
        ? FilledButton(
            onPressed: connecting || paying || _refresh != null
                ? null
                : () => recharge(settings!.rechargeCents, settings.wallet),
            child: Text('充值 ¥${campusCardYuan(settings!.rechargeCents)}'),
          )
        : message != null
        ? IconButton(
            tooltip: '关闭充值提示',
            onPressed: () => _mutate(() => this.message = null),
            icon: const Icon(Icons.close),
          )
        : null;
    return HomeTodoCardFrame(
      metadata: UiTag(
        '校园卡',
        icon: Icons.account_balance_wallet_outlined,
        tone: low ? UiTagTone.warning : UiTagTone.primary,
      ),
      title: low ? '校园卡余额 ¥${campusCardYuan(balance!)}' : '校园卡充值',
      detail: Text(
        message ?? (paying ? '正在充值…' : campusCardWalletName(settings!.wallet)),
      ),
      trailing: action == null
          ? null
          : Padding(padding: const EdgeInsets.only(left: 8), child: action),
      onTap: open,
    );
  }
}
