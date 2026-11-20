import 'dart:convert';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;

/// Metadata for an isolated Jujutsu workspace allocated for a Ring 3 child process ([D-307]).
class AllocatedWorkspace {
  const AllocatedWorkspace({
    required this.workspaceName,
    required this.workspaceRoot,
    required this.baseChangeId,
    required this.workingChangeId,
    required this.commitId,
    required this.currentOpId,
  });

  final String workspaceName;
  final String workspaceRoot;
  final String baseChangeId;
  final String workingChangeId;
  final String commitId;
  final String currentOpId;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'workspaceName': workspaceName,
        'workspaceRoot': workspaceRoot,
        'baseChangeId': baseChangeId,
        'workingChangeId': workingChangeId,
        'commitId': commitId,
        'currentOpId': currentOpId,
      };
}

/// Result of cleaning up an isolated Jujutsu workspace after child exit ([D-307]).
class WorkspaceCleanupResult {
  const WorkspaceCleanupResult({
    this.finalChangeId,
    this.finalCommitId,
    required this.cleanedUp,
  });

  final String? finalChangeId;
  final String? finalCommitId;
  final bool cleanedUp;
}

/// Result of cascading `workspace update-stale` and conflict inspection to a descendant stacked task ([D-311]).
class StackedCascadeTaskResult {
  const StackedCascadeTaskResult({
    required this.taskId,
    required this.workingChangeId,
    required this.commitId,
    required this.hasConflicts,
    this.conflictedFiles = const <String>[],
    required this.state,
  });

  final String taskId;
  final String workingChangeId;
  final String commitId;
  final bool hasConflicts;
  final List<String> conflictedFiles;
  final String state;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'taskId': taskId,
        'workingChangeId': workingChangeId,
        'commitId': commitId,
        'hasConflicts': hasConflicts,
        'conflictedFiles': conflictedFiles,
        'state': state,
      };
}

/// Pure helpers for building and parsing `jj workspace` CLI operations ([D-307], [D-308]).
final class JjWorkspaceOps {
  const JjWorkspaceOps._();

  /// JSON Lines template for `jj workspace list` ([D-307]).
  static const String workspaceListJsonTemplate =
      r'"{\"name\":" ++ json(name) ++ '
      r'",\"change_id\":" ++ json(target.change_id().short(12)) ++ '
      r'",\"commit_id\":" ++ json(target.commit_id()) ++ '
      r'",\"parents\":" ++ json(target.parents().map(|c| c.change_id().short(12))) ++ '
      r'",\"empty\":" ++ json(target.empty()) ++ '
      r'"}\n"';

  /// Non-destructive JSON template for `sys_jj_conflicts` ([D-310]).
  static const String conflictsJsonTemplate =
      r'"{\"change_id\":" ++ json(change_id.short(12)) ++ '
      r'",\"commit_id\":" ++ json(commit_id) ++ '
      r'",\"conflict\":" ++ json(conflict) ++ '
      r'",\"files\":" ++ json(conflicted_files.map(|e| e.path())) ++ '
      r'"}\n"';

  /// Normalizes `conflicted_files` paths into POSIX `/workspace/<relPath>` form
  /// and filters out protected or out-of-scope paths when [namespace] is given ([D-310]).
  static List<String> normalizeConflictedVirtualPaths(
    Iterable<dynamic> rawFiles, {
    VfsNamespace? namespace,
  }) {
    final normalized = <String>[];
    final seen = <String>{};
    for (final item in rawFiles) {
      if (item is! String) {
        continue;
      }
      var rel = item.replaceAll('\\', '/').trim();
      while (rel.startsWith('/')) {
        rel = rel.substring(1);
      }
      if (rel.isEmpty) {
        continue;
      }
      final vPath = '/workspace/$rel';
      if (namespace != null) {
        final check = namespace.resolveVirtualPath(
          vPath,
          allowRoot: false,
          checkProtected: true,
          checkSymlinks: false,
        );
        if (!check.ok) {
          continue;
        }
      }
      if (seen.add(vPath)) {
        normalized.add(vPath);
      }
    }
    return normalized;
  }

  static String workspaceNameForPid(Pid pid) => 'ws-$pid';

  static String workspaceRootForPid(String mainWorkspaceRoot, Pid pid) =>
      p.normalize(
        p.absolute(p.join(mainWorkspaceRoot, '.agent_os', 'ws', '$pid')),
      );

  static String taskWorkspaceName(String taskId) => 'ws-task-$taskId';

  static String taskWorkspaceRoot(String mainWorkspaceRoot, String taskId) =>
      p.normalize(
        p.absolute(p.join(mainWorkspaceRoot, '.agent_os', 'ws', 'task_$taskId')),
      );

  static List<String> buildWorkspaceAddArgs({
    required String workspaceRoot,
    required String workspaceName,
    required String baseChangeId,
    String? description,
  }) {
    final normalizedRoot = p.normalize(p.absolute(workspaceRoot));
    final desc = (description != null && description.trim().isNotEmpty)
        ? description.trim()
        : 'agent-os: $workspaceName';
    return <String>[
      'workspace',
      'add',
      '--no-colocate',
      normalizedRoot,
      '--name',
      workspaceName,
      '-r',
      baseChangeId,
      '-m',
      desc,
    ];
  }

  static List<String> buildWorkspaceForgetArgs(String workspaceName) =>
      <String>['workspace', 'forget', workspaceName];

  static List<String> buildWorkspaceUpdateStaleArgs() =>
      const <String>['workspace', 'update-stale'];

  static List<String> buildWorkspaceListArgs() => const <String>[
        'workspace',
        'list',
        '--ignore-working-copy',
        '-T',
        workspaceListJsonTemplate,
      ];

  static bool isStaleWorkingCopyError(String stderrText) =>
      stderrText.toLowerCase().contains('working copy is stale');

  static List<Map<String, dynamic>> parseWorkspaceListJsonLines(
    String stdoutText,
  ) {
    final results = <Map<String, dynamic>>[];
    for (final rawLine in LineSplitter.split(stdoutText)) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) {
        results.add(decoded);
      }
    }
    return results;
  }
}
