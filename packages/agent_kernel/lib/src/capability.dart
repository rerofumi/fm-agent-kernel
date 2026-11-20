import 'dart:collection';

import 'process_profile.dart';
import 'syscall_error.dart';

/// Opaque capability handle referencing an entry in a process's CSpace ([D-005]).
extension type const CapHandle(String id) {}

/// Access rights granted by a capability entry ([D-005], [D-213]).
enum CapRight {
  read,
  writeCow,
  exec,
  vcsRead,
  vcsTx,
  llmInfer,
  admin,
  // --- Stage 2 rights ([D-213]) ---
  memManage,
  procSpawn,
  procSelf,
  ipc,
  netRead,
  // --- Stage 3 rights ([D-302]) ---
  mcpCall,
}

/// Single capability descriptor binding a scope and set of rights to a [CapHandle].
class CapabilityEntry {
  CapabilityEntry({
    required this.handle,
    required this.resourceScope,
    required Set<CapRight> rights,
  }) : rights = UnmodifiableSetView<CapRight>(Set<CapRight>.from(rights));

  final CapHandle handle;
  final String resourceScope;
  final UnmodifiableSetView<CapRight> rights;

  /// Returns true if this capability grants [right].
  bool allows(CapRight right) => rights.contains(right);
}

/// Per-process capability table (CSpace) mediating access rights ([D-005]).
class CapabilityTable {
  CapabilityTable({Iterable<CapabilityEntry> initialEntries = const <CapabilityEntry>[]}) {
    for (final entry in initialEntries) {
      _entries[entry.handle] = entry;
    }
  }

  /// Creates the default Stage 1 LeadAgent capability table for `/workspace`.
  factory CapabilityTable.stage1LeadAgent({
    CapHandle handle = const CapHandle('cap_workspace_rw'),
  }) {
    return CapabilityTable(
      initialEntries: <CapabilityEntry>[
        CapabilityEntry(
          handle: handle,
          resourceScope: '/workspace',
          rights: const <CapRight>{
            CapRight.read,
            CapRight.writeCow,
            CapRight.exec,
            CapRight.vcsRead,
            CapRight.vcsTx,
            CapRight.llmInfer,
          },
        ),
      ],
    );
  }

  /// Creates the default Stage 2 LeadAgent capability table ([D-213]).
  ///
  /// Includes `/workspace` rights (including `memManage`, `procSpawn`, `ipc`)
  /// and a separate `net:public_readonly` entry (`netRead`) held as a delegation
  /// source for sterile `WebResearcher` children (`W⊕N` blocks direct parent use).
  factory CapabilityTable.stage2LeadAgent({
    CapHandle workspaceHandle = const CapHandle('cap_workspace_rw'),
    CapHandle netHandle = const CapHandle('cap_net_public'),
  }) {
    return CapabilityTable(
      initialEntries: <CapabilityEntry>[
        CapabilityEntry(
          handle: workspaceHandle,
          resourceScope: '/workspace',
          rights: const <CapRight>{
            CapRight.read,
            CapRight.writeCow,
            CapRight.exec,
            CapRight.vcsRead,
            CapRight.vcsTx,
            CapRight.llmInfer,
            CapRight.memManage,
            CapRight.procSpawn,
            CapRight.ipc,
          },
        ),
        CapabilityEntry(
          handle: netHandle,
          resourceScope: 'net:public_readonly',
          rights: const <CapRight>{
            CapRight.netRead,
          },
        ),
      ],
    );
  }

  /// Creates the default Stage 3 LeadAgent capability table ([D-302]).
  ///
  /// Includes all Stage 2 rights plus `CapRight.mcpCall` scoped to `mcp:session`.
  factory CapabilityTable.stage3LeadAgent({
    CapHandle workspaceHandle = const CapHandle('cap_workspace_rw'),
    CapHandle netHandle = const CapHandle('cap_net_public'),
    CapHandle mcpHandle = const CapHandle('cap_mcp_session'),
  }) {
    return CapabilityTable(
      initialEntries: <CapabilityEntry>[
        ...CapabilityTable.stage2LeadAgent(
          workspaceHandle: workspaceHandle,
          netHandle: netHandle,
        ).entries,
        CapabilityEntry(
          handle: mcpHandle,
          resourceScope: 'mcp:session',
          rights: const <CapRight>{
            CapRight.mcpCall,
          },
        ),
      ],
    );
  }

