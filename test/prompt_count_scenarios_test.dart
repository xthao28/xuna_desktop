// UDC-17 S17.6 (P10): how many times the owner is asked to sign, per task,
// before (UDC-8 rules) and now (ADR-0015 D1/D2 as this host enforces them).
//
// "Now" is measured, not assumed: every step goes through
// `HostToolDispatcher.dispatch` unsigned; a step the host refuses with
// `approval_required` counts as one prompt and is then re-sent signed.
// "Before" applies the UDC-8 rule to the same steps: every `input.type_text`,
// every Enter/Return/Space, and a click on a commit-like name is R3. Both
// count the signature that starts the session.
//
// This runs on scripted windows on the development machine, not on a real
// Mac or PC. The macOS profile uses the roles the AX adapter normalises to
// (`textfield`, `searchfield`, `textarea`) and an exact focus; the Windows
// profile uses UIA's `edit` and no exact focus, which is what the Windows
// adapter reports today (UDC-17 §10), so drafts and Enter still prompt there.

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/features/computer_use/computer_use_session_manager.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'support/cu_gate_harness.dart';

class _Step {
  const _Step(this.tool, this.args, {this.focus});

  final String tool;
  final Map<String, Object?> args;

  /// Role of the focused element when the step runs (macOS profile).
  final String? focus;
}

class _Scenario {
  const _Scenario(this.id, this.title, this.nodes, this.steps);

  final String id;
  final String title;
  final List<Map<String, Object?>> nodes;
  final List<_Step> steps;
}

String _ref(int index) => '@s00000001:e$index';

Map<String, Object?> _n(String id, String role, String name) =>
    <String, Object?>{
      'id': id,
      'role': role,
      'name': name,
      'enabled': true,
      if (const <String>{'textfield', 'searchfield', 'textarea'}.contains(role))
        'editable': true,
    };

_Step _click(int i) =>
    _Step('input.click', <String, Object?>{'elementId': _ref(i)});
_Step _type(int i, String text, String focus) => _Step(
  'input.type_text',
  <String, Object?>{'elementId': _ref(i), 'text': text},
  focus: focus,
);
_Step _key(String combo, {String? focus}) => _Step(
  'input.key',
  <String, Object?>{'combo': combo, 'inForm': false},
  focus: focus,
);
const _Step _scroll = _Step('input.scroll', <String, Object?>{
  'direction': 'down',
  'amount': 3,
});

final List<_Scenario> _scenarios = <_Scenario>[
  // The ten UDC-8 tasks (backend `SCRIPTED_10_TASKS`), with the same steps.
  _Scenario(
    'task-01',
    'Mở file báo cáo mới nhất',
    <Map<String, Object?>>[_n('a', 'list_item', 'Q4_Report.pdf')],
    <_Step>[_click(1), _key('Enter', focus: 'list_item')],
  ),
  _Scenario(
    'task-02',
    'Điền lịch họp, dừng trước nút Tạo',
    <Map<String, Object?>>[
      _n('a', 'button', 'New Event'),
      _n('b', 'textfield', 'Event title'),
    ],
    <_Step>[_click(1), _type(2, 'Họp nhóm XUNA 15:00', 'textfield')],
  ),
  _Scenario(
    'task-03',
    'Tìm hàm trong VS Code',
    <Map<String, Object?>>[_n('a', 'searchfield', 'Find')],
    <_Step>[
      _key('Ctrl+F'),
      _type(1, 'ComputerUseSessionRunner', 'searchfield'),
    ],
  ),
  _Scenario(
    'task-04',
    'Cuộn tới mục Kiến trúc bảo mật',
    <Map<String, Object?>>[_n('a', 'heading', 'Security Architecture')],
    <_Step>[_scroll, _click(1)],
  ),
  _Scenario(
    'task-05',
    'Thêm mục vào ghi chú',
    <Map<String, Object?>>[_n('a', 'textarea', 'Note body')],
    <_Step>[_click(1), _type(1, '- Hoàn thành kiểm thử UDC-8', 'textarea')],
  ),
  _Scenario(
    'task-06',
    'Tìm playlist trong Spotify',
    <Map<String, Object?>>[_n('a', 'searchfield', 'Search')],
    <_Step>[_click(1), _type(1, 'Lo-Fi Coding', 'searchfield')],
  ),
  _Scenario(
    'task-07',
    'Lọc pull request đang mở',
    <Map<String, Object?>>[_n('a', 'button', 'Open PRs')],
    <_Step>[_click(1), _scroll],
  ),
  _Scenario(
    'task-08',
    'Chuyển trang trong trình đọc PDF',
    <Map<String, Object?>>[_n('a', 'link', 'Section 5')],
    <_Step>[_key('PageDown'), _click(1)],
  ),
  _Scenario(
    'task-09',
    'Xoá màn hình Máy tính',
    <Map<String, Object?>>[_n('a', 'button', 'Clear')],
    <_Step>[_click(1), _key('Escape')],
  ),
  _Scenario(
    'task-10',
    'Bấm Gửi báo cáo',
    <Map<String, Object?>>[_n('a', 'button', 'Gửi báo cáo')],
    <_Step>[_click(1)],
  ),
  // The three tasks estimated in UDC-17 §2.
  _Scenario(
    'plan-a',
    'Tìm người, soạn tin, gửi',
    <Map<String, Object?>>[
      _n('a', 'searchfield', 'Tìm kiếm'),
      _n('b', 'list_item', 'Lan'),
      _n('c', 'textarea', 'Soạn tin'),
      _n('d', 'button', 'Gửi'),
    ],
    <_Step>[
      _click(1),
      _type(1, 'Lan', 'searchfield'),
      _key('Enter', focus: 'searchfield'),
      _click(2),
      _type(3, 'Báo cáo xong rồi', 'textarea'),
      _click(4),
    ],
  ),
  _Scenario(
    'plan-b',
    'Tạo ghi chú, gõ nội dung, lưu',
    <Map<String, Object?>>[
      _n('a', 'button', 'Ghi chú mới'),
      _n('b', 'textarea', 'Nội dung'),
    ],
    <_Step>[
      _click(1),
      _type(2, 'Mua sữa', 'textarea'),
      _key('Cmd+S', focus: 'textarea'),
    ],
  ),
  _Scenario(
    'plan-c',
    'Tìm trên trang web, cuộn đọc',
    <Map<String, Object?>>[_n('a', 'searchfield', 'Tìm kiếm')],
    <_Step>[
      _click(1),
      _type(1, 'thời tiết Hà Nội', 'searchfield'),
      _key('Enter', focus: 'searchfield'),
      _scroll,
    ],
  ),
];

