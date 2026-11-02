import 'package:flutter/material.dart';
import '../themes/app_colors.dart';

abstract class AppTextStyle {
  const AppTextStyle._();

  static const bodyFamily = 'BeVietnamPro';
  static const displayFamily = 'Anton';
  static const monoFamily = 'JetBrainsMono';

  static const _defaultFont = TextStyle(
    fontWeight: FontWeight.w400,
    color: AppColors.xunaInk,
    fontFamily: bodyFamily,
  );

  static const _display = TextStyle(
    fontWeight: FontWeight.w400,
    color: AppColors.xunaInk,
    fontFamily: displayFamily,
    height: 1,
  );

  static const _mono = TextStyle(
    fontWeight: FontWeight.w500,
    color: AppColors.xunaInk,
    fontFamily: monoFamily,
    height: 1.5,
  );

  static final display112 =
      _display.copyWith(fontSize: 112, height: 0.86, letterSpacing: -2);
  static final display62 =
      _display.copyWith(fontSize: 62, height: 1.25, letterSpacing: 0.3);
  static final display48 =
      _display.copyWith(fontSize: 48, height: 1.3, letterSpacing: 1.5);
  static final display36 = _display.copyWith(fontSize: 36, letterSpacing: 0.5);
  static final display30 = _display.copyWith(fontSize: 30, height: 1.1);
  static final display28 =
      _display.copyWith(fontSize: 28, height: 1.2, letterSpacing: 0.4);
  static final display22 = _display.copyWith(fontSize: 22, letterSpacing: 0.5);
  static final display19 =
      _display.copyWith(fontSize: 19, height: 1.1, letterSpacing: 0.3);
  static final display17 = _display.copyWith(fontSize: 17, letterSpacing: 0.3);

  static final mono9Bo =
      _mono.copyWith(fontSize: 9.5, fontWeight: FontWeight.w700);
  static final mono10Re = _mono.copyWith(fontSize: 10, letterSpacing: 0.8);
  static final mono10Bo = _mono.copyWith(
    fontSize: 10,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
  );
  static final mono11Re = _mono.copyWith(fontSize: 11, letterSpacing: 0.6);
  static final mono11Bo = _mono.copyWith(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.6,
  );
  static final mono12Bo = _mono.copyWith(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.4,
  );
  static final mono15Bo = _mono.copyWith(
    fontSize: 15,
    fontWeight: FontWeight.w700,
    letterSpacing: 1,
  );

  static final _font10 = _defaultFont.copyWith(fontSize: 10);
  static final _font12 = _defaultFont.copyWith(fontSize: 12);
  static final _font14 = _defaultFont.copyWith(fontSize: 14);
  static final _font16 = _defaultFont.copyWith(fontSize: 16);
  static final _font18 = _defaultFont.copyWith(fontSize: 18);
  static final _font20 = _defaultFont.copyWith(fontSize: 20);
  static final _font24 = _defaultFont.copyWith(fontSize: 24);
  static final _font32 = _defaultFont.copyWith(fontSize: 32);
  static final _font36 = _defaultFont.copyWith(fontSize: 36);

  static final font13Re = _defaultFont.copyWith(fontSize: 13, height: 1.45);
  static final font13Semi =
      _defaultFont.copyWith(fontSize: 13, fontWeight: FontWeight.w600);
  static final font13Bo =
      _defaultFont.copyWith(fontSize: 13, fontWeight: FontWeight.w700);
  static final font15Re = _defaultFont.copyWith(fontSize: 15, height: 1.5);
  static final font15Bo =
      _defaultFont.copyWith(fontSize: 15, fontWeight: FontWeight.w700);
  static final font16Body = _defaultFont.copyWith(fontSize: 16, height: 1.4);
  static final font17Re = _defaultFont.copyWith(fontSize: 17, height: 1.35);
  static final font17Ex = _defaultFont.copyWith(
    fontSize: 17,
    fontWeight: FontWeight.w800,
    height: 1.25,
    letterSpacing: -0.3,
  );
  static final font19Re = _defaultFont.copyWith(fontSize: 19, height: 1.35);

  static final font10Re = _font10.copyWith(fontWeight: FontWeight.w400);
  static final font10Semi = _font10.copyWith(fontWeight: FontWeight.w600);
  static final font10Bo = _font10.copyWith(fontWeight: FontWeight.w700);
  static final font10Ex = _font10.copyWith(fontWeight: FontWeight.w800);

  static final font12Re = _font12.copyWith(
    fontWeight: FontWeight.w400,
    height: 1.4,
  );
  static final font12Semi = _font12.copyWith(fontWeight: FontWeight.w600);
  static final font12Bo = _font12.copyWith(fontWeight: FontWeight.w700);
  static final font12Ex = _font12.copyWith(fontWeight: FontWeight.w800);

  static final font14Re = _font14.copyWith(
    fontWeight: FontWeight.w400,
    height: 1.45,
  );
  static final font14Semi = _font14.copyWith(fontWeight: FontWeight.w600);
  static final font14Bo = _font14.copyWith(fontWeight: FontWeight.w700);
  static final font14Ex = _font14.copyWith(fontWeight: FontWeight.w800);

  static final font16Re = _font16.copyWith(fontWeight: FontWeight.w400);
  static final font16Semi = _font16.copyWith(fontWeight: FontWeight.w600);
  static final font16Bo = _font16.copyWith(fontWeight: FontWeight.w700);
  static final font16Ex = _font16.copyWith(fontWeight: FontWeight.w800);

  static final font18Re = _font18.copyWith(fontWeight: FontWeight.w400);
  static final font18Semi = _font18.copyWith(fontWeight: FontWeight.w600);
  static final font18Bo = _font18.copyWith(fontWeight: FontWeight.w700);
  static final font18Ex = _font18.copyWith(fontWeight: FontWeight.w800);

  static final font20Re = _font20.copyWith(fontWeight: FontWeight.w400);
  static final font20Semi = _font20.copyWith(fontWeight: FontWeight.w600);
  static final font20Bo = _font20.copyWith(fontWeight: FontWeight.w700);
  static final font20Ex = _font20.copyWith(fontWeight: FontWeight.w800);

  static final font24Re = _font24.copyWith(fontWeight: FontWeight.w400);
  static final font24Semi = _font24.copyWith(fontWeight: FontWeight.w600);
  static final font24Bo = _font24.copyWith(fontWeight: FontWeight.w700);
  static final font24Ex = _font24.copyWith(fontWeight: FontWeight.w800);

  static final font32Re = _font32.copyWith(fontWeight: FontWeight.w400);
  static final font32Semi = _font32.copyWith(fontWeight: FontWeight.w600);
  static final font32Bo = _font32.copyWith(fontWeight: FontWeight.w700);
  static final font32Ex = _font32.copyWith(fontWeight: FontWeight.w800);

  static final font36Re = _font36.copyWith(fontWeight: FontWeight.w400);
  static final font36Semi = _font36.copyWith(fontWeight: FontWeight.w600);
  static final font36Bo = _font36.copyWith(fontWeight: FontWeight.w700);
  static final font36Ex = _font36.copyWith(fontWeight: FontWeight.w800);
}

