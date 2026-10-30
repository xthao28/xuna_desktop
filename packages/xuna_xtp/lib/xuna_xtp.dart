/// Pure-Dart XUNA Tool Protocol (XTP) v1 library.
///
/// Implements the normative wire contract in `docs/architecture/XUNA_XTP_V1_CONTRACT.md`:
/// - Strict JSON-RPC 2.0 frame parsing, encoding, and size limits (`frames.dart`)
/// - Canonical JSON and `argsSha256` computation (`canonical_json.dart`)
/// - Host proof message (`xuna.host.proof.v1\0`), 6-digit SAS, and P-256 DER/raw helpers (`crypto.dart`)
/// - Tool descriptors, risk tiers, status codes, and MVP catalog (`schemas.dart`)
/// - Fail-closed `host-policy.json` evaluator and URL allowlist validator (`policy.dart`)
library;

export 'src/canonical_json.dart';
export 'src/crypto.dart';
export 'src/frames.dart';
export 'src/policy.dart';
export 'src/schemas.dart';
