import 'package:ubaa_bindings/ubaa_bindings.dart';
import 'package:ubaa_domain/ubaa_domain.dart';

import 'context.dart';
import 'support/mapping.dart';

final class BridgeCampusCardService implements CampusCardService {
  const BridgeCampusCardService(this.context);
  final BridgeContext context;

  @override
  Future<int> balance() async {
    try {
      return await context.client.campusCardBalance();
    } on BridgeError catch (error) {
      throw bridgeMapError(error);
    }
  }

  @override
  Future<List<String>> wallets() async {
    try {
      return await context.client.campusCardWallets();
    } on BridgeError catch (error) {
      throw bridgeMapError(error);
    }
  }

  @override
  Future<CampusCardPayment> recharge(int cents, String wallet) async {
    try {
      return switch (await context.client.campusCardRecharge(
        cents: cents,
        wallet: wallet,
      )) {
        BridgeCampusCardPayment.paid => CampusCardPayment.paid,
        BridgeCampusCardPayment.syncing => CampusCardPayment.syncing,
      };
    } on BridgeError catch (error) {
      throw UiError(
        code: bridgeMapError(error).code,
        title: '校园卡充值',
        message: error.message,
      );
    }
  }
}
