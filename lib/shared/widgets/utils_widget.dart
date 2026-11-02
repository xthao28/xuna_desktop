import 'package:flutter/cupertino.dart';
import '../constants/const_src.dart';
import '../themes/app_colors.dart';

class UtilWidget {
  const UtilWidget._();

  static Widget buildLoading({Color? colorIcon}) {
    return CupertinoActivityIndicator(
      color: colorIcon ?? AppColors.xunaInk,
    );
  }

  static const Widget shrink = SizedBox.shrink();
  static const Widget sizedBox4 = SizedBox(height: 4);
  static const Widget sizedBox6 = SizedBox(height: 6);
  static const Widget sizedBox8 = SizedBox(height: 8);
  static const Widget sizedBox10 = SizedBox(height: 10);
  static const Widget sizedBox12 = SizedBox(height: 12);
  static const Widget sizedBox14 = SizedBox(height: 14);
  static const Widget sizedBox16 = SizedBox(height: 16);
  static const Widget sizedBox20 = SizedBox(height: 20);
  static const Widget sizedBox24 = SizedBox(height: 24);
  static const Widget sizedBoxWidth6 = SizedBox(width: 6);
  static const Widget sizedBoxWidth8 = SizedBox(width: 8);
  static const Widget sizedBoxWidth10 = SizedBox(width: 10);
  static const Widget sizedBoxWidth12 = SizedBox(width: 12);
  static const Widget sizedBoxWidth16 = SizedBox(width: 16);
  static const Widget sizedBoxWidth20 = SizedBox(width: 20);

  static Widget buildCardBase(
    Widget child, {
    Color? colorBorder,
    Color? backgroundColor,
    double? radius,
    EdgeInsetsGeometry? padding,
  }) =>
      Container(
        padding: padding,
        decoration: BoxDecoration(
          color: backgroundColor ?? AppColors.xunaCard,
          borderRadius:
              BorderRadius.all(Radius.circular(radius ?? AppDimens.radius8)),
          border: Border.all(
            color: colorBorder ?? AppColors.xunaInk,
            width: AppDimens.strokeThin,
          ),
        ),
        child: child,
      );
}