  /// Rights unconditionally forbidden on Stage 2 Ring 3 child processes ([D-204], [D-213]).
  static const Set<CapRight> stage2ForbiddenChildRights = <CapRight>{
    CapRight.writeCow,
    CapRight.vcsTx,
    CapRight.exec,
    CapRight.procSpawn,
    CapRight.admin,
  };

  /// Rights unconditionally forbidden on all Stage 3 Ring 3 child processes ([D-306]).
  static const Set<CapRight> stage3ForbiddenChildRights = <CapRight>{
    CapRight.vcsTx,
    CapRight.procSpawn,
    CapRight.mcpCall,
    CapRight.admin,
  };

  final Map<CapHandle, CapabilityEntry> _entries = <CapHandle, CapabilityEntry>{};

  /// Unmodifiable view of all entries in this CSpace.
  UnmodifiableListView<CapabilityEntry> get entries =>
      UnmodifiableListView<CapabilityEntry>(_entries.values);

  /// Union of all rights held across every entry in this CSpace.
  Set<CapRight> get allRights {
    final out = <CapRight>{};
    for (final entry in _entries.values) {
      out.addAll(entry.rights);
    }
    return Set<CapRight>.unmodifiable(out);
  }

  /// Looks up a capability entry by [handle].
  CapabilityEntry? lookup(CapHandle handle) => _entries[handle];

  /// Grants or replaces a capability entry in this CSpace.
  void grant(CapabilityEntry entry) {
    _entries[entry.handle] = entry;
  }

  /// Revokes the capability identified by [handle].
  bool revoke(CapHandle handle) => _entries.remove(handle) != null;

  /// Returns true if [handle] exists in CSpace and grants [right].
  bool hasRight(CapHandle handle, CapRight right) {
    final entry = _entries[handle];
    if (entry == null) {
      return false;
    }
    return entry.allows(right);
  }

  /// Returns true if any entry in this CSpace grants [right].
  bool hasAnyRight(CapRight right) {
    for (final entry in _entries.values) {
      if (entry.allows(right)) {
        return true;
      }
    }
    return false;
  }

  /// Resolves [right] against [handle] and other distinct-scope entries in this CSpace ([D-202], [D-213]).
  ///
  /// Rejects unknown handles and never escalates across another entry sharing the same
  /// `resourceScope` as [handle] (preserving explicit handle attenuation).
  bool hasRightForContext(CapHandle handle, CapRight right) {
    final primary = _entries[handle];
    if (primary == null) {
      return false;
    }
    if (primary.allows(right)) {
      return true;
    }
    for (final entry in _entries.values) {
      if (entry.resourceScope != primary.resourceScope && entry.allows(right)) {
        return true;
      }
    }
    return false;
  }

  /// Derives an attenuated child CSpace enforcing monotonic attenuation and Stage 2 child locks ([D-213]).
  ///
  /// - Rejects any right in [stage2ForbiddenChildRights] with `EPERM: STAGE2_READONLY_CHILD_LOCK`.
  /// - Rejects any resource right (other than `CapRight.procSelf`) not present in this parent
  ///   CSpace with `EPERM: CAPABILITY_ATTENUATION_VIOLATION`.
  SyscallResult<CapabilityTable> deriveForChild({
    required Set<CapRight> requestedRights,
    CapHandle childHandle = const CapHandle('cap_child'),
    String resourceScope = '/workspace',
    bool enforceStage2ReadOnlyChildLock = true,
  }) {
    if (enforceStage2ReadOnlyChildLock) {
      final forbidden = requestedRights.intersection(stage2ForbiddenChildRights);
      if (forbidden.isNotEmpty) {
        final names = forbidden.map((r) => r.name).toList()..sort();
        return SyscallResult<CapabilityTable>.failure(
          SyscallError(
            code: SyscallErrorCode.eperm,
            reason: 'STAGE2_READONLY_CHILD_LOCK',
            message:
                'Stage 2 child processes cannot hold mutating/exec/spawn/admin rights: ${names.join(', ')}.',
            recoverable: false,
            details: <String, dynamic>{'forbiddenRights': names},
          ),
        );
      }
    }

    final parentUnion = allRights;
    final missing = <CapRight>[];
    for (final right in requestedRights) {
      if (right == CapRight.procSelf) {
        continue;
      }
      if (!parentUnion.contains(right)) {
        missing.add(right);
      }
    }
    if (missing.isNotEmpty) {
      final names = missing.map((r) => r.name).toList()..sort();
      return SyscallResult<CapabilityTable>.failure(
        SyscallError(
          code: SyscallErrorCode.eperm,
          reason: 'CAPABILITY_ATTENUATION_VIOLATION',
          message:
              'Cannot derive child capability: parent CSpace lacks requested rights: ${names.join(', ')}.',
          recoverable: false,
          details: <String, dynamic>{'missingParentRights': names},
        ),
      );
    }

    return SyscallResult<CapabilityTable>.success(
      CapabilityTable(
        initialEntries: <CapabilityEntry>[
          CapabilityEntry(
            handle: childHandle,
            resourceScope: resourceScope,
            rights: requestedRights,
          ),
        ],
      ),
    );
  }

