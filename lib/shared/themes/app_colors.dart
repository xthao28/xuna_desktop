import 'package:flutter/material.dart';
export 'xuna_color_themes.dart';

abstract final class AppColors {
  // XUNA design system (Claude Design "XUNA App", 2026-10-14): ink outlines,
  // warm paper surfaces, lime accent and lilac room tones.
  static const Color xunaInk = Color(0xFF151515);
  static const Color xunaPaper = Color(0xFFF7F2E4);
  static const Color xunaCard = Color(0xFFFBF7EC);
  static const Color xunaCardPressed = Color(0xFFEFE8D6);
  static const Color xunaLime = Color(0xFFD6F43F);
  static const Color xunaLilac = Color(0xFFC4A9F6);
  static const Color xunaLilacSoft = Color(0xFFE6DAFB);
  static const Color xunaLilacDeep = Color(0xFFA98BEA);
  static const Color xunaRoom = Color(0xFFB79BEE);
  static const Color xunaSparkle = Color(0xFF2B55FF);
  static const Color xunaHeart = Color(0xFFFF6FA8);
  static const Color xunaInkMuted = Color(0xFF4A4842);
  static const Color xunaInkSoft = Color(0xFF3A3833);
  static const Color xunaInkDisabled = Color(0xFF6D6A63);
  static const Color xunaScrim = Color(0x6B151515);
  static const Color xunaBoard = Color(0xFF232323);
  static const Color xunaBoardScreen = Color(0xFF0D0D0D);
  static const Color xunaBoardButton = Color(0xFF888888);
  static const Color xunaOnline = Color(0xFF9BE22E);
  static const Color xunaConnecting = Color(0xFFFFD23F);
  static const Color xunaOffline = Color(0xFFB8B3A7);

  static const Color colorTransparent = Colors.transparent;
  static const Color colorBlack = xunaInk;
  static const Color colorWhite = xunaCard;
}

