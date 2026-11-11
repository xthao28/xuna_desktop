# XUNA desktop — coding rules

> **Mandatory before writing or changing any code in this repository.** Applies to every coding agent (Claude Code, Codex, Cursor, Copilot, Antigravity) and engineer.
>
> - Product intent, approved decisions and session scope: the parent repository's [AGENTS.md](../AGENTS.md) (canonical), then [PROCESS.md](../PROCESS.md), [UDC-3-desktop-agent.md](../docs/roadmap/device-control/UDC-3-desktop-agent.md) and [XUNA_XTP_V1_CONTRACT.md](../docs/architecture/XUNA_XTP_V1_CONTRACT.md). Relative links assume the `xuna_pet` superproject checkout.
> - How desktop code is written: **this file**.
> - If a request conflicts with either, stop and ask the owner. Changing these rules requires owner approval.
>
> Status: created 2026-10-30 (UDC-3 S3.1). Architecture: **Clean Architecture, feature-first, built on Flutter 3.32.8 (`fvm`) + GetX + pure-Dart `packages/xuna_xtp`**.

## 0. Workflow when asked to write a feature

1. Read the parent [AGENTS.md](../AGENTS.md), [XUNA_XTP_V1_CONTRACT.md](../docs/architecture/XUNA_XTP_V1_CONTRACT.md), [UDC-3-desktop-agent.md](../docs/roadmap/device-control/UDC-3-desktop-agent.md) and this file.
2. Confirm the feature belongs to the requested session/milestone. Do not build later sessions speculatively.
3. Before coding, tell the owner in Vietnamese: purpose, scope, layers/files affected, and whether a Windows PC or Mac run is needed.
4. Implement bottom-up: **`packages/xuna_xtp` (pure Dart) → `lib/features/*/domain` → `data` / `services` → `presentation` → native `xuna/host` MethodChannel → tests**.
5. Run the checks in §7 and walk through the Definition of Done (§8).
6. Report in Vietnamese: files changed, commands and results, what was **not** run, risks, next step. Commit only when asked.

## Honest code (mandatory, owner-approved 2026-11-05)

Full rules, incidents and review scans: parent [docs/architecture/XUNA_HONEST_CODE_RULES.md](../docs/architecture/XUNA_HONEST_CODE_RULES.md). Core rules:

- **H1 Real success only.** Return `ok` only after the real effect happened or the real system accepted it. If the transport, bridge, driver, permission or platform support is missing, fail closed: return `unsupported` / `needs_permission` / `failed` with a stable `errorCode` and a short `message`. Never update in-memory state to fake the outcome.
- **H2 No fabricated data.** No sample, canned or default-looking data (UI trees, HTML, counts, battery %, screenshots) on any production or tool path. Demo data only behind an explicit, labelled demo/simulator switch that the model's tool path cannot reach.
- **H3 Never guess targets.** A missing or ambiguous `refId`, host, file or entity returns an error with bounded valid candidates. No "first element", no magic `'ui_1'`.
- **H4 Errors travel end to end.** Native → channel → handler → XTP (`xuna/status`, `xuna/errorCode`, `message`) → backend → the model's tool result. No `catch`/`except` that turns failure into success. Backend guidance goes in `hint`, never inside host data.
- **H5 No app or phrase hard-coding in generic layers.** Prompts, catalog, agent loop and routing hold no app names, element IDs or keyword-intent tables. Producers declare capabilities (e.g. `xuna/policy.idempotent`) and consumers read them. App-specific fast paths stay isolated in host adapters.
- **H6 Names and docs match behaviour.** No unmeasured "native/0.1s/AI/real-time/verified" claims. Docstrings describe current behaviour, and a manifest advertises only what is implemented.
- **H7 Tests can fail.** Assert behaviour and end state, include the fail-closed case, no placeholder tests, no weakened assertions. Production defaults are never success-reporting fakes.
- **H8 Honest reports.** State what was run and what was not (simulator, real device, board, real model). Never claim unrun validation. Keep the diff to the task's files.

