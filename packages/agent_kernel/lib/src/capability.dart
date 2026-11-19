import 'dart:collection';

/// Opaque capability handle referencing an entry in a process's CSpace ([D-005]).
extension type const CapHandle(String id) {}

/// Access rights granted by a capability entry ([D-005]).
enum CapRight {
  read,
  writeCow,
  exec,
  vcsRead,
  vcsTx,
  llmInfer,
  admin,
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

  final Map<CapHandle, CapabilityEntry> _entries = <CapHandle, CapabilityEntry>{};

  /// Unmodifiable view of all entries in this CSpace.
  UnmodifiableListView<CapabilityEntry> get entries =>
      UnmodifiableListView<CapabilityEntry>(_entries.values);

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
}
