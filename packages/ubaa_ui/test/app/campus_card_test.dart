import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ubaa_domain/ubaa_domain.dart';
import 'package:ubaa_ui/ubaa_ui.dart';

const _quick = CampusCardSettings(
  wallet: 'icbc',
  thresholdCents: 1000,
  rechargeCents: 5000,
);

class _Portal implements CampusAccountService {
  String? balance = '9.99';
  int reads = 0;
  Completer<void>? gate;

  @override
  Future<CampusMetrics> metrics() async {
    reads++;
    await gate?.future;
    final at = DateTime.utc(2026, 11, 13);
    return CampusMetrics(
      cardBalance: switch (balance) {
        final String amount => CampusMetricValue(
          CampusAmount(value: amount, unit: '元'),
          fetchedAt: at,
        ),
        null => CampusMetricFailure('合成查询错误', fetchedAt: at),
      },
      networkBalance: null,
      unreadMail: null,
      borrowedBooks: null,
      cloudStorageRemaining: null,
    );
  }

  @override
  Future<CampusAccountSnapshot> cached() async => const CampusAccountSnapshot();

  @override
  Future<PortalIdentity> identity() async => throw UnimplementedError();

  @override
  Future<NetworkUsage> networkUsage() async => throw UnimplementedError();
}

class _Payments implements CampusCardService {
  int balanceReads = 0;
  int walletReads = 0;
  int currentBalance = 4200;
  final submitted = <(int, String)>[];

  @override
  Future<int> balance() async {
    balanceReads++;
    return currentBalance;
  }

  @override
  Future<List<String>> wallets() async {
    walletReads++;
    return ['icbc', 'ccb'];
  }

  @override
  Future<CampusCardPayment> recharge(int cents, String wallet) async {
    submitted.add((cents, wallet));
    currentBalance += cents;
    return CampusCardPayment.paid;
  }
}

Future<void> _open(
  WidgetTester tester,
  _Portal portal,
  _Payments payments, {
  CampusCardSettings? settings = _quick,
  Future<void> Function(CampusCardSettings)? save,
  Size size = const Size(430, 1050),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: UbaaTheme.light().copyWith(platform: TargetPlatform.windows),
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: child!,
      ),
      home: UbaaMainShell(
        user: const UserSummary(username: 'fixture', displayName: '测试同学'),
        snapshots: {
          for (final feature in FeatureId.values)
            feature: FeatureSnapshot(feature: feature),
        },
        routePolicy: RoutePolicy.webvpn,
        campusAccountService: portal,
        campusCardService: payments,
        onReadCampusCardSettings: () async => settings,
        onSaveCampusCardSettings: save,
        onRefresh: () async {},
        onRetryFeature: (_) async {},
        onLogout: () async {},
        onLogoutAndClearAccount: () async {},
        onRoutePolicyChanged: (_) {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('首页待办用门户余额和设置直接提交一笔，完成后收起旧提示', (tester) async {
    final portal = _Portal();
    final payments = _Payments();
    await _open(tester, portal, payments);

    final quickPay = find.widgetWithText(FilledButton, '充值 ¥50.00');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('home-todos')),
        matching: quickPay,
      ),
      findsOneWidget,
    );
    expect(find.text('校园卡余额 ¥9.99'), findsOneWidget);
    expect(find.text('中国工商银行钱包'), findsOneWidget);
    expect(portal.reads, 1);
    expect(payments.balanceReads, 0);
    expect(payments.walletReads, 0);
    expect(payments.submitted, isEmpty);

    await tester.ensureVisible(quickPay);
    await tester.pumpAndSettle();
    await tester.tap(quickPay);
    await tester.pumpAndSettle();
    expect(payments.submitted, [(5000, 'icbc')]);
    expect(quickPay, findsNothing);
    expect(payments.balanceReads, 0);
  });

  testWidgets('刷新时收起旧提示；余额等于阈值或门户查询失败不出现按钮', (tester) async {
    final portal = _Portal();
    final payments = _Payments();
    await _open(tester, portal, payments);
    final refresh = find.byTooltip('刷新');
    final quickPay = find.widgetWithText(FilledButton, '充值 ¥50.00');
    expect(quickPay, findsOneWidget);

    portal.balance = '10.00';
    portal.gate = Completer();
    await tester.tap(refresh);
    await tester.pump();
    expect(quickPay, findsNothing);
    portal.gate!.complete();
    await tester.pumpAndSettle();
    expect(quickPay, findsNothing);

    portal.balance = null;
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(portal.reads, 3);
    expect(quickPay, findsNothing);
    expect(payments.balanceReads, 0);
    expect(payments.submitted, isEmpty);
  });

  testWidgets('充值页读取航财通余额和钱包，自定义金额确认后才支付', (tester) async {
    final portal = _Portal();
    final payments = _Payments();
    await _open(tester, portal, payments, save: (_) async {});
    final lowBalance = find.text('校园卡余额 ¥9.99');
    await tester.ensureVisible(lowBalance);
    await tester.pumpAndSettle();
    await tester.tap(lowBalance);
    await tester.pumpAndSettle();
    expect(find.text('¥42.00'), findsOneWidget);
    expect(payments.walletReads, 1);

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('中国建设银行钱包').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '0.10');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '充值'));
    await tester.pumpAndSettle();
    expect(payments.submitted, isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, '确认充值'));
    await tester.pumpAndSettle();
    expect(payments.submitted, [(10, 'ccb')]);
    expect(find.text('¥42.10'), findsOneWidget);
    expect(portal.reads, 1);
  });

  testWidgets('快捷设置从账户钱包中选择，并以设置的分值在首页提交', (tester) async {
    final portal = _Portal();
    final payments = _Payments();
    CampusCardSettings? stored;
    await _open(
      tester,
      portal,
      payments,
      settings: null,
      save: (value) async => stored = value,
      size: const Size(360, 800),
      textScale: 1.4,
    );
    expect(portal.reads, 0);

    await tester.tap(find.byKey(const ValueKey('tab-校园')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('校园卡充值'));
    await tester.pumpAndSettle();
    expect(payments.walletReads, 1);
    await tester.tap(find.byTooltip('快捷充值设置'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    await tester.tap(
      find.descendant(
        of: dialog,
        matching: find.byType(DropdownButtonFormField<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('中国建设银行钱包').last);
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: dialog,
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '15.01');
    await tester.enterText(fields.at(1), '0.10');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(stored?.encode(), {
      'wallet': 'ccb',
      'threshold': 1501,
      'recharge': 10,
    });
    expect(payments.submitted, isEmpty);
    await tester.tap(find.byKey(const ValueKey('tab-首页')));
    await tester.pumpAndSettle();
    final quickPay = find.widgetWithText(FilledButton, '充值 ¥0.10');
    await tester.ensureVisible(quickPay);
    await tester.pumpAndSettle();
    await tester.tap(quickPay);
    await tester.pumpAndSettle();
    expect(payments.submitted, [(10, 'ccb')]);
  });
}
