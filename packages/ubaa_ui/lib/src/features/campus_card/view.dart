import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ubaa_domain/ubaa_domain.dart';

import '../../shared/dialogs/confirmation.dart';
import '../../theme.dart';

class CampusCardView extends StatefulWidget {
  const CampusCardView({
    super.key,
    required this.service,
    required this.settings,
    required this.paying,
    required this.message,
    required this.needsReview,
    required this.onSave,
    required this.onRecharge,
    required this.onReview,
  });

  final CampusCardService? service;
  final CampusCardSettings? settings;
  final bool paying, needsReview;
  final String? message;
  final Future<void> Function(CampusCardSettings)? onSave;
  final Future<void> Function(int, String) onRecharge;
  final Future<void> Function() onReview;

  @override
  State<CampusCardView> createState() => _CampusCardViewState();
}

class _CampusCardViewState extends State<CampusCardView> {
  final _amount = TextEditingController();
  List<String> _wallets = [];
  String? _selected, _error;
  bool _loading = true;
  bool _confirming = false;
  bool _amountEdited = false;
  bool _walletEdited = false;
  int _revision = 0;
  int _balanceRevision = 0;
  int? _balance;
  bool _balanceLoading = false;
  bool _balanceFailed = false;

  @override
  void initState() {
    super.initState();
    _applySettings();
    unawaited(_load());
    unawaited(_loadBalance());
  }

