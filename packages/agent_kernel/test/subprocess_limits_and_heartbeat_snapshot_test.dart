import 'package:agent_kernel/agent_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('SpawnSpec limits & defaults [D-502]', () {
    test('exposes updated defaults and upper bounds', () {
      expect(SpawnSpec.defaultMaxWallTimeMs, equals(600000));
      expect(SpawnSpec.maxAllowedWallTimeMs, equals(3600000));
      expect(SpawnSpec.defaultMaxSteps, equals(32));
      expect(SpawnSpec.maxAllowedSteps, equals(128));
      expect(SpawnSpec.defaultHeartbeatTimeoutMs, equals(300000));
      expect(SpawnSpec.maxAllowedHeartbeatTimeoutMs, equals(600000));

      final defaults = SpawnSpec(
        profile: ProcessProfileId.workspaceWorker,
        taskPrompt: 'Implement feature',
      );
      expect(defaults.maxWallTimeMs, equals(600000));
      expect(defaults.maxSteps, equals(32));
      expect(defaults.heartbeatTimeoutMs, equals(300000));
      expect(defaults.toJson()['maxWallTimeMs'], equals(600000));
      expect(defaults.toJson()['maxSteps'], equals(32));
      expect(defaults.toJson()['heartbeatTimeoutMs'], equals(300000));
    });

    test('accepts min and max boundary values and rejects out-of-range values', () {
      final minSpec = SpawnSpec(
        profile: ProcessProfileId.explorer,
        taskPrompt: 'Min bounds',
        maxWallTimeMs: 1,
        maxSteps: 1,
        heartbeatTimeoutMs: 1,
      );
      expect(minSpec.maxWallTimeMs, equals(1));
      expect(minSpec.maxSteps, equals(1));
      expect(minSpec.heartbeatTimeoutMs, equals(1));

      final maxSpec = SpawnSpec(
        profile: ProcessProfileId.workspaceWorker,
        taskPrompt: 'Max bounds',
        maxWallTimeMs: 3600000,
        maxSteps: 128,
        heartbeatTimeoutMs: 600000,
      );
      expect(maxSpec.maxWallTimeMs, equals(3600000));
      expect(maxSpec.maxSteps, equals(128));
      expect(maxSpec.heartbeatTimeoutMs, equals(600000));

      expect(
        () => SpawnSpec(
          profile: ProcessProfileId.explorer,
          taskPrompt: 'bad wall',
          maxWallTimeMs: 3600001,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => SpawnSpec(
          profile: ProcessProfileId.explorer,
          taskPrompt: 'bad steps',
          maxSteps: 129,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => SpawnSpec(
          profile: ProcessProfileId.explorer,
          taskPrompt: 'bad hb zero',
          heartbeatTimeoutMs: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => SpawnSpec(
          profile: ProcessProfileId.explorer,
          taskPrompt: 'bad hb over',
          heartbeatTimeoutMs: 600001,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('ChildHeartbeatSnapshot & ChildRunningSnapshot [D-503], [D-504]', () {
    test('ChildHeartbeatSnapshot serializes all fields deterministically', () {
      const snap = ChildHeartbeatSnapshot(
        currentStep: 9,
        maxSteps: 64,
        totalSyscalls: 23,
        elapsedMs: 120014,
        idleMs: 4120,
        heartbeatTimeoutMs: 300000,
        lastHeartbeatAt: '2026-11-27T14:46:55.890Z',
        isPaused: false,
        activeSyscall: 'sys_exec',
        lastSyscall: 'sys_edit_block',
        consecutiveErrors: 2,
        lastErrorReason: 'ENOENT',
      );
      expect(snap.toJson(), equals(<String, dynamic>{
        'currentStep': 9,
        'maxSteps': 64,
        'totalSyscalls': 23,
        'elapsedMs': 120014,
        'idleMs': 4120,
        'heartbeatTimeoutMs': 300000,
        'lastHeartbeatAt': '2026-11-27T14:46:55.890Z',
        'isPaused': false,
        'activeSyscall': 'sys_exec',
        'lastSyscall': 'sys_edit_block',
        'consecutiveErrors': 2,
        'lastErrorReason': 'ENOENT',
      }));

      const nullOpt = ChildHeartbeatSnapshot(
        currentStep: 0,
        maxSteps: 32,
        totalSyscalls: 0,
        elapsedMs: 10,
        idleMs: 10,
        heartbeatTimeoutMs: 300000,
        lastHeartbeatAt: '2026-11-27T14:46:55.890Z',
        isPaused: true,
        consecutiveErrors: 0,
      );
      final json = nullOpt.toJson();
      expect(json['activeSyscall'], isNull);
      expect(json['lastSyscall'], isNull);
      expect(json['lastErrorReason'], isNull);
      expect(json['isPaused'], isTrue);
    });

    test('ChildRunningSnapshot serializes running task metadata and nested heartbeat', () {
      const hb = ChildHeartbeatSnapshot(
        currentStep: 4,
        maxSteps: 45,
        totalSyscalls: 10,
        elapsedMs: 2500,
        idleMs: 100,
        heartbeatTimeoutMs: 300000,
        lastHeartbeatAt: '2026-11-27T14:46:55.890Z',
        isPaused: false,
        activeSyscall: 'sys_llm_chat',
        lastSyscall: 'sys_read_lines',
        consecutiveErrors: 0,
      );
      const running = ChildRunningSnapshot(
        pid: 3,
        logicalTaskId: 'task_0002',
        name: 'workspace_worker-3',
        profile: ProcessProfileId.workspaceWorker,
        state: 'running',
        model: 'local-ollama/gemma4:12b',
        attemptIndex: 1,
        maxWallTimeMs: 3600000,
        workspaceName: 'ws-3',
        baseChangeId: 'qpvuntsm',
        workingChangeId: 'kkmpptxz',
        consumedTokens: 6800,
        consumedCostMicroUsd: 0,
        heartbeat: hb,
      );
      final json = running.toJson();
      expect(json['pid'], equals(3));
      expect(json['logicalTaskId'], equals('task_0002'));
      expect(json['profile'], equals('workspace_worker'));
      expect(json['state'], equals('running'));
      expect(json['maxWallTimeMs'], equals(3600000));
      expect((json['heartbeat'] as Map<String, dynamic>)['currentStep'], equals(4));
    });
  });

  group('QuotaLedger donation alignment with extended maxSteps [D-502]', () {
    test('supports maxSyscallCountPerTurn = 128 * 8 and maxWallTimeMs = 3600000', () {
      final parent = ProcessControlBlock(
        pid: 1,
        name: 'lead',
        ring: ProtectionRing.ring2,
        cspace: CapabilityTable.stage3LeadAgent(),
        quota: const ResourceQuota(
          maxChildProcesses: 4,
          maxTotalTokens: 100000,
        ),
        namespace: const VfsNamespace.empty(),
        memory: VirtualContextMemory(
          sessionId: 'quota_ext',
          systemInstruction: PinnedSystemInstruction(
            instruction: 'System',
            tools: const <SyscallToolSchema>[],
          ),
        ),
      );
      final ledger = QuotaLedger();
      final res = ledger.donateToChild(
        parent: parent,
        childPid: 2,
        maxWallTimeMs: SpawnSpec.maxAllowedWallTimeMs,
        maxSyscallCountPerTurn: SpawnSpec.maxAllowedSteps * 8,
      );
      expect(res.ok, isTrue);
      expect(res.value!.childQuota.maxWallTimeMs, equals(3600000));
      expect(res.value!.childQuota.maxSyscallCountPerTurn, equals(1024));
    });
  });
}
