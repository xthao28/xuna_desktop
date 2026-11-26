import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/exec/draft_workspace_manager.dart';
import 'package:xuna_desktop/features/exec/exec_host_environment.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// `draft.*` tool handlers (`ADR-0019` §3–§4 / `W4-M3`, `W4-M4`).
const List<HostToolHandler> defaultDraftToolHandlers = <HostToolHandler>[
  DraftCreateTool(),
  DraftManifestTool(),
  DraftDiscardTool(),
  DraftApplyTool(),
];

DraftWorkspaceManager _manager(ToolExecutionContext context) {
  final mgr = context.draftWorkspaceManager;
  if (mgr == null) {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'platform_unsupported',
    );
  }
  return mgr;
}

class DraftCreateTool extends HostToolHandler {
  const DraftCreateTool();

  @override
  String get name => 'draft.create';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final args = context.arguments;
    final session = await _manager(context).createDraft(
      rawWorkspacePath: args['workspacePath']! as String,
      requestedAlias: args['workspaceAlias'] as String?,
      shellControl: context.policy?.shellControl,
      homeDirectory: context.execFsContext?.homeDirectory ?? hostHomeDirectory(),
      nowUtc: context.nowUtc,
    );
    return ToolHandlerOutput(
      text:
          'draft.create ${session.draftId} (${session.fileCount} files, ${session.totalBytes} bytes)',
      structuredContent: <String, Object?>{
        'draftId': session.draftId,
        'workspaceAlias': session.workspaceAlias,
        'scope': EffectManifest.workspaceFilesOnlyScope,
        'networkIsolated': false,
        'fileCount': session.fileCount,
        'totalBytes': session.totalBytes,
        'expiresAt': session.expiresAt.toUtc().toIso8601String(),
      },
      toastBody: 'đã tạo bản nháp workspace',
    );
  }
}

class DraftManifestTool extends HostToolHandler {
  const DraftManifestTool();

  @override
  String get name => 'draft.manifest';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final draftId = context.arguments['draftId']! as String;
    final snapshot = _manager(context).buildManifest(
      draftId,
      nowUtc: context.nowUtc,
    );
    final manifest = snapshot.manifest;
    const maxWireChanges = 50;
    final truncated = manifest.changes.length > maxWireChanges;
    final shown = truncated
        ? manifest.changes.sublist(0, maxWireChanges)
        : manifest.changes;
    return ToolHandlerOutput(
      text:
          'draft.manifest ${manifest.draftId}: ${manifest.changes.length} change(s)',
      structuredContent: <String, Object?>{
        'schemaVersion': manifest.schemaVersion,
        'draftId': manifest.draftId,
        'workspaceAlias': manifest.workspaceAlias,
        'scope': manifest.scope,
        'networkIsolated': manifest.networkIsolated,
        'effectSha256': snapshot.effectSha256,
        'changeCount': manifest.changes.length,
        'changes': shown
            .map(
              (c) => <String, Object?>{
                'relPath': c.relPath,
                'op': c.op.wire,
                if (c.preSha256 != null) 'preSha256': c.preSha256,
                if (c.postSha256 != null) 'postSha256': c.postSha256,
                if (c.sizeBytes != null) 'sizeBytes': c.sizeBytes,
              },
            )
            .toList(growable: false),
        'truncated': truncated,
        if (manifest.checks != null) ...<String, Object?>{
          'commandCount': manifest.checks!.commandCount,
          'allCompleted': manifest.checks!.allCompleted,
          'failedCount': manifest.checks!.failedCount,
        },
        'createdAt': manifest.createdAt,
        'expiresAt': manifest.expiresAt,
      },
    );
  }
}

class DraftDiscardTool extends HostToolHandler {
  const DraftDiscardTool();

  @override
  String get name => 'draft.discard';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final draftId = context.arguments['draftId']! as String;
    final discarded = _manager(context).discardDraft(draftId);
    return ToolHandlerOutput(
      text: 'draft.discard $draftId discarded=$discarded',
      structuredContent: <String, Object?>{
        'draftId': draftId,
        'discarded': discarded,
      },
    );
  }
}

class DraftApplyTool extends HostToolHandler {
  const DraftApplyTool();

  @override
  String get name => 'draft.apply';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final journal = context.fsUndoJournal;
    if (journal == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'platform_unsupported',
      );
    }
    final args = context.arguments;
    final draftId = args['draftId']! as String;
    final effectSha256 = args['effectSha256']! as String;
    final result = await _manager(context).applyDraft(
      draftId: draftId,
      requestedEffectSha256: effectSha256,
      approval: context.approval,
      arguments: args,
      hostId: context.hostId,
      pinnedPhonePublicKeys: context.pinnedPhonePublicKeys,
      undoJournal: journal,
      shellControl: context.policy?.shellControl,
      homeDirectory: context.execFsContext?.homeDirectory ?? hostHomeDirectory(),
      nowUtc: context.nowUtc,
    );
    return ToolHandlerOutput(
      text:
          'Đã áp dụng bản nháp (${result.appliedCount} tệp: +${result.createdCount} ~${result.modifiedCount} -${result.deletedCount}).',
      structuredContent: <String, Object?>{
        'draftId': result.draftId,
        'effectSha256': result.effectSha256,
        'appliedCount': result.appliedCount,
        'createdCount': result.createdCount,
        'modifiedCount': result.modifiedCount,
        'deletedCount': result.deletedCount,
        'undoTxId': result.undoTxId,
        'undoAvailable': result.undoAvailable,
      },
      toastBody: 'đã áp dụng bản nháp (${result.appliedCount} tệp)',
    );
  }
}