  /// Derives a child CSpace constrained to [profile]'s allowed rights and optional subset [requestedRights] ([D-211], [D-213], [D-306]).
  SyscallResult<CapabilityTable> deriveForProfile(
    ProcessProfileId profile, {
    Set<CapRight>? requestedRights,
    CapHandle? childHandle,
  }) {
    final profileDefaults = profile.defaultRights;
    final targetRights = requestedRights ?? profileDefaults;

    if (profile.allowsIsolatedWorkspaceMutation) {
      final forbidden = targetRights.intersection(stage3ForbiddenChildRights);
      if (forbidden.isNotEmpty) {
        final names = forbidden.map((r) => r.name).toList()..sort();
        return SyscallResult<CapabilityTable>.failure(
          SyscallError(
            code: SyscallErrorCode.eperm,
            reason: 'STAGE3_FORBIDDEN_CHILD_RIGHT',
            message:
                'Stage 3 child profile "${profile.wireValue}" cannot hold forbidden rights: ${names.join(', ')}.',
            recoverable: false,
            details: <String, dynamic>{
              'profile': profile.wireValue,
              'forbiddenRights': names,
            },
          ),
        );
      }
    } else {
      // Enforce Stage 2 child lock first so mutating rights always surface STAGE2_READONLY_CHILD_LOCK.
      final forbidden = targetRights.intersection(stage2ForbiddenChildRights);
      if (forbidden.isNotEmpty) {
        final names = forbidden.map((r) => r.name).toList()..sort();
        return SyscallResult<CapabilityTable>.failure(
          SyscallError(
            code: SyscallErrorCode.eperm,
            reason: 'STAGE2_READONLY_CHILD_LOCK',
            message:
                'Stage 2 child profile "${profile.wireValue}" cannot hold forbidden rights: ${names.join(', ')}.',
            recoverable: false,
            details: <String, dynamic>{
              'profile': profile.wireValue,
              'forbiddenRights': names,
            },
          ),
        );
      }
    }

    if (requestedRights != null) {
      final outsideProfile = requestedRights.difference(profileDefaults);
      if (outsideProfile.isNotEmpty) {
        final names = outsideProfile.map((r) => r.name).toList()..sort();
        return SyscallResult<CapabilityTable>.failure(
          SyscallError(
            code: SyscallErrorCode.eperm,
            reason: 'CAPABILITY_ATTENUATION_VIOLATION',
            message:
                'Requested rights exceed profile "${profile.wireValue}" boundary: ${names.join(', ')}.',
            recoverable: false,
            details: <String, dynamic>{
              'profile': profile.wireValue,
              'outsideProfileRights': names,
            },
          ),
        );
      }
    }

    return deriveForChild(
      requestedRights: targetRights,
      childHandle: childHandle ?? CapHandle('cap_${profile.wireValue}'),
      resourceScope: profile.primaryResourceScope,
      enforceStage2ReadOnlyChildLock: !profile.allowsIsolatedWorkspaceMutation,
    );
  }
}
