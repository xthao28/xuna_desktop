import 'package:flutter/material.dart';

/// Official 7 XUNA Color Theme identifiers.
enum XunaColorThemeId {
  greenEdition('green_edition'),
  forestMint('forest_mint'),
  seafoam('seafoam'),
  lavenderDream('lavender_dream'),
  sunnyGold('sunny_gold'),
  skyBlue('sky_blue'),
  berryCandy('berry_candy');

  const XunaColorThemeId(this.id);
  final String id;

  static XunaColorThemeId fromId(String? raw) {
    final clean = (raw ?? '').trim().toLowerCase();
    for (final value in XunaColorThemeId.values) {
      if (value.id == clean || value.name.toLowerCase() == clean) {
        return value;
      }
    }
    return XunaColorThemeId.greenEdition;
  }
}

/// Configurable design data for a 5-role XUNA character palette (`highlight`, `hair`, `body`, `shadow`, `outline`).
@immutable
class XunaColorThemeData {
  const XunaColorThemeData({
    required this.id,
    required this.index,
    required this.code,
    required this.name,
    required this.nameVi,
    required this.tagline,
    required this.highlightHex,
    required this.hairHex,
    required this.bodyHex,
    required this.shadowHex,
    required this.outlineHex,
    this.isDefault = false,
    this.accentParticle = 'rays',
  });

  final String id;
  final int index;
  final String code;
  final String name;
  final String nameVi;
  final String tagline;
  final String highlightHex;
  final String hairHex;
  final String bodyHex;
  final String shadowHex;
  final String outlineHex;
  final bool isDefault;
  final String accentParticle;

  Color get highlight => parseHexColor(highlightHex);
  Color get hair => parseHexColor(hairHex);
  Color get body => parseHexColor(bodyHex);
  Color get shadow => parseHexColor(shadowHex);
  Color get outline => parseHexColor(outlineHex);

  List<Color> get swatches => <Color>[
        highlight,
        hair,
        body,
        shadow,
        outline,
      ];

  static Color parseHexColor(String hex) {
    final clean = hex.trim().replaceFirst('#', '');
    final value = int.tryParse(clean, radix: 16) ?? 0x1E1E1E;
    return Color(0xFF000000 | (value & 0xFFFFFF));
  }
}

/// Registry of XUNA's 7 official Color Themes.
abstract final class XunaColorThemes {
  static const XunaColorThemeData greenEdition = XunaColorThemeData(
    id: 'green_edition',
    index: 1,
    code: 'theme_01',
    name: 'Green Edition',
    nameVi: 'Xanh Nguyên Bản',
    tagline: 'Fresh · Vibrant · Original',
    highlightHex: '#EAF7C9',
    hairHex: '#B7E17D',
    bodyHex: '#8FB06B',
    shadowHex: '#5F7F52',
    outlineHex: '#1E1E1E',
    isDefault: true,
    accentParticle: 'rays',
  );

  static const XunaColorThemeData forestMint = XunaColorThemeData(
    id: 'forest_mint',
    index: 2,
    code: 'theme_02',
    name: 'Forest Mint',
    nameVi: 'Bạc Hà Rừng Xanh',
    tagline: 'Fresh · Calm · Natural',
    highlightHex: '#D5E3A2',
    hairHex: '#B1CA80',
    bodyHex: '#86A668',
    shadowHex: '#5F7D50',
    outlineHex: '#28322A',
    accentParticle: 'rays',
  );

  static const XunaColorThemeData seafoam = XunaColorThemeData(
    id: 'seafoam',
    index: 3,
    code: 'theme_03',
    name: 'Seafoam',
    nameVi: 'Bọt Biển Mơ Màng',
    tagline: 'Cool · Smart · Dreamy',
    highlightHex: '#C5E2DD',
    hairHex: '#91C9C0',
    bodyHex: '#6EACA8',
    shadowHex: '#496F77',
    outlineHex: '#263742',
    accentParticle: 'rays',
  );

  static const XunaColorThemeData lavenderDream = XunaColorThemeData(
    id: 'lavender_dream',
    index: 4,
    code: 'theme_04',
    name: 'Lavender Dream',
    nameVi: 'Oải Hương Huyền Bí',
    tagline: 'Calm · Mysterious · Cozy',
    highlightHex: '#DCD3EE',
    hairHex: '#C0B4DF',
    bodyHex: '#A191C7',
    shadowHex: '#6C5F90',
    outlineHex: '#342E46',
    accentParticle: 'sparkle',
  );

  static const XunaColorThemeData sunnyGold = XunaColorThemeData(
    id: 'sunny_gold',
    index: 5,
    code: 'theme_05',
    name: 'Sunny Gold',
    nameVi: 'Nắng Vàng Rực Rỡ',
    tagline: 'Warm · Cheerful · Energetic',
    highlightHex: '#F5DEB2',
    hairHex: '#F7CE8A',
    bodyHex: '#EDB264',
    shadowHex: '#CB8348',
    outlineHex: '#6D412F',
    accentParticle: 'rays',
  );

  static const XunaColorThemeData skyBlue = XunaColorThemeData(
    id: 'sky_blue',
    index: 6,
    code: 'theme_06',
    name: 'Sky Blue',
    nameVi: 'Mây Trời Bình Yên',
    tagline: 'Pure · Peaceful · Kind',
    highlightHex: '#B9D6F4',
    hairHex: '#94BDE9',
    bodyHex: '#71A0D6',
    shadowHex: '#4B6A95',
    outlineHex: '#2D3850',
    accentParticle: 'rays',
  );

  static const XunaColorThemeData berryCandy = XunaColorThemeData(
    id: 'berry_candy',
    index: 7,
    code: 'theme_07',
    name: 'Berry Candy',
    nameVi: 'Kẹo Dâu Ngọt Ngào',
    tagline: 'Sweet · Playful · Lovely',
    highlightHex: '#F9C1C6',
    hairHex: '#F1AAB0',
    bodyHex: '#D8858D',
    shadowHex: '#A1565E',
    outlineHex: '#4F2D35',
    accentParticle: 'heart',
  );

  static const List<XunaColorThemeData> builtIn = <XunaColorThemeData>[
    greenEdition,
    forestMint,
    seafoam,
    lavenderDream,
    sunnyGold,
    skyBlue,
    berryCandy,
  ];

  static XunaColorThemeData byId(String? id) {
    final clean = (id ?? '').trim().toLowerCase();
    for (final theme in builtIn) {
      if (theme.id == clean || theme.code == clean) {
        return theme;
      }
    }
    return greenEdition;
  }
}

