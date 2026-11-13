import 'package:ubaa_domain/ubaa_domain.dart';

import '../../contracts/recovery.dart';
import '../../write/coordinator.dart';

final class ScopedCampusCardService implements CampusCardService {
  const ScopedCampusCardService(
    this.delegate,
    this.current,
    this.read,
    this.writer,
  );
  final CampusCardService delegate;
  final bool Function() current;
  final ServiceRead read;
  final WriteCoordinator writer;

  void _check() {
    if (!current()) {
      throw const UiError(
        code: UbaaErrorCode.operationConflict,
        title: '登录状态已变化',
        message: '请重新打开校园卡充值',
      );
    }
  }

  @override
  Future<int> balance() => read(RecoveryTarget.campusCard, () async {
    _check();
    final result = await delegate.balance();
    _check();
    return result;
  });

  @override
  Future<List<String>> wallets() => read(RecoveryTarget.campusCard, () async {
    _check();
    final result = await delegate.wallets();
    _check();
    return result;
  });

  @override
  Future<CampusCardPayment> recharge(int cents, String wallet) async {
    // 补齐目标路线和验证钱包发生在写入边界前。支付请求不参加读取恢复。
    final available = await wallets();
    if (!available.contains(wallet)) {
      throw const UiError(
        code: UbaaErrorCode.businessUnavailable,
        title: '钱包不可用',
        message: '选中的数币钱包已不可用，请重新选择',
      );
    }
    return writer.runConfirmedBatch(() async {
      _check();
      final outcome = await delegate.recharge(cents, wallet);
      if (!current()) {
        throw const UiError(
          code: UbaaErrorCode.outcomeUnknown,
          title: '请核对充值结果',
          message: '账号或连接已变化，请先在原账号的航财通交费记录核对',
        );
      }
      return outcome;
    });
  }
}
