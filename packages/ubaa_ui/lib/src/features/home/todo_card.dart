import 'package:flutter/material.dart';
import 'package:ubaa_domain/ubaa_domain.dart';
import '../../common/tag.dart';
import '../../shared/feature_icons.dart' show uiFeatureIcon;
import '../../theme.dart';

/// 首页待办和加载提示使用的来源短名。
String uiHomeFeatureLabel(FeatureId feature) => switch (feature) {
  FeatureId.exam => '考试',
  FeatureId.bykc => '博雅',
  FeatureId.spoc => 'SPOC',
  FeatureId.judge => '希冀',
  FeatureId.cgyy => '研讨室',
  FeatureId.signin => '签到',
  FeatureId.ygdk => '阳光打卡',
  _ => feature.title,
};

/// 首页待办卡片：来源标签与课程等补充信息同处一行，标题单独占行。
class HomeTodoCard extends StatelessWidget {
  const HomeTodoCard({
    super.key,
    required this.item,
    required this.now,
    required this.onTap,
    this.onSignin,
    this.onRefreshSignin,
    this.signing = false,
    this.signinUncertain = false,
    this.moreCount = 0,
  });

  /// 同一课程被折叠的其余远期待办数量。
  final int moreCount;
  final HomeTodo item;
  final DateTime now;
  final VoidCallback onTap;
  final Future<void> Function()? onSignin, onRefreshSignin;
  final bool signing, signinUncertain;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = item.feature == FeatureId.signin && signing
        ? '签到处理中'
        : signinUncertain
        ? '结果未确认'
        : item.statusLabel;
    final subtitle = item.subtitle.trim();
    final remaining = uiTodoRemaining(item.deadline, now);
    // 三天内截止与数据层标记的“临近”同样用警示色。
    final urgent =
        item.soon ||
        (item.deadline != null &&
            item.deadline!.difference(now) < const Duration(days: 3));
    return HomeTodoCardFrame(
      onTap: item.feature == FeatureId.signin
          ? (signing ? null : onSignin ?? onRefreshSignin)
          : item.navigation == null
          ? null
          : onTap,
      title: item.title,
      metadata: Row(
        children: [
          UiTag(
            uiHomeFeatureLabel(item.feature),
            icon: uiFeatureIcon(item.feature),
            tone: UiTagTone.primary,
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(width: 8),
            Flexible(
              // 不截断：窄屏大字时课程名或地点换行保留全文。
              child: Text(
                subtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          if (moreCount > 0) ...[
            const SizedBox(width: 6),
            UiTag('另有 $moreCount 项'),
          ],
          // “待××”与时间信息重复，不显示。
          if (!status.startsWith('待')) ...[
            const SizedBox(width: 6),
            UiTag(status),
          ],
        ],
      ),
      detail: Text.rich(
        TextSpan(
          text: item.timeLabel,
          children: [
            if (remaining != null)
              TextSpan(
                text: ' · $remaining',
                style: TextStyle(
                  color: urgent ? null : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w400,
                ),
              ),
          ],
        ),
        style: theme.textTheme.labelLarge?.copyWith(
          color: urgent
              ? UbaaTheme.warning(theme.colorScheme)
              : theme.colorScheme.onPrimaryContainer,
        ),
      ),
      trailing: item.feature == FeatureId.signin
          ? Padding(
              padding: const EdgeInsets.only(left: 8),
              child: FilledButton(
                onPressed: signing ? null : onSignin ?? onRefreshSignin,
                child: Text(
                  signing
                      ? '处理中…'
                      : onSignin != null
                      ? '签到'
                      : '刷新状态',
                ),
              ),
            )
          : item.navigation != null
          ? Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant)
          : null,
    );
  }
}

/// 待办网格内的共用卡片布局，也可显示没有日程的提醒。
class HomeTodoCardFrame extends StatelessWidget {
  const HomeTodoCardFrame({
    super.key,
    required this.title,
    required this.metadata,
    required this.detail,
    this.trailing,
    this.onTap,
  });

  final String title;
  final Widget metadata, detail;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      metadata,
                      const SizedBox(height: 4),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                    ],
                  ),
                  detail,
                ],
              ),
            ),
            if (trailing case final action?) Center(child: action),
          ],
        ),
      ),
    ),
  );
}

/// 截止时间的相对说法（“还有 3 天”）；没有截止时间或已过期时为空。
String? uiTodoRemaining(DateTime? deadline, DateTime now) {
  if (deadline == null) return null;
  final left = deadline.difference(now);
  if (left.isNegative) return null;
  if (left.inDays >= 1) return '还有 ${left.inDays} 天';
  if (left.inHours >= 1) return '还有 ${left.inHours} 小时';
  return '不到 1 小时';
}
