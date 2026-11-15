import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

void main() {
  group('Wave B Browser Tools — Family & Descriptors', () {
    test('resolveToolFamilyForName maps all 7 web tools to ToolFamily.url', () {
      expect(resolveToolFamilyForName('web.navigate'), ToolFamily.url);
      expect(resolveToolFamilyForName('web.snapshot'), ToolFamily.url);
      expect(resolveToolFamilyForName('web.click'), ToolFamily.url);
      expect(resolveToolFamilyForName('web.fill'), ToolFamily.url);
      expect(resolveToolFamilyForName('web.select'), ToolFamily.url);
      expect(resolveToolFamilyForName('web.extract'), ToolFamily.url);
      expect(resolveToolFamilyForName('web.wait_for'), ToolFamily.url);
    });

    test('ToolDescriptor.validateToolName validates web tools against ToolFamily.url', () {
      ToolDescriptor.validateToolName('web.navigate', expectedFamily: ToolFamily.url);
      ToolDescriptor.validateToolName('web.snapshot', expectedFamily: ToolFamily.url);
      ToolDescriptor.validateToolName('web.click', expectedFamily: ToolFamily.url);
      ToolDescriptor.validateToolName('web.fill', expectedFamily: ToolFamily.url);
      ToolDescriptor.validateToolName('web.select', expectedFamily: ToolFamily.url);
      ToolDescriptor.validateToolName('web.extract', expectedFamily: ToolFamily.url);
      ToolDescriptor.validateToolName('web.wait_for', expectedFamily: ToolFamily.url);

      expect(
        () => ToolDescriptor.validateToolName('web.navigate', expectedFamily: ToolFamily.app),
        throwsFormatException,
      );
      expect(
        () => ToolDescriptor.validateToolName('web.snapshot', expectedFamily: ToolFamily.screen),
        throwsFormatException,
      );
    });

    test('buildBrowserToolCatalog builds exactly 7 tools with strict schemas and bounds', () {
      final catalog = buildBrowserToolCatalog();
      expect(catalog.length, 7);

      final names = catalog.map((t) => t.name).toSet();
      expect(
        names,
        containsAll(<String>[
          'web.navigate',
          'web.snapshot',
          'web.click',
          'web.fill',
          'web.select',
          'web.extract',
          'web.wait_for',
        ]),
      );

      for (final tool in catalog) {
        expect(tool.policy.family, ToolFamily.url);
        expect(tool.description.isNotEmpty, isTrue);
        expect(tool.description.length <= 240, isTrue);
        expect(tool.inputSchema['type'], 'object');
        expect(tool.inputSchema['additionalProperties'], isFalse);
        expect(tool.outputSchema['type'], 'object');
        expect(tool.outputSchema['additionalProperties'], isFalse);
      }

      // Check individual tool properties
      final navigate = catalog.firstWhere((t) => t.name == 'web.navigate');
      expect(navigate.policy.risk, RiskTier.r2);
      expect(navigate.policy.observes, isFalse);

      final snapshot = catalog.firstWhere((t) => t.name == 'web.snapshot');
      expect(snapshot.policy.risk, RiskTier.r1);
      expect(snapshot.policy.observes, isTrue);
      expect(snapshot.policy.idempotent, isTrue);

      final click = catalog.firstWhere((t) => t.name == 'web.click');
      expect(click.policy.risk, RiskTier.r2);

      final fill = catalog.firstWhere((t) => t.name == 'web.fill');
      expect(fill.policy.risk, RiskTier.r2);

      final select = catalog.firstWhere((t) => t.name == 'web.select');
      expect(select.policy.risk, RiskTier.r2);

      final extract = catalog.firstWhere((t) => t.name == 'web.extract');
      expect(extract.policy.risk, RiskTier.r1);
      expect(extract.policy.observes, isTrue);

      final waitFor = catalog.firstWhere((t) => t.name == 'web.wait_for');
      expect(waitFor.policy.risk, RiskTier.r1);
    });
  });

  group('Wave B Browser Tools — Argument Validation & SSRF Filters', () {
    final policy = HostPolicy(
      schemaVersion: 1,
      trustPreset: TrustPreset.standard,
      families: const <ToolFamily, FamilyPolicyDecision>{},
      apps: const <AllowedAppConfig>[],
      urlDomains: const <String>['example.com', 'shop.vietnam.vn'],
      workflows: const <WorkflowConfig>[],
      players: const <String>[],
    );
    final now = DateTime.utc(2026, 11, 15, 12, 0, 0);

    PolicyEvaluationResult eval(
      String name,
      Map<String, Object?> args, {
      bool allowPublicHttps = false,
    }) {
      return validateToolArguments(
        toolName: name,
        arguments: args,
        activePolicy: policy,
        now: now,
        isStopped: false,
        hostId: 'test-host',
        pinnedPhonePublicKeys: <Uint8List>[],
        isInApprovedCuSession: false,
        allowZeroConfigAppDiscovery: true,
        allowPublicHttpsDomains: allowPublicHttps,
        evaluateStep: ({
          required String toolName,
          required Map<String, Object?> arguments,
          ApprovalToken? approval,
          required bool isStopped,
          required DateTime nowUtc,
          String? hostId,
          required List<Uint8List> pinnedPhonePublicKeys,
          required bool isInApprovedCuSession,
          required bool allowZeroConfigAppDiscovery,
          bool allowPublicHttpsDomains = false,
        }) =>
            throw UnimplementedError(),
      );
    }

    test('web.navigate allows policy-approved HTTPS domain', () {
      final res = eval('web.navigate', <String, Object?>{
        'url': 'https://example.com/checkout',
        'timeoutMs': 15000,
      });
      expect(res.allowed, isTrue);
      expect(res.effectiveRisk, RiskTier.r2);
    });

    test('web.navigate allows public HTTPS when allowPublicHttps is true', () {
      final res = eval(
        'web.navigate',
        <String, Object?>{'url': 'https://github.com/xthao28/xuna_pet'},
        allowPublicHttps: true,
      );
      expect(res.allowed, isTrue);
      expect(res.effectiveRisk, RiskTier.r2);
    });

    test('web.navigate denies unlisted domain when allowPublicHttps is false', () {
      final res = eval(
        'web.navigate',
        <String, Object?>{'url': 'https://unlisted-site.org/page'},
        allowPublicHttps: false,
      );
      expect(res.allowed, isFalse);
      expect(res.status, XtpStatus.denied);
      expect(res.errorCode, 'domain_not_allowed');
    });

    test('web.navigate anti-SSRF rejects HTTP scheme', () {
      final res = eval(
        'web.navigate',
        <String, Object?>{'url': 'http://example.com'},
        allowPublicHttps: true,
      );
      expect(res.allowed, isFalse);
      expect(res.status, XtpStatus.invalidArgs);
      expect(res.errorCode, 'url_invalid');
    });

    test('web.navigate anti-SSRF rejects IPv4 literals and loopback', () {
      for (final badUrl in <String>[
        'https://127.0.0.1/admin',
        'https://10.0.0.1/secret',
        'https://192.168.1.1/router',
        'https://169.254.169.254/latest/meta-data/',
      ]) {
        final res = eval('web.navigate', <String, Object?>{'url': badUrl}, allowPublicHttps: true);
        expect(res.allowed, isFalse, reason: 'Must reject $badUrl');
        expect(res.errorCode, 'url_invalid');
      }
    });

    test('web.navigate anti-SSRF rejects IPv6 literals and localhost', () {
      for (final badUrl in <String>[
        'https://[::1]/api',
        'https://localhost:8080/dashboard',
        'https://myhost.local/index.html',
        'https://app.localhost/settings',
        'https://localhost.localdomain',
        'https://sub.localhost.localdomain',
        'https://metadata.google.internal',
        'https://instance-data.ec2.internal',
        'https://router.lan',
        'https://home.arpa',
        'https://device.localdomain',
        'https://１２７.０.０.１',
        'https://１６９.２５４.１６９.２５４',
        'https://sub.ｌｏｃａｌｈｏｓｔ',
        'https://127.0.0.0x1',
        'https://127.0.0.0x01',
        'https://0x7f.0.0.0x1',
        'https://169.254.169.0xfe',
        'https://10.0.0.0x1',
        'https://192.168.1.0x1',
        'https://127.0x1',
      ]) {
        final res = eval('web.navigate', <String, Object?>{'url': badUrl}, allowPublicHttps: true);
        expect(res.allowed, isFalse, reason: 'Must reject $badUrl');
        expect(res.errorCode, 'url_invalid');
      }
    });

    test('web.navigate anti-SSRF rejects userinfo credential smuggling', () {
      final res = eval(
        'web.navigate',
        <String, Object?>{'url': 'https://admin:password@example.com/login'},
        allowPublicHttps: true,
      );
      expect(res.allowed, isFalse);
      expect(res.errorCode, 'url_invalid');
    });

    test('web.navigate rejects null bytes, invalid timeouts, and extra keys', () {
      expect(
        eval('web.navigate', <String, Object?>{'url': 'https://example.com\x00/evil'}).errorCode,
        'schema_mismatch',
      );
      expect(
        eval('web.navigate', <String, Object?>{
          'url': 'https://example.com',
          'timeoutMs': 500, // below 1000ms minimum
        }).errorCode,
        'schema_mismatch',
      );
      expect(
        eval('web.navigate', <String, Object?>{
          'url': 'https://example.com',
          'extra': 'bad',
        }).errorCode,
        'schema_mismatch',
      );
    });

    test('web.snapshot validates compact and maxBytes bounds (max 6144)', () {
      final valid = eval('web.snapshot', <String, Object?>{
        'compact': true,
        'maxBytes': 4096,
      });
      expect(valid.allowed, isTrue);
      expect(valid.effectiveRisk, RiskTier.r1);

      // maxBytes > 6144 rejected
      final tooBig = eval('web.snapshot', <String, Object?>{
        'maxBytes': 6145,
      });
      expect(tooBig.allowed, isFalse);
      expect(tooBig.errorCode, 'schema_mismatch');

      // maxBytes < 100 rejected
      final tooSmall = eval('web.snapshot', <String, Object?>{
        'maxBytes': 99,
      });
      expect(tooSmall.allowed, isFalse);
      expect(tooSmall.errorCode, 'schema_mismatch');
    });

    test('web.click benign element is RiskTier.r2', () {
      for (final benign in <Map<String, String>>[
        {'ref': 'link-about-us', 'selector': 'a.about', 'targetText': 'Giới thiệu'},
        {'ref': 'theme_button', 'targetText': 'Toggle dark theme'},
        {'ref': 'guide_link', 'targetText': 'view the guide'},
        {'ref': 'weather_widget', 'targetText': 'Today weather'},
        {'ref': 'other_options_btn', 'targetText': 'other options'},
        {'ref': 'spin_wheel', 'targetText': 'spin'},
        {'ref': 'opinion_poll', 'targetText': 'give your opinion'},
        {'ref': 'cardigan_product', 'targetText': 'wool cardigan'},
        {'ref': 'wildcard_search', 'targetText': 'wildcard search'},
      ]) {
        final res = eval('web.click', benign);
        expect(res.allowed, isTrue);
        expect(res.effectiveRisk, RiskTier.r2, reason: 'Expected R2 for ${benign['ref']}');
      }
    });

    test('web.click consequential element elevates to RiskTier.r3', () {
      // Test English keywords
      final checkoutClick = eval('web.click', <String, Object?>{
        'ref': 'btn-checkout',
        'targetText': 'Proceed to Checkout',
      });
      expect(checkoutClick.allowed, isTrue);
      expect(checkoutClick.effectiveRisk, RiskTier.r3);

      final deleteClick = eval('web.click', <String, Object?>{
        'ref': 'action-delete',
        'targetText': 'Delete Account',
      });
      expect(deleteClick.allowed, isTrue);
      expect(deleteClick.effectiveRisk, RiskTier.r3);

      // Test camelCase identifier decomposition
      for (final camelRef in <String>['payNow', 'buyNow', 'submitOrder', 'deleteItem']) {
        final res = eval('web.click', <String, Object?>{'ref': camelRef});
        expect(res.allowed, isTrue);
        expect(res.effectiveRisk, RiskTier.r3, reason: 'Must elevate camelCase $camelRef to R3');
      }

      // Explicit Challenger 2 elevation checks: checkOut, checkout, check_out, DELETE_ITEM, placeOrder
      for (final targetRef in <String>[
        'checkOut',
        'checkout',
        'check_out',
        'DELETE_ITEM',
        'placeOrder',
      ]) {
        final res = eval('web.click', <String, Object?>{'ref': targetRef});
        expect(res.allowed, isTrue);
        expect(res.effectiveRisk, RiskTier.r3, reason: 'Must elevate $targetRef to R3');
      }

      // Test Vietnamese keywords
      final payClick = eval('web.click', <String, Object?>{
        'ref': 'btn-payment',
        'targetText': 'Xác nhận thanh toán',
      });
      expect(payClick.allowed, isTrue);
      expect(payClick.effectiveRisk, RiskTier.r3);

      final xoaClick = eval('web.click', <String, Object?>{
        'ref': 'btn-xoa',
        'targetText': 'Xóa dữ liệu',
      });
      expect(xoaClick.allowed, isTrue);
      expect(xoaClick.effectiveRisk, RiskTier.r3);

      for (final vnTerm in <String>[
        'hủy',
        'hủy bỏ',
        'hủy tài khoản',
        'gỡ bỏ',
        'nộp',
        'wire',
      ]) {
        final res = eval('web.click', <String, Object?>{'ref': 'btn', 'targetText': vnTerm});
        expect(res.allowed, isTrue);
        expect(res.effectiveRisk, RiskTier.r3, reason: 'Must elevate $vnTerm to R3');
      }
    });

    test('web.fill benign text is RiskTier.r2', () {
      final res = eval('web.fill', <String, Object?>{
        'ref': 'search-field',
        'value': 'áo khoác mùa đông',
        'targetText': 'Tìm kiếm sản phẩm',
      });
      expect(res.allowed, isTrue);
      expect(res.effectiveRisk, RiskTier.r2);
    });

    test('web.fill sensitive field elevates to RiskTier.r3', () {
      final pwFill = eval('web.fill', <String, Object?>{
        'ref': 'user-password-input',
        'value': 'SuperSecret123',
      });
      expect(pwFill.allowed, isTrue);
      expect(pwFill.effectiveRisk, RiskTier.r3);

      final cardFill = eval('web.fill', <String, Object?>{
        'ref': 'card-element',
        'value': '4111222233334444',
        'targetText': 'Số thẻ tín dụng',
      });
      expect(cardFill.allowed, isTrue);
      expect(cardFill.effectiveRisk, RiskTier.r3);

      final cvvFill = eval('web.fill', <String, Object?>{
        'ref': 'cvv-box',
        'value': '123',
        'selector': 'input[name=cvv]',
      });
      expect(cvvFill.allowed, isTrue);
      expect(cvvFill.effectiveRisk, RiskTier.r3);

      // Sensitive inputs in value elevate to R3 (payNow, secret password, DELETE_ITEM, checkOut, placeOrder)
      for (final sensitiveVal in <String>[
        'payNow',
        'secret password',
        'DELETE_ITEM',
        'checkOut',
        'placeOrder',
      ]) {
        final fillRes = eval('web.fill', <String, Object?>{
          'ref': 'input_field',
          'value': sensitiveVal,
        });
        expect(fillRes.allowed, isTrue);
        expect(fillRes.effectiveRisk, RiskTier.r3,
            reason: 'Must elevate web.fill with value=$sensitiveVal to R3');
      }
    });

    test('web.select validates required ref and value', () {
      final valid = eval('web.select', <String, Object?>{
        'ref': 'dropdown-country',
        'value': 'VN',
      });
      expect(valid.allowed, isTrue);
      expect(valid.effectiveRisk, RiskTier.r2);

      // Missing value rejected
      final missingVal = eval('web.select', <String, Object?>{
        'ref': 'dropdown-country',
      });
      expect(missingVal.allowed, isFalse);
      expect(missingVal.errorCode, 'schema_mismatch');
    });

    test('web.extract validates arguments and returns RiskTier.r1', () {
      final valid = eval('web.extract', <String, Object?>{
        'ref': 'title-1',
        'attribute': 'href',
      });
      expect(valid.allowed, isTrue);
      expect(valid.effectiveRisk, RiskTier.r1);

      // Extra property rejected
      final bad = eval('web.extract', <String, Object?>{
        'extraProp': 123,
      });
      expect(bad.allowed, isFalse);
      expect(bad.errorCode, 'schema_mismatch');
    });

    test('web.wait_for validates state enum, timeout range, and returns RiskTier.r1', () {
      final valid = eval('web.wait_for', <String, Object?>{
        'selector': '#finish-banner',
        'state': 'visible',
        'timeoutMs': 5000,
      });
      expect(valid.allowed, isTrue);
      expect(valid.effectiveRisk, RiskTier.r1);

      // Invalid state
      final badState = eval('web.wait_for', <String, Object?>{
        'state': 'destroyed',
      });
      expect(badState.allowed, isFalse);
      expect(badState.errorCode, 'schema_mismatch');

      // Invalid timeout (< 100 or > 30000)
      final badTimeout = eval('web.wait_for', <String, Object?>{
        'timeoutMs': 35000,
      });
      expect(badTimeout.allowed, isFalse);
      expect(badTimeout.errorCode, 'schema_mismatch');
    });
  });

  group('Wave B Browser Redaction & Byte Limiting', () {
    test('redactBrowserSnapshot masks sensitive API tokens and credentials', () {
      const rawSnapshot = '''
# ARIA Tree — Dashboard (https://example.com)
[e1] heading "Welcome"
[e2] textbox "API Key" value="sk-1234567890abcdef123456"
[e3] textbox "GitHub Token" value="ghp_1234567890abcdef123456"
[e4] button "Submit"
''';
      final result = redactBrowserSnapshot(rawSnapshot, maxBytes: 6144);
      expect(result.truncated, isFalse);
      expect(result.text, contains('[e2] textbox "API Key" value="[REDACTED]"'));
      expect(result.text, contains('[e3] textbox "GitHub Token" value="[REDACTED]"'));
      expect(result.text, isNot(contains('sk-1234567890abcdef123456')));
      expect(result.text, isNot(contains('ghp_1234567890abcdef123456')));
    });

    test('redactBrowserSnapshot truncates cleanly at maxBytes without breaking UTF-8', () {
      final largeText = 'XUNA Pixel Art Pet: Tiếng Việt có dấu rất đẹp! ' * 200;
      final result = redactBrowserSnapshot(largeText, maxBytes: 500);
      expect(result.truncated, isTrue);
      expect(result.byteCount <= 500, isTrue);
      expect(result.text.isNotEmpty, isTrue);
    });

    test('isConsequentialBrowserTarget detects passwords, cards, and payment keywords', () {
      expect(
        isConsequentialBrowserTarget(ref: 'input_passwd', value: 'secret'),
        isTrue,
      );
      expect(
        isConsequentialBrowserTarget(ref: 'box-1', targetText: 'Nhập mật khẩu'),
        isTrue,
      );
      expect(
        isConsequentialBrowserTarget(ref: 'elem-9', selector: '#credit-card-number'),
        isTrue,
      );
      expect(isConsequentialBrowserTarget(ref: 'checkOut'), isTrue);
      expect(isConsequentialBrowserTarget(ref: 'checkout'), isTrue);
      expect(isConsequentialBrowserTarget(ref: 'check_out'), isTrue);
      expect(isConsequentialBrowserTarget(ref: 'DELETE_ITEM'), isTrue);
      expect(isConsequentialBrowserTarget(ref: 'placeOrder'), isTrue);
      expect(isConsequentialBrowserTarget(ref: 'fld', value: 'payNow'), isTrue);
      expect(isConsequentialBrowserTarget(ref: 'fld', value: 'secret password'), isTrue);
      expect(
        isConsequentialBrowserTarget(ref: 'btn-normal', targetText: 'Xem thêm'),
        isFalse,
      );
    });
  });
}
