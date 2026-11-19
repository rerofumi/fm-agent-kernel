import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<void> _initJjRepo(Directory dir) async {
  final env = JjDriver.buildNonInteractiveEnvironment();
  final initRes = await Process.run(
    'jj',
    const <String>['git', 'init'],
    workingDirectory: dir.path,
    runInShell: false,
    environment: env,
  );
  if (initRes.exitCode != 0) {
    throw StateError('jj git init failed: ${initRes.stderr}');
  }
  await Process.run(
    'jj',
    const <String>['config', 'set', '--repo', 'user.name', 'Test User'],
    workingDirectory: dir.path,
    runInShell: false,
    environment: env,
  );
  await Process.run(
    'jj',
    const <String>['config', 'set', '--repo', 'user.email', 'test@example.com'],
    workingDirectory: dir.path,
    runInShell: false,
    environment: env,
  );
}

Future<String> _getHeadOpIdIgnoreWc(Directory dir) async {
  final res = await Process.run(
    'jj',
    const <String>[
      'op',
      'log',
      '--no-graph',
      '--limit',
      '1',
      '--ignore-working-copy',
      '-T',
      'self.id()',
    ],
    workingDirectory: dir.path,
    runInShell: false,
    environment: JjDriver.buildNonInteractiveEnvironment(),
  );
  if (res.exitCode != 0) {
    throw StateError('jj op log failed: ${res.stderr}');
  }
  return (res.stdout as String).trim();
}

Future<void> _snapshotJj(Directory dir) async {
  final res = await Process.run(
    'jj',
    const <String>['status'],
    workingDirectory: dir.path,
    runInShell: false,
    environment: JjDriver.buildNonInteractiveEnvironment(),
  );
  if (res.exitCode != 0) {
    throw StateError('jj status failed: ${res.stderr}');
  }
}

class _MockLlmDriver implements LlmDriver {
  _MockLlmDriver(this.providerId, this._handler);

  @override
  final LlmProviderId providerId;

  final LlmChatResponse Function(LlmChatRequest request) _handler;
  final List<LlmChatRequest> capturedRequests = <LlmChatRequest>[];

  @override
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  }) async* {
    capturedRequests.add(request);
    final resp = _handler(request);
    if (resp.content.isNotEmpty) {
      yield LlmTextDelta(resp.content);
    }
    yield LlmDoneEvent(resp);
  }
}