## 1. Repository layout

```text
xuna_desktop/
├── AGENTS.md                  # This file
├── .fvmrc                     # Flutter 3.32.8 (D14)
├── pubspec.yaml
├── packages/xuna_xtp/         # Pure Dart: XTP v1 frames, schemas, canonical JSON, SAS, proof message, policy evaluator
│   ├── lib/
│   └── test/                  # Uses byte-identical copies of backend/tests/fixtures/xtp/
├── lib/
│   ├── main.dart              # Tray-only app start, single-instance guard
│   ├── core/                  # Config paths, content-free logging, errors, DI (GetX)
│   └── features/
│       ├── enrollment/        # QR + 6-digit SAS screen, local state (hostId)
│       ├── session/           # WSS client, handshake, reconnect with backoff (1,2,4…60 s + jitter), heartbeat
│       ├── policy/            # host-policy.json load/validate (fail-closed), settings UI
│       ├── tools/             # Registry, dispatcher (deadline, cancel), one class per tool
│       ├── audit/             # Rotating JSONL, 30 days, viewer
│       ├── stop/              # Global hotkey, tray "Dừng XUNA", suspended state
│       └── permissions/       # OS permission status + onboarding screens
├── macos/Runner/              # Swift providers + XunaHostPlugin.swift
├── windows/runner/            # C++ providers + xuna_host_plugin.cpp
└── test/
```

## 2. Architecture and layering rules

- **`packages/xuna_xtp` is 100% pure Dart:** no `package:flutter/*`, no `dart:io` socket/file I/O, no platform plugins. It owns XTP v1 frame parsing/encoding, schema validation, canonical JSON (`argsSha256`), `host_proof_message`, 6-digit SAS computation, DER ↔ raw `r || s` P-256 signature conversion, URL validation and fail-closed `host-policy.json` evaluation.
- **Native boundary (`xuna/host` MethodChannel):** all OS-specific operations (CNG / Keychain P-256 keys, GSMTC / CoreAudio media & volume, `ShellExecuteExW` / `NSWorkspace` app & URL launch, `.lnk` / `shortcuts` workflows, OS permission checks) live strictly behind the single `xuna/host` MethodChannel table defined in `UDC-3-desktop-agent.md` §5.6.3 with a 10 s native timeout per call.
- **Clean feature boundaries:** domain models and tool dispatch logic never import Flutter widgets or native channel details directly; inject provider interfaces so unit tests run deterministically with fake providers.

## 3. Hard security invariants (ADR-0012, ADR-0013, UDC-3)

1. **No arbitrary code execution:** never expose or implement `shell.*`, `powershell.*`, `osascript.*`, `eval.*`, `script.*`, or arbitrary command-line flags. Every tool in `FORBIDDEN_TOOLS` is rejected at manifest construction and dispatch.
2. **Fail-closed local policy (`host-policy.json`):**
   - Windows: `%APPDATA%\XUNA\host-policy.json` (owner-only ACL).
   - macOS: `~/Library/Application Support/XUNA/host-policy.json` (`0600`).
   - If the policy file is missing, unreadable or invalid JSON/schema, **every tool except `host.status` returns `xuna/status = "denied"`** (`errorCode = "policy_invalid"`) and the tray shows `"Cấu hình lỗi"`.
   - An app or workflow's risk tier in `host-policy.json` may be raised by the owner above the tool default (`app.launch` default `R2`), never lowered below it.
