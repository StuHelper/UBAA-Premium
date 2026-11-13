import 'package:flutter/material.dart';
import 'package:ubaa_domain/ubaa_domain.dart';

/// 保留已访问的页面，只有当前页面可以播放动画和显示提示。
Widget buildFeatureStack({
  required int generation,
  required FeatureId? active,
  required List<FeatureId> pages,
  required Widget tab,
  required Widget Function(FeatureId) buildPage,
}) => IndexedStack(
  key: ValueKey<int>(generation),
  index: active == null ? 0 : pages.indexOf(active) + 1,
  children: <Widget>[
    TickerMode(enabled: active == null, child: tab),
    for (final feature in pages)
      TickerMode(
        key: ValueKey<FeatureId>(feature),
        enabled: active == feature,
        child: TooltipVisibility(
          visible: active == feature,
          child: buildPage(feature),
        ),
      ),
  ],
);