void main() {
  group('WorkspacePageFreshnessChecker & sys_mem_pagein ([D-204], [D-208])', () {
    late Directory tempDir;
    late VfsNamespace namespace;
    late JjDriver jjDriver;
    late HostFsDriver hostFsDriver;
    late WorkspacePageFreshnessChecker checker;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fm_wp2_freshness_');
      await _initJjRepo(tempDir);
      await File(p.join(tempDir.path, 'a.dart')).writeAsString('int a = 1;\n');
      await File(p.join(tempDir.path, 'b.dart')).writeAsString('int b = 1;\n');
      await _snapshotJj(tempDir);

      namespace = VfsNamespace(workspaceHostRoot: tempDir.path);
      jjDriver = JjDriver(namespace: namespace);
      hostFsDriver = HostFsDriver(
        namespace: namespace,
        ensureActiveTransaction: jjDriver.ensureActiveTransaction,
        syncWorkingCopySnapshot: jjDriver.syncWorkingCopySnapshot,
        currentCommitIdProvider: jjDriver.getCurrentCommitIdNonDestructive,
      );
      checker = WorkspacePageFreshnessChecker(
        namespace: namespace,
        jjDriver: jjDriver,
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'detects all 4 freshness cases without false positives/negatives, preserves Segment 1, and keeps jj op log unchanged',
      () async {
        final memory = VirtualContextMemory(
          sessionId: 'sess_fresh_4cases',
          systemInstruction: PinnedSystemInstruction(
            instruction: 'System pinned',
            tools: const <SyscallToolSchema>[],
          ),
        );
        final pager = const ContextPager();

        memory.appendUserTurn('Inspect a.dart and status');
        final readA = await hostFsDriver.readLines(path: '/workspace/a.dart');
        expect(readA.ok, isTrue);
        final readData = readA.value!;
        final pageA = memory.appendToolResultTurn(
          CanonicalToolResultTurn(
            canonicalCallId: 'sc_0001',
            toolName: 'sys_read_lines',
            content: jsonEncode(readData),
          ),
          cleanSource: CleanPageSourceMeta(
            sourceKind: CleanSourceKind.workspaceFile,
            syscallName: 'sys_read_lines',
            replayArgs: const <String, dynamic>{'path': '/workspace/a.dart'},
            virtualPath: '/workspace/a.dart',
            startLine: readData['startLine'] as int,
            endLine: readData['endLine'] as int,
            readSha256: readData['sha256'] as String,
            readModifiedUtc: DateTime.parse(readData['modifiedUtc'] as String),
            readByteLength: readData['byteLength'] as int,
          ),
        );

        final statusRes = await jjDriver.status();
        expect(statusRes.ok, isTrue);
        final statusData = statusRes.value!;
        final pageVcs = memory.appendToolResultTurn(
          CanonicalToolResultTurn(
            canonicalCallId: 'sc_0002',
            toolName: 'sys_jj_status',
            content: jsonEncode(statusData),
          ),
          cleanSource: CleanPageSourceMeta(
            sourceKind: CleanSourceKind.vcsSnapshot,
            syscallName: 'sys_jj_status',
            replayArgs: const <String, dynamic>{},
            readCommitId: statusData['commitId'] as String,
            readOpId: statusData['opId'] as String?,
          ),
        );

        // Snapshot Segment 1 strings to prove immutability across all freshness updates.
        final segment1Before = memory.historySegment.turns
            .map((t) => t is CanonicalToolResultTurn ? t.content : t.toString())
            .toList(growable: false);
        final opIdBeforeChecks = await _getHeadOpIdIgnoreWc(tempDir);

        // Case 1: Unedited -> Fresh
        await pager.refreshFreshness(memory, freshnessChecker: checker);
        expect(pageA.freshness, PageFreshnessStatus.fresh);
        expect(pageVcs.freshness, PageFreshnessStatus.fresh);
        expect(memory.ephemeralSegment.pageDirectorySummary, isNull);
        expect(await _getHeadOpIdIgnoreWc(tempDir), opIdBeforeChecks);

        // Case 4: Unrelated file b.dart edited + snapshotted -> a.dart remains Fresh (zero false positives), VCS becomes Stale
        await File(p.join(tempDir.path, 'b.dart')).writeAsString('int b = 2;\n');
        await _snapshotJj(tempDir);
        final opIdAfterBEdit = await _getHeadOpIdIgnoreWc(tempDir);

        await pager.refreshFreshness(memory, freshnessChecker: checker);
        expect(pageA.freshness, PageFreshnessStatus.fresh);
        expect(pageVcs.freshness, PageFreshnessStatus.stale);
        expect(memory.ephemeralSegment.pageDirectorySummary, contains('STALE'));
        expect(memory.ephemeralSegment.pageDirectorySummary, contains(pageVcs.pageId));
        expect(memory.ephemeralSegment.pageDirectorySummary, isNot(contains(pageA.pageId)));
        expect(await _getHeadOpIdIgnoreWc(tempDir), opIdAfterBEdit);

        // Case 3: Unsnapshotted external direct edit on a.dart -> a.dart immediately becomes [STALE] while jj op_id stays unchanged
        await File(p.join(tempDir.path, 'a.dart')).writeAsString('int a = 999;\n');
        await pager.refreshFreshness(memory, freshnessChecker: checker);
        expect(pageA.freshness, PageFreshnessStatus.stale);
        expect(memory.ephemeralSegment.pageDirectorySummary, contains(pageA.pageId));
        expect(memory.ephemeralSegment.pageDirectorySummary, contains('STALE'));
        expect(await _getHeadOpIdIgnoreWc(tempDir), opIdAfterBEdit);

        // Case 2: Snapshotted edit via HostFsDriver.editBlock -> remains [STALE]
        final rereadA = await hostFsDriver.readLines(path: '/workspace/a.dart');
        final editRes = await hostFsDriver.editBlock(
          path: '/workspace/a.dart',
          expectedSha256: rereadA.value!['sha256'] as String,
          oldBlock: 'int a = 999;',
          newBlock: 'int a = 1000;',
        );
        expect(editRes.ok, isTrue);
        await pager.refreshFreshness(memory, freshnessChecker: checker);
        expect(pageA.freshness, PageFreshnessStatus.stale);

        // Case 5: Deleted file -> PageFreshnessStatus.deleted
        await File(p.join(tempDir.path, 'a.dart')).delete();
        await pager.refreshFreshness(memory, freshnessChecker: checker);
        expect(pageA.freshness, PageFreshnessStatus.deleted);
        expect(memory.ephemeralSegment.pageDirectorySummary, contains('DELETED'));

        // Verify Segment 1 strings were NEVER mutated during freshness detection ([D-208]).
        final segment1After = memory.historySegment.turns
            .map((t) => t is CanonicalToolResultTurn ? t.content : t.toString())
            .toList(growable: false);
        expect(segment1After, equals(segment1Before));
      },
    );

    test(
      'sys_mem_pagein reloads latest content without mutating Segment 1 stub and enforces ENOENT/EINVAL/EPERM',
      () async {
        final auditLogger = AuditLogger(
          workspaceHostRoot: tempDir.path,
          sessionId: 'sess_pagein_test',
        );
        const fullCap = CapHandle('cap_full');
        const noMemCap = CapHandle('cap_no_mem');
        const memOnlyCap = CapHandle('cap_mem_only');

        final cspace = CapabilityTable(
          initialEntries: <CapabilityEntry>[
            CapabilityEntry(
              handle: fullCap,
              resourceScope: '/workspace',
              rights: const <CapRight>{
                CapRight.read,
                CapRight.vcsRead,
                CapRight.memManage,
              },
            ),
            CapabilityEntry(
              handle: noMemCap,
              resourceScope: '/workspace',
              rights: const <CapRight>{CapRight.read},
            ),
            CapabilityEntry(
              handle: memOnlyCap,
              resourceScope: '/workspace',
              rights: const <CapRight>{CapRight.memManage},
            ),
          ],
        );

        final pcb = ProcessControlBlock(
          pid: 1,
          name: 'lead-agent',
          ring: ProtectionRing.ring2,
          cspace: cspace,
          quota: ResourceQuota.stage1Default,
          namespace: namespace,
          jjContext: jjDriver.txContext,
          memory: VirtualContextMemory(
            sessionId: 'sess_pagein_test',
            systemInstruction: PinnedSystemInstruction(
              instruction: 'System',
              tools: <SyscallToolSchema>[buildMemPageinToolSchema()],
            ),
          ),
        );
        final processTable = KernelProcessTable()..registerProcess(pcb);
        final gate = SyscallGate(
          processTable: processTable,
          approvalGate: ApprovalGate(handler: PolicyApprovalHandler.alwaysAllow()),
          ioCapper: IoPayloadCapper(workspaceHostRoot: tempDir.path),
          auditLogger: auditLogger,
          jjAuditInfoProvider: jjDriver.getAuditInfo,
        );
        gate.registerSyscall(
          buildMemPageinSyscallDefinition(
            hostFsDriver: hostFsDriver,
            jjDriver: jjDriver,
            freshnessChecker: checker,
          ),
        );

        pcb.memory.appendUserTurn('Read a.dart');
        final userPageId = pcb.memory.pageTable.pages.last.pageId;

        final readA = await hostFsDriver.readLines(path: '/workspace/a.dart');
        final readData = readA.value!;
        final origSha = readData['sha256'] as String;
        final pageA = pcb.memory.appendToolResultTurn(
          CanonicalToolResultTurn(
            canonicalCallId: 'sc_0001',
            toolName: 'sys_read_lines',
            content: jsonEncode(readData),
          ),
          cleanSource: CleanPageSourceMeta(
            sourceKind: CleanSourceKind.workspaceFile,
            syscallName: 'sys_read_lines',
            replayArgs: const <String, dynamic>{'path': '/workspace/a.dart'},
            virtualPath: '/workspace/a.dart',
            startLine: 1,
            endLine: 1,
            readSha256: origSha,
            readModifiedUtc: DateTime.parse(readData['modifiedUtc'] as String),
            readByteLength: readData['byteLength'] as int,
          ),
        );

        // Simulate eviction into mechanical stub in Segment 1.
        const pager = ContextPager();
        final stubText = pager.buildPageStub(pageA);
        pcb.memory.historySegment.replaceToolResultContentWithStub(
          pageA.historyTurnIndex!,
          stubText,
        );
        pageA.resident = false;

        // Modify a.dart externally so page becomes stale.
        await File(p.join(tempDir.path, 'a.dart')).writeAsString('int a = 42;\n');

        final fullCtx = SyscallContext(
          pid: 1,
          capHandle: fullCap,
          sessionId: 'sess_pagein_test',
        );

        // 1. EPERM: missing CapRight.memManage
        final epermNoMem = await gate.invoke(
          SyscallContext(
            pid: 1,
            capHandle: noMemCap,
            sessionId: 'sess_pagein_test',
          ),
          SyscallRequest(
            name: 'sys_mem_pagein',
            args: <String, dynamic>{'pageId': pageA.pageId},
          ),
        );
        expect(epermNoMem.ok, isFalse);
        expect(epermNoMem.error!.code, SyscallErrorCode.eperm);

        // 2. EPERM: has memManage but lacks source CapRight.read
        final epermNoRead = await gate.invoke(
          SyscallContext(
            pid: 1,
            capHandle: memOnlyCap,
            sessionId: 'sess_pagein_test',
          ),
          SyscallRequest(
            name: 'sys_mem_pagein',
            args: <String, dynamic>{'pageId': pageA.pageId},
          ),
        );
        expect(epermNoRead.ok, isFalse);
        expect(epermNoRead.error!.code, SyscallErrorCode.eperm);

        // 3. EINVAL: empty or malformed pageId
        final einvalBadId = await gate.invoke(
          fullCtx,
          SyscallRequest(
            name: 'sys_mem_pagein',
            args: <String, dynamic>{'pageId': 'not-a-page'},
          ),
        );
        expect(einvalBadId.ok, isFalse);
        expect(einvalBadId.error!.code, SyscallErrorCode.einval);
        expect(einvalBadId.error!.reason, 'INVALID_PAGE_ID');

        // 4. ENOENT: unknown pageId
        final enoentUnknown = await gate.invoke(
          fullCtx,
          SyscallRequest(
            name: 'sys_mem_pagein',
            args: <String, dynamic>{'pageId': 'pg_9999'},
          ),
        );
        expect(enoentUnknown.ok, isFalse);
        expect(enoentUnknown.error!.code, SyscallErrorCode.enoent);
        expect(enoentUnknown.error!.reason, 'PAGE_NOT_FOUND');

        // 5. EINVAL: non-Clean Page (user conversation turn)
        final einvalDirty = await gate.invoke(
          fullCtx,
          SyscallRequest(
            name: 'sys_mem_pagein',
            args: <String, dynamic>{'pageId': userPageId},
          ),
        );
        expect(einvalDirty.ok, isFalse);
        expect(einvalDirty.error!.code, SyscallErrorCode.einval);
        expect(einvalDirty.error!.reason, 'NOT_CLEAN_PAGE');

        // 6. Success: reloads updated content, updates metadata, leaves Segment 1 stub untouched.
        final okRes = await gate.invoke(
          fullCtx,
          SyscallRequest(
            name: 'sys_mem_pagein',
            args: <String, dynamic>{'pageId': pageA.pageId},
          ),
        );
        expect(okRes.ok, isTrue);
        final payload = okRes.value!;
        expect(payload['pageId'], pageA.pageId);
        expect(payload['wasStale'], isTrue);
        expect(payload['previousSha256'], origSha);
        expect(payload['currentSha256'], isNot(origSha));
        expect(payload['content'], contains('int a = 42;'));
        expect(pageA.freshness, PageFreshnessStatus.fresh);

        // Segment 1 stub remains byte-identical ([D-208]).
        final seg1Turn =
            pcb.memory.historySegment.turns[pageA.historyTurnIndex!]
                as CanonicalToolResultTurn;
        expect(seg1Turn.content, equals(stubText));

        // 7. ENOENT: source file deleted
        await File(p.join(tempDir.path, 'a.dart')).delete();
        final enoentDeleted = await gate.invoke(
          fullCtx,
          SyscallRequest(
            name: 'sys_mem_pagein',
            args: <String, dynamic>{'pageId': pageA.pageId},
          ),
        );
        expect(enoentDeleted.ok, isFalse);
        expect(enoentDeleted.error!.code, SyscallErrorCode.enoent);
        expect(enoentDeleted.error!.reason, 'SOURCE_FILE_DELETED');

        await auditLogger.flush();
      },
    );
  });

  group('ContextWindowResolver & OllamaDriver num_ctx invariant ([D-203], [D-209])', () {
    test('resolves local-ollama (/api/ps > /api/show num_ctx > capped archMax > fallback)', () async {
      var psResponse = <String, dynamic>{
        'models': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'gemma4:12b',
            'context_length': 16384,
          },
        ],
      };
      var showCalls = 0;

      final client = MockClient((request) async {
        if (request.url.path.endsWith('/api/ps')) {
          return http.Response(jsonEncode(psResponse), 200);
        }
        if (request.url.path.endsWith('/api/show')) {
          showCalls += 1;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final model = body['model'] as String;
          if (model == 'custom-numctx:latest') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'parameters': 'temperature 0.7\nnum_ctx 24576\n',
                'model_info': <String, dynamic>{'qwen35.context_length': 262144},
              }),
              200,
            );
          }
          if (model == 'unloaded-large:27b') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'parameters': 'temperature 0.7',
                'model_info': <String, dynamic>{'qwen35.context_length': 262144},
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }
        return http.Response('unexpected', 500);
      });

      final resolver = ContextWindowResolver(
        config: const ContextWindowConfig(
          modelOverrides: <String, int>{'local-ollama/override-model': 4096},
          defaultLocalUnloadedCap: 32768,
        ),
        localOllamaBaseUrl: 'http://127.0.0.1:11434',
        httpClient: client,
        processEnvironment: const <String, String>{},
      );

      // Priority 1: Explicit override
      final overrideSpec = await resolver.resolve(
        const ModelIdentifier(
          provider: LlmProviderId.localOllama,
          modelName: 'override-model',
        ),
      );
      expect(overrideSpec.contextWindowTokens, 4096);
      expect(overrideSpec.source, 'override');

      // Priority 2 Step A: /api/ps exact loaded context_length
      final psSpec = await resolver.resolve(
        const ModelIdentifier(
          provider: LlmProviderId.localOllama,
          modelName: 'gemma4:12b',
        ),
      );
      expect(psSpec.contextWindowTokens, 16384);
      expect(psSpec.isLoadedExact, isTrue);
      expect(psSpec.source, 'local-ollama:/api/ps');

      // Priority 2 Step B-1: unloaded model with explicit num_ctx in /api/show parameters
      final numCtxSpec = await resolver.resolve(
        const ModelIdentifier(
          provider: LlmProviderId.localOllama,
          modelName: 'custom-numctx:latest',
        ),
      );
      expect(numCtxSpec.contextWindowTokens, 24576);
      expect(numCtxSpec.isLoadedExact, isFalse);
      expect(numCtxSpec.source, 'local-ollama:/api/show:num_ctx');

      // Priority 2 Step B-2: unloaded model capped by defaultLocalUnloadedCap (32768)
      final cappedSpec = await resolver.resolve(
        const ModelIdentifier(
          provider: LlmProviderId.localOllama,
          modelName: 'unloaded-large:27b',
        ),
      );
      expect(cappedSpec.contextWindowTokens, 32768);
      expect(cappedSpec.isLoadedExact, isFalse);
      expect(cappedSpec.source, 'local-ollama:/api/show:capped');

      // When OLLAMA_CONTEXT_LENGTH is set, use min(archMax, envCap)
      final envResolver = ContextWindowResolver(
        localOllamaBaseUrl: 'http://127.0.0.1:11434',
        httpClient: client,
        processEnvironment: const <String, String>{
          'OLLAMA_CONTEXT_LENGTH': '65536',
        },
      );
      final envCappedSpec = await envResolver.resolve(
        const ModelIdentifier(
          provider: LlmProviderId.localOllama,
          modelName: 'unloaded-large:27b',
        ),
      );
      expect(envCappedSpec.contextWindowTokens, 65536);

      // Step C: unknown model -> fallback 32768
      final fallbackSpec = await resolver.resolve(
        const ModelIdentifier(
          provider: LlmProviderId.localOllama,
          modelName: 'unknown-model:1b',
        ),
      );
      expect(fallbackSpec.contextWindowTokens, 32768);
      expect(fallbackSpec.source, 'fallback:local-ollama');

      // Once loaded into /api/ps, re-probing syncs to exact loaded value
      psResponse = <String, dynamic>{
        'models': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'unloaded-large:27b',
            'context_length': 128000,
          },
        ],
      };
      final syncedSpec = await resolver.resolve(
        const ModelIdentifier(
          provider: LlmProviderId.localOllama,
          modelName: 'unloaded-large:27b',
        ),
      );
      expect(syncedSpec.contextWindowTokens, 128000);
      expect(syncedSpec.isLoadedExact, isTrue);
      expect(showCalls, greaterThanOrEqualTo(3));
    });

    test('resolves ollama-cloud /api/show and openrouter /models with session caching and fallbacks', () async {
      var openRouterCalls = 0;
      var cloudShowCalls = 0;
      var failMode = false;

      final client = MockClient((request) async {
        if (failMode) {
          return http.Response('service unavailable', 503);
        }
        if (request.url.host == 'ollama.com' &&
            request.url.path.endsWith('/api/show')) {
          cloudShowCalls += 1;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'model_info': <String, dynamic>{'gptoss.context_length': 131072},
            }),
            200,
          );
        }
        if (request.url.host == 'openrouter.ai' &&
            request.url.path.endsWith('/models')) {
          openRouterCalls += 1;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'data': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'openai/gpt-4o-mini',
                  'context_length': 128000,
                  'top_provider': <String, dynamic>{
                    'context_length': 128000,
                    'max_completion_tokens': 16384,
                  },
                },
                <String, dynamic>{
                  'id': 'anthropic/claude-sonnet-4',
                  'context_length': 200000,
                },
              ],
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });

      final resolver = ContextWindowResolver(
        httpClient: client,
        processEnvironment: const <String, String>{
          'OLLAMA_API_KEY': 'test_cloud_key_1234',
        },
      );

      // Cloud /api/show cached per model
      final cloud1 = await resolver.resolve(
        const ModelIdentifier(
          provider: LlmProviderId.ollamaCloud,
          modelName: 'gpt-oss:120b',
        ),
      );
      final cloud2 = await resolver.resolve(
        const ModelIdentifier(
          provider: LlmProviderId.ollamaCloud,
          modelName: 'gpt-oss:120b',
        ),
      );
      expect(cloud1.contextWindowTokens, 131072);
      expect(cloud2.contextWindowTokens, 131072);
      expect(cloudShowCalls, 1);

      // OpenRouter /models fetched once and cached for subsequent models
      final or1 = await resolver.resolve(
        const ModelIdentifier(
          provider: LlmProviderId.openRouter,
          modelName: 'openai/gpt-4o-mini',
        ),
      );
      final or2 = await resolver.resolve(
        const ModelIdentifier(
          provider: LlmProviderId.openRouter,
          modelName: 'anthropic/claude-sonnet-4',
        ),
      );
      expect(or1.contextWindowTokens, 128000);
      expect(or1.maxCompletionTokens, 16384);
      expect(or2.contextWindowTokens, 200000);
      expect(openRouterCalls, 1);

      // Failure falls back cleanly without throwing and without negative caching
      failMode = true;
      final offlineResolver = ContextWindowResolver(
        httpClient: client,
        processEnvironment: const <String, String>{},
      );
      final orFallback = await offlineResolver.resolve(
        const ModelIdentifier(
          provider: LlmProviderId.openRouter,
          modelName: 'openai/gpt-4o-mini',
        ),
      );
      final cloudFallback = await offlineResolver.resolve(
        const ModelIdentifier(
          provider: LlmProviderId.ollamaCloud,
          modelName: 'gpt-oss:120b',
        ),
      );
      expect(orFallback.contextWindowTokens, 128000);
      expect(orFallback.source, 'fallback:openrouter');
      expect(cloudFallback.contextWindowTokens, 131072);
      expect(cloudFallback.source, 'fallback:ollama-cloud');
    });

    test('OllamaDriver.buildRequestBody never sends dynamic options.num_ctx ([D-209] §4.2)', () {
      final driver = OllamaDriver.local(baseUrl: 'http://127.0.0.1:11434');
      final memory = VirtualContextMemory(
        sessionId: 'sess_num_ctx_check',
        systemInstruction: PinnedSystemInstruction(
          instruction: 'System',
          tools: const <SyscallToolSchema>[],
        ),
      )..appendUserTurn('Hello');

      final body = driver.buildRequestBody(
        LlmChatRequest(
          sessionId: 'sess_num_ctx_check',
          sessionUuid: 'uuid-1',
          model: const ModelIdentifier(
            provider: LlmProviderId.localOllama,
            modelName: 'gemma4:12b',
          ),
          prompt: const CanonicalIrProjector().project(
            memory,
            targetProvider: 'local-ollama',
            targetModel: 'gemma4:12b',
          ),
          turnIndex: 1,
          temperature: 0.2,
          maxTokens: 1024,
        ),
      );

      final options = body['options'] as Map<String, dynamic>?;
      expect(options, isNotNull);
      expect(options!.containsKey('num_ctx'), isFalse);
      driver.close();
    });
  });

  group('LlmRouter Dynamic Frame Resizing & Telemetry ([D-207], [D-209], [D-215])', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fm_wp2_router_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'auto-evicts Clean Pages on large-to-small model switch, logs paging telemetry, and returns EDQUOT when Dirty exceeds small window',
      () async {
        final auditLogger = AuditLogger(
          workspaceHostRoot: tempDir.path,
          sessionId: 'sess_resize_test',
        );
        final namespace = VfsNamespace(workspaceHostRoot: tempDir.path);
        final memory = VirtualContextMemory(
          sessionId: 'sess_resize_test',
          systemInstruction: PinnedSystemInstruction(
            instruction: 'System instruction',
            tools: const <SyscallToolSchema>[],
          ),
        );

        // Populate 3 large Clean Pages (~2000 tokens each) under a large 128k model.
        for (var i = 1; i <= 3; i++) {
          memory.appendUserTurn('Read file $i');
          memory.appendAssistantTurn(
            CanonicalAssistantTurn(
              originProvider: 'openrouter',
              originModel: 'openai/gpt-4o-mini',
              toolCalls: <CanonicalToolCall>[
                CanonicalToolCall(
                  canonicalCallId: 'sc_000$i',
                  name: 'sys_read_lines',
                  arguments: <String, dynamic>{'path': '/workspace/f$i.dart'},
                ),
              ],
            ),
          );
          memory.appendToolResultTurn(
            CanonicalToolResultTurn(
              canonicalCallId: 'sc_000$i',
              toolName: 'sys_read_lines',
              content: List<String>.filled(400, 'line_content_$i').join('\n'),
            ),
            cleanSource: CleanPageSourceMeta(
              sourceKind: CleanSourceKind.workspaceFile,
              syscallName: 'sys_read_lines',
              replayArgs: <String, dynamic>{'path': '/workspace/f$i.dart'},
              virtualPath: '/workspace/f$i.dart',
              startLine: 1,
              endLine: 400,
              readSha256: 'a' * 64,
            ),
          );
        }

        final mockCloud = _MockLlmDriver(
          LlmProviderId.openRouter,
          (req) => LlmChatResponse(
            content: 'Cloud ok',
            finishReason: 'stop',
            endpoint: 'https://openrouter.ai/api/v1/chat/completions',
            usage: LlmUsageTelemetry(
              promptTokens: 6000,
              completionTokens: 20,
              durationMs: 10,
            ),
          ),
        );
        final mockLocal = _MockLlmDriver(
          LlmProviderId.localOllama,
          (req) => LlmChatResponse(
            content: 'Local ok',
            finishReason: 'stop',
            endpoint: 'http://127.0.0.1:11434/api/chat',
            usage: LlmUsageTelemetry(
              promptTokens: 800,
              completionTokens: 15,
              durationMs: 10,
            ),
          ),
        );
        final router = LlmRouter(
          drivers: <LlmProviderId, LlmDriver>{
            LlmProviderId.openRouter: mockCloud,
            LlmProviderId.localOllama: mockLocal,
          },
        );

        final resolver = ContextWindowResolver(
          config: const ContextWindowConfig(
            modelOverrides: <String, int>{
              'openrouter/openai/gpt-4o-mini': 128000,
              'local-ollama/small-4k': 4096,
              'local-ollama/tiny-512': 512,
            },
          ),
        );

        final observedPids = <Pid>[];
        final pagingReports = <ContextPagingReport>[];

        final pcb = ProcessControlBlock(
          pid: 1,
          name: 'lead-agent',
          ring: ProtectionRing.ring2,
          cspace: CapabilityTable.stage1LeadAgent(),
          quota: ResourceQuota.stage1Default,
          namespace: namespace,
          jjContext: JjTxContext(),
          memory: memory,
        );
        final processTable = KernelProcessTable()..registerProcess(pcb);
        final gate = SyscallGate(
          processTable: processTable,
          approvalGate: ApprovalGate(handler: PolicyApprovalHandler.alwaysAllow()),
          ioCapper: IoPayloadCapper(workspaceHostRoot: tempDir.path),
          auditLogger: auditLogger,
        );
        gate.registerSyscall(
          buildLlmChatSyscallDefinition(
            router: router,
            auditLogger: auditLogger,
            contextWindowSource: resolver,
            onPagingReport: (report, {Pid pid = 1}) => pagingReports.add(report),
            onProcessStreamEvent: (_, _, _, {Pid pid = 1}) =>
                observedPids.add(pid),
          ),
        );

        final ctx = SyscallContext(
          pid: 1,
          capHandle: const CapHandle('cap_workspace_rw'),
          sessionId: 'sess_resize_test',
        );

        // Step 1: Large 128k cloud model -> 0 evictions.
        final cloudRes = await gate.invoke(
          ctx,
          SyscallRequest(
            name: 'sys_llm_chat',
            args: <String, dynamic>{
              'model': 'openrouter/openai/gpt-4o-mini',
              'turnIndex': 1,
            },
          ),
        );
        expect(cloudRes.ok, isTrue);
        expect(pagingReports.last.effectiveWindowTokens, 128000);
        expect(pagingReports.last.evictedPagesInStep, 0);
        expect(memory.pageTable.residentCleanPagesCount, 3);
        expect(observedPids, contains(1));

        // Step 2: Switch to small 4096 local model -> automatic Clean Page stub eviction fires!
        final localRes = await gate.invoke(
          ctx,
          SyscallRequest(
            name: 'sys_llm_chat',
            args: <String, dynamic>{
              'model': 'local-ollama/small-4k',
              'turnIndex': 2,
            },
          ),
        );
        expect(localRes.ok, isTrue);
        expect(pagingReports.last.effectiveWindowTokens, 4096);
        expect(pagingReports.last.evictedPagesInStep, greaterThan(0));
        expect(memory.pageTable.evictedCleanPagesCount, greaterThan(0));

        // Verify tool_call_id pairs remained intact in projected prompt sent to local model.
        final sentMessages = mockLocal.capturedRequests.single.prompt.messages;
        final assistantIds = sentMessages
            .where((m) => m.role == ProjectedRole.assistant)
            .expand((m) => m.toolCalls.map((tc) => tc.id))
            .toList(growable: false);
        final toolIds = sentMessages
            .where((m) => m.role == ProjectedRole.tool)
            .map((m) => m.toolCallId!)
            .toList(growable: false);
        expect(toolIds, equals(assistantIds));

        // Step 3: Add large Dirty conversation turn and switch to tiny 512 model -> EDQUOT: CONTEXT_FRAME_EXCEEDED
        memory.appendUserTurn(List<String>.filled(400, 'dirty_conversation').join(' '));
        final overflowRes = await gate.invoke(
          ctx,
          SyscallRequest(
            name: 'sys_llm_chat',
            args: <String, dynamic>{
              'model': 'local-ollama/tiny-512',
              'turnIndex': 3,
            },
          ),
        );
        expect(overflowRes.ok, isFalse);
        expect(overflowRes.error!.code, SyscallErrorCode.edquot);
        expect(overflowRes.error!.reason, 'CONTEXT_FRAME_EXCEEDED');
        expect(overflowRes.error!.recoverable, isTrue);

        // Verify llm_io.jsonl contains paging telemetry 5 fields + process attribution 4 fields ([D-207], [D-215]).
        await auditLogger.flush();
        final lines = await File(auditLogger.llmIoLogPath).readAsLines();
        expect(lines.length, 3);
        final rec2 = jsonDecode(lines[1]) as Map<String, dynamic>;
        expect(rec2['pid'], 1);
        expect(rec2['processName'], 'lead-agent');
        expect(rec2['ring'], 'ring2');
        expect(rec2['effectiveWindowTokens'], 4096);
        expect(rec2['evictedPagesInStep'], greaterThan(0));
        expect(rec2['evictedCleanPages'], greaterThan(0));
        expect(rec2.containsKey('residentCleanPages'), isTrue);
        expect(rec2.containsKey('stalePagesCount'), isTrue);

        resolver.close();
      },
    );
  });
}