/// The UDC-8 rule (before ADR-0015) applied to [scenario]'s steps.
int _promptsBefore(_Scenario scenario) {
  var prompts = 1; // cu.session_start
  for (final step in scenario.steps) {
    switch (step.tool) {
      case 'input.type_text':
        prompts++;
      case 'input.key':
        final key = (step.args['combo'] as String).split('+').last;
        if (const <String>{
          'enter',
          'return',
          'space',
        }.contains(key.toLowerCase())) {
          prompts++;
        }
      case 'input.click':
        final ref = step.args['elementId'] as String;
        final index = int.parse(ref.substring(ref.lastIndexOf('e') + 1));
        if (isConsequentialElementName(
          scenario.nodes[index - 1]['name'] as String?,
        )) {
          prompts++;
        }
    }
  }
  return prompts;
}

/// Windows profile: UIA reports `edit` for text inputs and no exact focus.
Map<String, Object?> _asWindows(Map<String, Object?> node) {
  final role = node['role'] as String;
  if (!const <String>{'textfield', 'searchfield', 'textarea'}.contains(role)) {
    return node;
  }
  return <String, Object?>{...node, 'role': 'edit'};
}

int _seq = 0;
String _invocation() =>
    '6${(_seq++).toString().padLeft(7, '0')}-1111-4111-8111-111111111111';

/// Runs [scenario] through the real host gate and counts the prompts.
Future<int> _promptsNow(_Scenario scenario, {required bool windows}) async {
  final nodes = windows
      ? scenario.nodes.map(_asWindows).toList()
      : scenario.nodes;
  ActiveWindowObservation window(String? focus) => ActiveWindowObservation(
    appId: 'explorer',
    processName: 'explorer.exe',
    windowTitle: scenario.title,
    nodes: nodes,
    focusedRole: windows ? null : focus,
  );
  final h = await CuGateHarness.create(window: window(null));
  try {
    await h.startSessionAndInspect();
    var prompts = 1; // cu.session_start is always phone-signed (R3)
    for (final step in scenario.steps) {
      h.provider.currentWindow = window(step.focus);
      final unsigned = await h.dispatchMeta(
        step.tool,
        step.args,
        invocationId: _invocation(),
      );
      if (unsigned['xuna/status'] == 'ok') continue;
      expect(
        unsigned['xuna/errorCode'],
        'approval_required',
        reason: '${scenario.id} ${step.tool}',
      );
      prompts++;
      final signed = await h.dispatchMeta(
        step.tool,
        step.args,
        approval: h.signedApproval(step.args),
        invocationId: _invocation(),
      );
      expect(signed['xuna/status'], 'ok', reason: '${scenario.id} signed');
    }
    return prompts;
  } finally {
    await h.dispose();
  }
}

void main() {
  test('owner prompts per task, before and now (scripted windows)', () async {
    final rows = <String>[
      '| Kịch bản | Trước (UDC-8) | Nay, macOS | Nay, Windows |',
      '|---|---|---|---|',
    ];
    final before = <String, int>{};
    final mac = <String, int>{};
    final win = <String, int>{};
    for (final s in _scenarios) {
      before[s.id] = _promptsBefore(s);
      mac[s.id] = await _promptsNow(s, windows: false);
      win[s.id] = await _promptsNow(s, windows: true);
      rows.add(
        '| ${s.id} ${s.title} | ${before[s.id]} | ${mac[s.id]} | ${win[s.id]} |',
      );
    }
    int sum(Map<String, int> m) => m.values.fold(0, (a, b) => a + b);
    rows.add('| **Tổng** | ${sum(before)} | ${sum(mac)} | ${sum(win)} |');
    // ignore: avoid_print
    print(rows.join('\n'));

    // The new rules never ask more than the old ones.
    for (final s in _scenarios) {
      expect(mac[s.id]!, lessThanOrEqualTo(before[s.id]!), reason: s.id);
      expect(win[s.id]!, lessThanOrEqualTo(before[s.id]!), reason: s.id);
    }
    // Commits still need the owner: "Bấm Gửi báo cáo" and the message send.
    expect(mac['task-10'], 2);
    expect(mac['plan-a'], 2);
    // Enter outside a search field still needs the owner.
    expect(mac['task-01'], 2);
    // On macOS drafts and Enter in a search field no longer prompt.
    expect(mac['plan-a']!, lessThan(before['plan-a']!));
    expect(mac['plan-c'], 1);
  });
}