3. **Strict URL validation (`url.open` & `cu.session_start`):**
   - `https` scheme only (case-insensitive); reject `http`, `file`, `javascript`, custom schemes (`invalid_args` / `url_invalid`).
   - No `userinfo` (`user:pass@`).
   - Convert IDN hostnames to ASCII punycode before matching.
   - Reject IPv4 literals, IPv6 literals, `localhost`, `.local`, `.localhost`, single-label hosts and numeric TLDs.
   - Direct `url.open` and `cu.session_start` invocations dispatched by `HostToolDispatcher` (`allowPublicHttpsDomains: true`, owner-approved 2026-11-11) permit any valid public `https://` domain because every invocation requires explicit owner R2/R3 approval on the phone bound to `argsSha256` (and inside a computer-use session, active browser tabs remain restricted to the session's approved `domains`). Composite `workflow.batch_steps` sub-steps continue to require membership in `host-policy.json` `urlDomains`; otherwise return `denied` (`domain_not_allowed`).
4. **R2+ approval binding:** any tool invocation with effective risk `>= R2` requires a non-expired `_meta["xuna/approval"]` whose `argsSha256` equals `sha256(canonical_json(arguments))`. On mismatch, refuse with `xuna/status = "denied"` and `errorCode = "approval_mismatch"`.
5. **Emergency stop (`xuna/stop` / global hotkey):** immediately cancels in-flight invocations and suspends new `R2+` tool calls with `xuna/status = "denied"` (`errorCode = "stopped"`) until explicitly resumed by the owner from the tray.
6. **Zero content in logs and audit:** neither application logs nor the local rotating audit JSONL (`{ts, invocationId, tool, status, durationMs}`) may ever record tool arguments, URLs, media titles, window titles or file paths.
7. **User-session process only:** the Desktop Agent runs as an ordinary user-session tray application (`HKCU Run` on Windows, Login Item with `LSUIElement = true` on macOS). It **never** runs elevated (Admin/root) and is **never** installed as a Windows Service (`Session 0`).

## 4. Approved dependencies (UDC-3 §5.6.2, owner-approved 2026-10-30)

- App (`pubspec.yaml`): `tray_manager`, `window_manager`, `launch_at_startup`, `hotkey_manager`, `web_socket_channel`, `qr_flutter`, `path_provider`, `get`, `crypto`, `xuna_xtp` (path).
- `packages/xuna_xtp`: `crypto` (SHA-256), `pointycastle` (dev/test software P-256 golden-vector verification).
- Do not add any other package without explicit owner approval.

## 5. Contract fixtures rule

`packages/xuna_xtp/test/fixtures/xtp/` holds byte-identical copies of `backend/tests/fixtures/xtp/` (`golden_vectors.json` and `sample_frames.json`). Any change to the wire contract must update `docs/architecture/XUNA_XTP_V1_CONTRACT.md` and both fixture directories in the same milestone.

## 6. Code style

- Project imports use `package:xuna_desktop/…` or `package:xuna_xtp/…`.
- Prefer `const` and `final`; exhaustive `switch` on enums without `default`.
- English identifiers and technical comments; Vietnamese user-facing copy in tray/dialogs.
- Never use `print`; use the content-free logger.

## 7. Toolchain and checks

- Flutter **3.32.8** via fvm (`.fvmrc`, decision D14).
- For `packages/xuna_xtp`:
  ```sh
  cd packages/xuna_xtp
  fvm dart pub get
  fvm dart format --output=none --set-exit-if-changed .
  fvm dart analyze --fatal-infos
  fvm dart test --reporter expanded
  ```
- For the desktop app (from S3.4 onward):
  ```sh
  fvm flutter pub get
  fvm dart format --output=none --set-exit-if-changed lib test
  fvm flutter analyze
  fvm flutter test --reporter expanded
  ```

## 8. Definition of Done

- [ ] Scope matches the requested session; nothing from later sessions.
- [ ] `packages/xuna_xtp` stays pure Dart; fixtures byte-match `backend/tests/fixtures/xtp/`.
- [ ] Hard security invariants (§3) enforced and unit-tested (forbidden tools, fail-closed policy, URL validation, approval hash binding, e-stop, content-free logs).
- [ ] Honest-code rules H1–H8 respected: no fake success, no fabricated data, no guessed targets, errors propagate, no app or phrase hard-coding in generic layers, tests include the fail-closed case.
- [ ] Analyzer reports 0 issues; all tests pass.
- [ ] Report in Vietnamese lists files changed, commands run, what was not run, and next steps.