  @override
  void didUpdateWidget(covariant CampusCardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.service, oldWidget.service)) {
      _balance = null;
      unawaited(_load());
      unawaited(_loadBalance());
    }
    if (!identical(widget.settings, oldWidget.settings)) _applySettings();
  }

  void _applySettings() {
    if (!_amountEdited)
      _amount.text = campusCardYuan(widget.settings?.rechargeCents ?? 5000);
    if (!_walletEdited && _wallets.contains(widget.settings?.wallet)) {
      _selected = widget.settings?.wallet;
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final revision = ++_revision;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final wallets = await widget.service?.wallets() ?? [];
      if (!mounted || revision != _revision) return;
      setState(() {
        _wallets = wallets;
        if (!wallets.contains(_selected)) {
          _selected = wallets.contains(widget.settings?.wallet)
              ? widget.settings!.wallet
              : wallets.length == 1
              ? wallets.single
              : null;
        }
      });
    } on UiError catch (error) {
      if (mounted && revision == _revision)
        setState(() => _error = error.message);
    } on Object {
      if (mounted && revision == _revision)
        setState(() => _error = '暂时无法读取已绑定的钱包。');
    } finally {
      if (mounted && revision == _revision) setState(() => _loading = false);
    }
  }

  Future<void> _loadBalance() async {
    final revision = ++_balanceRevision;
    setState(() {
      _balanceLoading = true;
      _balanceFailed = false;
    });
    try {
      final value = await widget.service?.balance();
      if (mounted && revision == _balanceRevision) {
        setState(() => _balance = value);
      }
    } on Object {
      if (mounted && revision == _balanceRevision) {
        setState(() {
          _balance = null;
          _balanceFailed = true;
        });
      }
    } finally {
      if (mounted && revision == _balanceRevision) {
        setState(() => _balanceLoading = false);
      }
    }
  }

  Future<void> _confirm(int cents, String wallet) async {
    setState(() => _confirming = true);
    try {
      final confirmed = await uiConfirmIrreversible(
        context,
        title: '确认校园卡充值',
        message:
            '使用${campusCardWalletName(wallet)}支付 ¥${campusCardYuan(cents)}。如有同类未支付订单，将关闭旧订单再创建新订单。',
        action: '确认充值',
      );
      if (confirmed && mounted) {
        await widget.onRecharge(cents, wallet);
        if (mounted) await _loadBalance();
      }
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  Future<void> _settings() async {
    final saved = await showDialog<CampusCardSettings>(
      context: context,
      builder: (_) =>
          _SettingsDialog(wallets: _wallets, current: widget.settings),
    );
    if (saved == null || !mounted) return;
    try {
      await widget.onSave?.call(saved);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('快捷充值设置已保存')));
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未能保存快捷充值设置')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final cents = campusCardCents(_amount.text);
    final wallet = _selected;
    final busy = widget.paying || _confirming;
    return ListView(
      padding: UbaaTheme.pageInsets(context, top: 12),
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  color: colors.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        const Icon(Icons.account_balance_wallet_outlined),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('校园卡余额', style: text.labelLarge),
                              Text(
                                _balance == null
                                    ? '—'
                                    : '¥${campusCardYuan(_balance!)}',
                                style: text.headlineSmall,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '刷新航财通余额',
                          onPressed: busy || _balanceLoading
                              ? null
                              : _loadBalance,
                          icon: const Icon(Icons.refresh),
                        ),
                        IconButton(
                          tooltip: '快捷充值设置',
                          onPressed:
                              busy ||
                                  _loading ||
                                  _wallets.isEmpty ||
                                  widget.onSave == null
                              ? null
                              : _settings,
                          icon: const Icon(Icons.settings_outlined),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_balanceFailed) const Text('暂时无法读取航财通余额。'),
                const SizedBox(height: 24),
                Text('充值金额', style: text.titleMedium),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final preset in [1000, 2000, 5000, 10000])
                      ChoiceChip(
                        label: Text('¥${preset ~/ 100}'),
                        selected: cents == preset,
                        onSelected: busy
                            ? null
                            : (_) => setState(() {
                                _amountEdited = true;
                                _amount.text = campusCardYuan(preset);
                              }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  enabled: !busy,
                  controller: _amount,
                  onChanged: (_) => setState(() => _amountEdited = true),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '自定义金额（元）',
                    errorText:
                        _amount.text.isNotEmpty && (cents == null || cents == 0)
                        ? '请输入大于 0 且最多两位小数的金额'
                        : null,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(child: Text('数币钱包', style: text.titleMedium)),
                    IconButton(
                      tooltip: '刷新已绑定钱包',
                      onPressed: _loading || busy ? null : _load,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                if (_loading)
                  const LinearProgressIndicator()
                else if (_error case final error?)
                  Text(error)
                else if (_wallets.isEmpty)
                  const Text('未找到可用的数币钱包，请先在航财通绑定。')
                else
                  DropdownButton<String>(
                    isExpanded: true,
                    value: _wallets.contains(wallet) ? wallet : null,
                    hint: const Text('选择本次支付的钱包'),
                    items: [
                      for (final code in _wallets)
                        DropdownMenuItem(
                          value: code,
                          child: Text(campusCardWalletName(code)),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) => setState(() {
                            _walletEdited = true;
                            _selected = value;
                          }),
                  ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed:
                      busy ||
                          widget.needsReview ||
                          _loading ||
                          _error != null ||
                          cents == null ||
                          cents == 0 ||
                          wallet == null ||
                          !_wallets.contains(wallet)
                      ? null
                      : () => _confirm(cents, wallet),
                  child: Text(widget.paying ? '正在充值…' : '充值'),
                ),
                if (widget.message case final message?) ...[
                  const SizedBox(height: 12),
                  Text(message),
                ],
                if (widget.needsReview)
                  TextButton(
                    onPressed: widget.onReview,
                    child: const Text('已核对交费记录'),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.wallets, required this.current});
  final List<String> wallets;
  final CampusCardSettings? current;
  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final _threshold = TextEditingController(
    text: campusCardYuan(widget.current?.thresholdCents ?? 1000),
  );
  late final _recharge = TextEditingController(
    text: campusCardYuan(widget.current?.rechargeCents ?? 5000),
  );
  late String? _wallet = widget.wallets.contains(widget.current?.wallet)
      ? widget.current!.wallet
      : widget.wallets.length == 1
      ? widget.wallets.single
      : null;

  @override
  void dispose() {
    _threshold.dispose();
    _recharge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final limit = campusCardCents(_threshold.text);
    final amount = campusCardCents(_recharge.text);
    final wallet = _wallet;
    return AlertDialog(
      title: const Text('快捷充值设置'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 20,
        children: [
          DropdownButtonFormField<String>(
            initialValue: wallet,
            decoration: const InputDecoration(labelText: '默认数币钱包'),
            isExpanded: true,
            items: [
              for (final code in widget.wallets)
                DropdownMenuItem(
                  value: code,
                  child: Text(campusCardWalletName(code)),
                ),
            ],
            onChanged: (value) => setState(() => _wallet = value),
          ),
          TextField(
            controller: _threshold,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: '余额阈值（元）'),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: _recharge,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: '快捷充值金额（元）'),
            onChanged: (_) => setState(() {}),
          ),
          const Text('余额低于阈值时，首页「待办」会提示。点击充值按钮才会扣款；如有同类未支付订单，会关闭旧订单。'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed:
              wallet == null || limit == null || amount == null || amount == 0
              ? null
              : () => Navigator.pop(
                  context,
                  CampusCardSettings(
                    wallet: wallet,
                    thresholdCents: limit,
                    rechargeCents: amount,
                  ),
                ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
