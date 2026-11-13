enum CampusCardPayment { paid, syncing }

abstract interface class CampusCardService {
  Future<int> balance();
  Future<List<String>> wallets();
  Future<CampusCardPayment> recharge(int cents, String wallet);
}

abstract interface class CampusCardProvider {
  CampusCardService get campusCard;
}

final class CampusCardSettings {
  const CampusCardSettings({
    required this.wallet,
    required this.thresholdCents,
    required this.rechargeCents,
  });

  final String wallet;
  final int thresholdCents, rechargeCents;

  bool promptsFor(int? balanceCents) =>
      balanceCents != null && balanceCents < thresholdCents;

  static CampusCardSettings decode(Object? value) {
    if (value
        case {
          'wallet': final String wallet,
          'threshold': final int threshold,
          'recharge': final int recharge,
        }
        when wallet.isNotEmpty &&
            threshold >= 0 &&
            threshold <= 0xffffffff &&
            recharge > 0 &&
            recharge <= 0xffffffff) {
      return CampusCardSettings(
        wallet: wallet,
        thresholdCents: threshold,
        rechargeCents: recharge,
      );
    }
    throw const FormatException('校园卡充值设置无效');
  }

  Map<String, Object> encode() => {
    'wallet': wallet,
    'threshold': thresholdCents,
    'recharge': rechargeCents,
  };
}

int? campusCardCents(String input) {
  final match = RegExp(
    r'^([0-9]{1,8})(?:\.([0-9]{1,2}))?$',
  ).firstMatch(input.trim());
  if (match == null) return null;
  final cents =
      int.parse(match[1]!) * 100 + int.parse((match[2] ?? '').padRight(2, '0'));
  return cents <= 0xffffffff ? cents : null;
}

String campusCardYuan(int cents) =>
    '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';

String campusCardWalletName(String code) => switch (code) {
  'icbc' => '中国工商银行钱包',
  'abc' => '中国农业银行钱包',
  'boc' => '中国银行钱包',
  'ccb' => '中国建设银行钱包',
  'psbc' => '中国邮政储蓄银行钱包',
  'comm' => '交通银行钱包',
  'mybank' => '网商银行钱包',
  'cmb' => '招商银行钱包',
  'webank' => '微众银行钱包',
  _ => '数币钱包（$code）',
};
