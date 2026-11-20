import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:ffi/ffi.dart';

import '../fs/host_fs_driver.dart';
import 'sys_exec_classifier.dart';

const int _jobObjectExtendedLimitInformationClass = 9;
const int _jobObjectLimitKillOnJobClose = 0x00002000;
const int _processSetQuota = 0x0100;
const int _processTerminate = 0x0001;
const int _processQueryLimitedInformation = 0x1000;
const int _stillActive = 259;
const int _errorAccessDenied = 5;
const int _errorInvalidParameter = 87;

/// Win32 `JOBOBJECT_BASIC_LIMIT_INFORMATION` (64 bytes on 64-bit Windows, natural 8-byte alignment; NO `@Packed`) ([D-016]).
final class JobObjectBasicLimitInformation extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;

  @Int64()
  external int perJobUserTimeLimit;

  /// Byte offset 16: `LimitFlags` (`0x00002000` = `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`).
  @Uint32()
  external int limitFlags;

  @UintPtr()
  external int minimumWorkingSetSize;

  @UintPtr()
  external int maximumWorkingSetSize;

  @Uint32()
  external int activeProcessLimit;

  @UintPtr()
  external int affinity;

  @Uint32()
  external int priorityClass;

  @Uint32()
  external int schedulingClass;
}

/// Win32 `IO_COUNTERS` (48 bytes on 64-bit Windows) ([D-016]).
final class IoCounters extends Struct {
  @Uint64()
  external int readOperationCount;

  @Uint64()
  external int writeOperationCount;

  @Uint64()
  external int otherOperationCount;

  @Uint64()
  external int readTransferCount;

  @Uint64()
  external int writeTransferCount;

  @Uint64()
  external int otherTransferCount;
}

/// Win32 `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` (exact 144 bytes on 64-bit Windows; NO `@Packed`) ([D-016]).
final class JobObjectExtendedLimitInformation extends Struct {
  external JobObjectBasicLimitInformation basicLimitInformation;
  external IoCounters ioInfo;

  @UintPtr()
  external int processMemoryLimit;

  @UintPtr()
  external int jobMemoryLimit;

  @UintPtr()
  external int peakProcessMemoryUsed;

  @UintPtr()
  external int peakJobMemoryUsed;
}

typedef CreateJobObjectNative = IntPtr Function(
  Pointer<Void> lpJobAttributes,
  Pointer<Void> lpName,
);
typedef CreateJobObjectDart = int Function(
  Pointer<Void> lpJobAttributes,
  Pointer<Void> lpName,
);

typedef SetInformationJobObjectNative = Int32 Function(
  IntPtr hJob,
  Int32 jobObjectInfoClass,
  Pointer<Void> lpJobObjectInfo,
  Uint32 cbJobObjectInfoLength,
);
typedef SetInformationJobObjectDart = int Function(
  int hJob,
  int jobObjectInfoClass,
  Pointer<Void> lpJobObjectInfo,
  int cbJobObjectInfoLength,
);

typedef OpenProcessNative = IntPtr Function(
  Uint32 dwDesiredAccess,
  Int32 bInheritHandle,
  Uint32 dwProcessId,
);
typedef OpenProcessDart = int Function(
  int dwDesiredAccess,
  int bInheritHandle,
  int dwProcessId,
);

typedef AssignProcessToJobObjectNative = Int32 Function(
  IntPtr hJob,
  IntPtr hProcess,
);
typedef AssignProcessToJobObjectDart = int Function(
  int hJob,
  int hProcess,
);

typedef TerminateJobObjectNative = Int32 Function(
  IntPtr hJob,
  Uint32 uExitCode,
);
typedef TerminateJobObjectDart = int Function(
  int hJob,
  int uExitCode,
);

typedef GetExitCodeProcessNative = Int32 Function(
  IntPtr hProcess,
  Pointer<Uint32> lpExitCode,
);
typedef GetExitCodeProcessDart = int Function(
  int hProcess,
  Pointer<Uint32> lpExitCode,
);

typedef CloseHandleNative = Int32 Function(IntPtr hObject);
typedef CloseHandleDart = int Function(int hObject);

typedef GetLastErrorNative = Uint32 Function();
typedef GetLastErrorDart = int Function();

/// Minimal `kernel32.dll` FFI bindings for Job Object lifecycle and OS PID liveness checks ([D-016]).
final class Win32Kernel32 {
  Win32Kernel32() : _lib = DynamicLibrary.open('kernel32.dll') {
    createJobObjectW =
        _lib.lookupFunction<CreateJobObjectNative, CreateJobObjectDart>(
      'CreateJobObjectW',
    );
    setInformationJobObject = _lib.lookupFunction<
        SetInformationJobObjectNative, SetInformationJobObjectDart>(
      'SetInformationJobObject',
    );
    openProcess = _lib.lookupFunction<OpenProcessNative, OpenProcessDart>(
      'OpenProcess',
    );
    assignProcessToJobObject = _lib.lookupFunction<
        AssignProcessToJobObjectNative, AssignProcessToJobObjectDart>(
      'AssignProcessToJobObject',
    );
    terminateJobObject = _lib
        .lookupFunction<TerminateJobObjectNative, TerminateJobObjectDart>(
      'TerminateJobObject',
    );
    getExitCodeProcess = _lib
        .lookupFunction<GetExitCodeProcessNative, GetExitCodeProcessDart>(
      'GetExitCodeProcess',
    );
    closeHandle = _lib.lookupFunction<CloseHandleNative, CloseHandleDart>(
      'CloseHandle',
    );
    getLastError = _lib.lookupFunction<GetLastErrorNative, GetLastErrorDart>(
      'GetLastError',
    );
  }

  final DynamicLibrary _lib;
  late final CreateJobObjectDart createJobObjectW;
  late final SetInformationJobObjectDart setInformationJobObject;
  late final OpenProcessDart openProcess;
  late final AssignProcessToJobObjectDart assignProcessToJobObject;
  late final TerminateJobObjectDart terminateJobObject;
  late final GetExitCodeProcessDart getExitCodeProcess;
  late final CloseHandleDart closeHandle;
  late final GetLastErrorDart getLastError;

  /// Returns true if OS process [pid] is currently alive (`STILL_ACTIVE`).
  bool isProcessAlive(int pid) {
    if (pid <= 0) {
      return false;
    }
    final hProc = openProcess(_processQueryLimitedInformation, 0, pid);
    if (hProc == 0) {
      return false;
    }
    final exitCodePtr = calloc<Uint32>();
    try {
      final ok = getExitCodeProcess(hProc, exitCodePtr);
      if (ok == 0) {
        return false;
      }
      return exitCodePtr.value == _stillActive;
    } finally {
      calloc.free(exitCodePtr);
      closeHandle(hProc);
    }
  }
}

/// Executes external commands inside a Windows Job Object (`KILL_ON_JOB_CLOSE`, no breakaway) ([D-016]).
class Win32JobExecDriver {
  Win32JobExecDriver({
    required this.namespace,
    EnsureActiveTransactionCallback? ensureActiveTransaction,
    SyncWorkingCopySnapshotCallback? syncWorkingCopySnapshot,
    EnsureActiveTransactionForPcbCallback? ensureActiveTransactionForPcb,
    SyncWorkingCopySnapshotForPcbCallback? syncWorkingCopySnapshotForPcb,
    IoPayloadCapper? ioCapper,
    SysExecClassifier? classifier,
    Win32Kernel32? kernel32,
  })  : _ensureActiveTransaction = ensureActiveTransaction,
        _syncWorkingCopySnapshot = syncWorkingCopySnapshot,
        _ensureActiveTransactionForPcb = ensureActiveTransactionForPcb,
        _syncWorkingCopySnapshotForPcb = syncWorkingCopySnapshotForPcb,
        _ioCapper = ioCapper ??
            IoPayloadCapper(workspaceHostRoot: namespace.workspaceHostRoot),
        classifier = classifier ?? SysExecClassifier(namespace: namespace),
        _kernel32 = kernel32;

  factory Win32JobExecDriver.forWorkspace(
    String workspaceHostRoot, {
    EnsureActiveTransactionCallback? ensureActiveTransaction,
    SyncWorkingCopySnapshotCallback? syncWorkingCopySnapshot,
    EnsureActiveTransactionForPcbCallback? ensureActiveTransactionForPcb,
    SyncWorkingCopySnapshotForPcbCallback? syncWorkingCopySnapshotForPcb,
    IoPayloadCapper? ioCapper,
  }) {
    final ns = VfsNamespace(workspaceHostRoot: workspaceHostRoot);
    return Win32JobExecDriver(
      namespace: ns,
      ensureActiveTransaction: ensureActiveTransaction,
      syncWorkingCopySnapshot: syncWorkingCopySnapshot,
      ensureActiveTransactionForPcb: ensureActiveTransactionForPcb,
      syncWorkingCopySnapshotForPcb: syncWorkingCopySnapshotForPcb,
      ioCapper: ioCapper,
    );
  }

  static const int defaultTimeoutMs = 60000;
  static const int minTimeoutMs = 100;
  static const int maxTimeoutMs = 300000;
  static const int jobExtendedLimitInfoStructBytes = 144;
  static const int jobLimitFlagsByteOffset = 16;
  static const int killOnJobCloseFlag = _jobObjectLimitKillOnJobClose;

  static final RegExp _sensitiveEnvPattern = RegExp(
    r'^(OPENROUTER_API_KEY|OLLAMA_API_KEY|.*_(API_KEY|SECRET|TOKEN|PASSWORD))$',
    caseSensitive: false,
  );

  static const Set<String> _shellExecutables = <String>{
    'cmd',
    'powershell',
    'pwsh',
    'sh',
    'bash',
    'wsl',
    'zsh',
    'fish',
  };

  final VfsNamespace namespace;
  final EnsureActiveTransactionCallback? _ensureActiveTransaction;
  final SyncWorkingCopySnapshotCallback? _syncWorkingCopySnapshot;
  final EnsureActiveTransactionForPcbCallback? _ensureActiveTransactionForPcb;
  final SyncWorkingCopySnapshotForPcbCallback? _syncWorkingCopySnapshotForPcb;
  final IoPayloadCapper _ioCapper;
  final SysExecClassifier classifier;
  Win32Kernel32? _kernel32;

  Win32Kernel32 get _k32 => _kernel32 ??= Win32Kernel32();

  /// Removes API keys, secrets, and tokens from [baseEnvironment] before spawning child processes ([D-016]).
  static Map<String, String> buildSanitizedEnvironment([
    Map<String, String>? baseEnvironment,
  ]) {
    final source = baseEnvironment ?? Platform.environment;
    final sanitized = <String, String>{};
    for (final entry in source.entries) {
      if (_sensitiveEnvPattern.hasMatch(entry.key)) {
        continue;
      }
      sanitized[entry.key] = entry.value;
    }
    return sanitized;
  }

  /// Executes a command inside an isolated Win32 Job Object and returns structured results ([D-016]).
  Future<SyscallResult<Map<String, dynamic>>> execute({
    required String command,
    List<String>? args,
    String? workingDir,
    int? timeoutMs,
    CancellationToken? cancelToken,
    String sessionId = 'exec',
    int syscallSeq = 0,
    VfsNamespace? namespaceOverride,
    ProcessControlBlock? callerPcb,
  }) async {
    final effectiveNamespace = namespaceOverride ?? namespace;
    final validationError = validateRawArgs(<String, dynamic>{
      'command': command,
      'args': ?args,
      'workingDir': ?workingDir,
      'timeoutMs': ?timeoutMs,
    });
    if (validationError != null) {
      return SyscallResult<Map<String, dynamic>>.failure(validationError);
    }

    final normalized = SysExecCommandNormalizer.normalize(
      command: command,
      args: args,
    );
    final effectiveWorkingDir =
        (workingDir == null || workingDir.trim().isEmpty)
            ? VfsNamespace.virtualRoot
            : workingDir.trim();
    final effectiveTimeoutMs = timeoutMs ?? defaultTimeoutMs;

    final wdPrecheck = _resolveWorkingDir(
      effectiveWorkingDir,
      namespaceOverride: effectiveNamespace,
    );
    if (!wdPrecheck.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(wdPrecheck.error!);
    }
    final hostWorkingDir = wdPrecheck.value!.hostPath;

    if (cancelToken?.isCancelled ?? false) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.ecancelled,
          reason: 'CANCELLED',
          message: 'sys_exec cancelled before execution.',
          recoverable: true,
        ),
      );
    }

    if (!Platform.isWindows) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'UNSUPPORTED_PLATFORM',
          message: 'Win32JobExecDriver requires Windows.',
          recoverable: false,
        ),
      );
    }

    final extSize = sizeOf<JobObjectExtendedLimitInformation>();
    if (extSize != jobExtendedLimitInfoStructBytes) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'JOB_STRUCT_SIZE_MISMATCH',
          message:
              'Expected 144-byte JOBOBJECT_EXTENDED_LIMIT_INFORMATION, got $extSize.',
          recoverable: false,
        ),
      );
    }

    // 1. Ensure isolated CoW working change before running external process ([D-015], [D-016]).
    if (callerPcb != null && _ensureActiveTransactionForPcb != null) {
      final txRes = await _ensureActiveTransactionForPcb(callerPcb);
      if (!txRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(txRes.error!);
      }
    } else if (_ensureActiveTransaction != null) {
      final txRes = await _ensureActiveTransaction();
      if (!txRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(txRes.error!);
      }
    }

    final k32 = _k32;
    final infoPtr = calloc<JobObjectExtendedLimitInformation>();
    var hJob = 0;
    var txIsolated = true;

    try {
      // Configure ONLY JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE (0x2000) at byte offset 16; NEVER set BREAKAWAY_OK.
      infoPtr.ref.basicLimitInformation.limitFlags = killOnJobCloseFlag;
      final flagsAtOffset16 =
          infoPtr.cast<Uint32>()[jobLimitFlagsByteOffset ~/ 4];
      if (flagsAtOffset16 != killOnJobCloseFlag) {
        return const SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.eio,
            reason: 'JOB_LIMIT_OFFSET_MISMATCH',
            message: 'LimitFlags alignment check failed at offset 16.',
            recoverable: false,
          ),
        );
      }

      // 2. Create and configure Win32 Job Object.
      hJob = k32.createJobObjectW(nullptr, nullptr);
      if (hJob == 0) {
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.eio,
            reason: 'CREATE_JOB_OBJECT_FAILED',
            message:
                'CreateJobObjectW failed with Win32 error ${k32.getLastError()}.',
            recoverable: false,
          ),
        );
      }

      final setOk = k32.setInformationJobObject(
        hJob,
        _jobObjectExtendedLimitInformationClass,
        infoPtr.cast<Void>(),
        extSize,
      );
      if (setOk == 0) {
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.eio,
            reason: 'SET_JOB_INFO_FAILED',
            message:
                'SetInformationJobObject failed with Win32 error ${k32.getLastError()}.',
            recoverable: false,
          ),
        );
      }

      // 3. Resolve executable/args and sanitized environment.
      final spawnPlan = _buildSpawnPlan(
        normalized: normalized,
        hostWorkingDir: hostWorkingDir,
        effectiveNamespace: effectiveNamespace,
      );
      final sanitizedEnv = buildSanitizedEnvironment();

      final stopwatch = Stopwatch()..start();
      final Process process;
      try {
        process = await Process.start(
          spawnPlan.executable,
          spawnPlan.arguments,
          workingDirectory: hostWorkingDir,
          environment: sanitizedEnv,
          includeParentEnvironment: false,
          runInShell: false,
        );
      } on ProcessException catch (e) {
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.enoent,
            reason: 'PROCESS_START_FAILED',
            message:
                'Failed to start "${spawnPlan.executable}": ${e.message}',
            recoverable: true,
          ),
        );
      }

      // 4. Immediately assign process to Job Object synchronously before stream consumption.
      final assignError = await _assignProcessWithRaceHandling(
        k32: k32,
        hJob: hJob,
        process: process,
      );
      if (assignError != null) {
        return SyscallResult<Map<String, dynamic>>.failure(assignError);
      }

      // 5. Collect stdout/stderr and manage timeout / cooperative cancellation.
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final stdoutSub = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(stdoutBuffer.write);
      final stderrSub = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(stderrBuffer.write);

      var timedOut = false;
      var cancelled = false;
      var terminatedByKernel = false;

      void terminateTree() {
        if (terminatedByKernel) {
          return;
        }
        terminatedByKernel = true;
        k32.terminateJobObject(hJob, 137);
      }

      final timer = Timer(Duration(milliseconds: effectiveTimeoutMs), () {
        if (!cancelled) {
          timedOut = true;
          terminateTree();
        }
      });

      StreamSubscription<void>? cancelSub;
      if (cancelToken != null) {
        cancelSub = cancelToken.onCancel.asStream().listen((_) {
          if (!timedOut) {
            cancelled = true;
            terminateTree();
          }
        });
        if (cancelToken.isCancelled && !timedOut) {
          cancelled = true;
          terminateTree();
        }
      }

      final int exitCode;
      try {
        exitCode = await process.exitCode;
        await Future.wait<void>(<Future<void>>[
          stdoutSub.asFuture<void>(),
          stderrSub.asFuture<void>(),
        ]).timeout(
          const Duration(seconds: 2),
          onTimeout: () => const <void>[],
        );
      } finally {
        timer.cancel();
        await cancelSub?.cancel();
        await stdoutSub.cancel();
        await stderrSub.cancel();
      }

      stopwatch.stop();
      final durationMs = stopwatch.elapsedMilliseconds;
      final rawStdout = stdoutBuffer.toString();
      final rawStderr = stderrBuffer.toString();

      if (cancelled) {
        return const SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.ecancelled,
            reason: 'CANCELLED',
            message: 'External command execution was cancelled; process tree terminated.',
            recoverable: true,
          ),
        );
      }

      if (timedOut) {
        // Allow brief kernel cleanup window for descendant process teardown.
        await Future<void>.delayed(const Duration(milliseconds: 100));

        final cappedOut = await _ioCapper.capText(
          text: rawStdout,
          sessionId: sessionId,
          syscallSeq: syscallSeq,
          syscallName: 'sys_exec',
          fieldSuffix: 'stdout',
        );
        final cappedErr = await _ioCapper.capText(
          text: rawStderr,
          sessionId: sessionId,
          syscallSeq: syscallSeq,
          syscallName: 'sys_exec',
          fieldSuffix: 'stderr',
        );

        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.etimedout,
            reason: 'EXEC_TIMEOUT',
            message:
                'Command "${normalized.command}" timed out after ${effectiveTimeoutMs}ms and its Job Object process tree was terminated.',
            recoverable: true,
            hint:
                'Inspect partial stdout/stderr in details, optimize or narrow the command, or increase timeoutMs (up to 300000ms).',
            details: <String, dynamic>{
              'exitCode': exitCode,
              'stdout': cappedOut.text,
              'stderr': cappedErr.text,
              'timedOut': true,
              'durationMs': durationMs,
              'truncatedStdout': cappedOut.truncated,
              'truncatedStderr': cappedErr.truncated,
            },
          ),
        );
      }

      return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
        'exitCode': exitCode,
        'stdout': rawStdout,
        'stderr': rawStderr,
        'timedOut': false,
        'durationMs': durationMs,
        'truncatedStdout': false,
        'truncatedStderr': false,
      });
    } finally {
      if (hJob != 0) {
        k32.closeHandle(hJob);
      }
      calloc.free(infoPtr);
      if (txIsolated) {
        if (callerPcb != null && _syncWorkingCopySnapshotForPcb != null) {
          await _syncWorkingCopySnapshotForPcb(callerPcb);
        } else if (_syncWorkingCopySnapshot != null) {
          await _syncWorkingCopySnapshot();
        }
      }
    }
  }

  /// Assigns [process] synchronously to [hJob], safely handling ultra-fast exits.
  Future<SyscallError?> _assignProcessWithRaceHandling({
    required Win32Kernel32 k32,
    required int hJob,
    required Process process,
  }) async {
    final hProc = k32.openProcess(
      _processSetQuota | _processTerminate,
      0,
      process.pid,
    );
    if (hProc == 0) {
      final err = k32.getLastError();
      if (await _didProcessExitImmediately(process, err)) {
        return null;
      }
      process.kill(ProcessSignal.sigkill);
      return SyscallError(
        code: SyscallErrorCode.eio,
        reason: 'OPEN_PROCESS_FAILED',
        message: 'OpenProcess(pid=${process.pid}) failed with Win32 error $err.',
        recoverable: false,
      );
    }

    final assignOk = k32.assignProcessToJobObject(hJob, hProc);
    final assignErr = assignOk == 0 ? k32.getLastError() : 0;
    k32.closeHandle(hProc);

    if (assignOk == 0) {
      if (await _didProcessExitImmediately(process, assignErr)) {
        return null;
      }
      process.kill(ProcessSignal.sigkill);
      return SyscallError(
        code: SyscallErrorCode.eio,
        reason: 'ASSIGN_JOB_OBJECT_FAILED',
        message:
            'AssignProcessToJobObject(pid=${process.pid}) failed with Win32 error $assignErr.',
        recoverable: false,
      );
    }

    return null;
  }

  Future<bool> _didProcessExitImmediately(Process process, int win32Error) async {
    if (win32Error != _errorInvalidParameter &&
        win32Error != _errorAccessDenied) {
      return false;
    }
    try {
      await process.exitCode.timeout(const Duration(milliseconds: 50));
      return true;
    } on TimeoutException {
      return false;
    }
  }

  ({String executable, List<String> arguments}) _buildSpawnPlan({
    required NormalizedExecCommand normalized,
    required String hostWorkingDir,
    VfsNamespace? effectiveNamespace,
  }) {
    final ns = effectiveNamespace ?? namespace;
    final exeBase = _normalizeExeBase(normalized.command);
    if (normalized.hadShellMeta && !_shellExecutables.contains(exeBase)) {
      // Execute approved shell-syntax commands via explicit powershell.exe with runInShell: false
      // so the root PID is directly captured and bound to the Job Object ([D-016]).
      final fullCommand = normalized.args.isEmpty
          ? normalized.command
          : '${normalized.command} ${normalized.args.map(_quotePowerShellArg).join(' ')}';
      return (
        executable: 'powershell.exe',
        arguments: <String>[
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          fullCommand,
        ],
      );
    }

    final resolvedArgs = exeBase == 'dart'
        ? normalized.args
            .map((a) => SysExecClassifier.resolveHostCommandArg(
                  ns,
                  hostWorkingDir,
                  a,
                ))
            .toList(growable: false)
        : normalized.args;

    return (
      executable: normalized.command,
      arguments: resolvedArgs,
    );
  }

  SyscallResult<VfsPathResolution> _resolveWorkingDir(
    String rawWorkingDir, {
    VfsNamespace? namespaceOverride,
  }) {
    final effectiveNamespace = namespaceOverride ?? namespace;
    final resolved = effectiveNamespace.resolveVirtualPath(
      rawWorkingDir,
      allowRoot: true,
      checkProtected: true,
      checkSymlinks: true,
    );
    if (!resolved.ok) {
      return resolved;
    }
    final res = resolved.value!;
    final type = FileSystemEntity.typeSync(res.hostPath, followLinks: true);
    if (type == FileSystemEntityType.notFound) {
      return SyscallResult<VfsPathResolution>.failure(
        SyscallError(
          code: SyscallErrorCode.enoent,
          reason: 'WORKING_DIR_NOT_FOUND',
          message: 'workingDir "${res.virtualPath}" does not exist.',
          recoverable: true,
        ),
      );
    }
    if (type != FileSystemEntityType.directory) {
      return SyscallResult<VfsPathResolution>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'WORKING_DIR_NOT_A_DIRECTORY',
          message: 'workingDir "${res.virtualPath}" is not a directory.',
          recoverable: true,
        ),
      );
    }
    return resolved;
  }

  /// Registers `sys_exec` on [gate].
  void registerSyscalls(SyscallGate gate) {
    gate.registerSyscall(buildSyscallDefinition());
  }

  /// Builds the Stage 1..8 [SyscallDefinition] for `sys_exec` ([D-002], [D-006], [D-016]).
  SyscallDefinition buildSyscallDefinition() {
    return SyscallDefinition(
      name: 'sys_exec',
      requiredRight: CapRight.exec,
      kind: 'execute',
      applyIoCap: true,
      cappedTextFields: const <String>['stdout', 'stderr'],
      validateArgs: validateRawArgs,
      normalizeArgs: normalizeRawArgs,
      checkPreconditions: (pcb, args) async {
        final workingDir =
            (args['workingDir'] as String?) ?? VfsNamespace.virtualRoot;
        final res = _resolveWorkingDir(
          workingDir,
          namespaceOverride: pcb.namespace,
        );
        return res.ok ? null : res.error;
      },
      evaluatePolicy: (pcb, args) async {
        final command = args['command'] as String;
        final rawArgs = args['args'] as List<dynamic>?;
        final resolvedArgs = rawArgs?.cast<String>() ?? const <String>[];
        final workingDir = args['workingDir'] as String?;
        final timeoutMs = (args['timeoutMs'] as int?) ?? defaultTimeoutMs;
        return classifier
            .classify(
              command: command,
              args: resolvedArgs,
              workingDir: workingDir,
              timeoutMs: timeoutMs,
              namespaceOverride: pcb.namespace,
            )
            .decision;
      },
      approvalPreviewBuilder: (hookCtx) async {
        final command = (hookCtx.args['command'] as String?) ?? '';
        final argsList =
            (hookCtx.args['args'] as List<dynamic>?)?.cast<String>() ??
                const <String>[];
        final workingDir =
            (hookCtx.args['workingDir'] as String?) ?? VfsNamespace.virtualRoot;
        final timeoutMs =
            (hookCtx.args['timeoutMs'] as int?) ?? defaultTimeoutMs;
        final fullCmd =
            argsList.isEmpty ? command : '$command ${argsList.join(' ')}';
        final classification = classifier.classify(
          command: command,
          args: argsList,
          workingDir: workingDir,
          timeoutMs: timeoutMs,
        );
        return ApprovalPreview(
          title: 'Execute external command: $fullCmd',
          kind: 'execute',
          content: <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'content',
              'content': <String, dynamic>{
                'type': 'text',
                'text':
                    'Command: $fullCmd\nWorkingDir: $workingDir\nTimeout: ${timeoutMs}ms\nReason: ${classification.reason}',
              },
            },
          ],
          metadata: <String, dynamic>{
            'command': command,
            'args': argsList,
            'workingDir': workingDir,
            'timeoutMs': timeoutMs,
            'classificationReason': classification.reason,
          },
        );
      },
      approvalSignatureBuilder: (args) {
        final command = (args['command'] as String?) ?? '';
        final argsList =
            (args['args'] as List<dynamic>?)?.cast<String>() ?? const <String>[];
        final workingDir =
            (args['workingDir'] as String?) ?? VfsNamespace.virtualRoot;
        return '$command\u0000${argsList.join('\u0000')}\u0000$workingDir';
      },
      handler: (exec) {
        final rawArgs = exec.args['args'] as List<dynamic>?;
        return execute(
          command: exec.args['command'] as String,
          args: rawArgs?.cast<String>(),
          workingDir: exec.args['workingDir'] as String?,
          timeoutMs: exec.args['timeoutMs'] as int?,
          cancelToken: exec.context.cancelToken,
          sessionId: exec.context.sessionId,
          syscallSeq: exec.syscallSeq,
          namespaceOverride: exec.pcb.namespace,
          callerPcb: exec.pcb,
        );
      },
    );
  }

  /// Canonical tool schema for `sys_exec` ([D-007], [D-016]).
  static List<SyscallToolSchema> toolSchemas() {
    return <SyscallToolSchema>[
      SyscallToolSchema(
        name: 'sys_exec',
        description:
            'Execute an external command inside a Win32 Job Object within /workspace. Safe `dart test`, `dart analyze`, and `dart format --output=none` run immediately; other commands require user approval. Raw git/jj CLI commands are blocked by kernel policy.',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'command': <String, dynamic>{
              'type': 'string',
              'description':
                  'Executable name (or single command string when args is omitted).',
            },
            'args': <String, dynamic>{
              'type': 'array',
              'items': <String, dynamic>{'type': 'string'},
              'description': 'Optional array of command-line arguments.',
            },
            'workingDir': <String, dynamic>{
              'type': 'string',
              'description':
                  'Virtual working directory under /workspace (default "/workspace").',
            },
            'timeoutMs': <String, dynamic>{
              'type': 'integer',
              'description':
                  'Timeout in milliseconds (100..300000, default 60000).',
            },
          },
          'required': <String>['command'],
        },
      ),
    ];
  }

  /// Stage 1 argument validator for `sys_exec`.
  static SyscallError? validateRawArgs(Map<String, dynamic> args) {
    final command = args['command'];
    if (command is! String || command.trim().isEmpty) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "command" must be a non-empty string.',
        recoverable: true,
      );
    }

    final rawArgs = args['args'];
    if (rawArgs != null) {
      if (rawArgs is! List<dynamic> || rawArgs.any((e) => e is! String)) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_ARGS',
          message: 'Argument "args" must be a list of strings when provided.',
          recoverable: true,
        );
      }
    } else if (!SysExecCommandNormalizer.containsShellMetacharacters(command)) {
      try {
        final split = SysExecCommandNormalizer.splitQuotedCommand(command);
        if (split.isEmpty) {
          return const SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'INVALID_ARGS',
            message: 'Argument "command" must not be empty.',
            recoverable: true,
          );
        }
      } on FormatException catch (e) {
        return SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_COMMAND_QUOTING',
          message: e.message,
          recoverable: true,
        );
      }
    }

    final workingDir = args['workingDir'];
    if (workingDir != null &&
        (workingDir is! String || workingDir.trim().isEmpty)) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "workingDir" must be a non-empty string.',
        recoverable: true,
      );
    }

    final timeoutMs = args['timeoutMs'];
    if (timeoutMs != null) {
      if (timeoutMs is! int ||
          timeoutMs < minTimeoutMs ||
          timeoutMs > maxTimeoutMs) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_TIMEOUT',
          message:
              'Argument "timeoutMs" must be an integer between $minTimeoutMs and $maxTimeoutMs.',
          recoverable: true,
        );
      }
    }

    return null;
  }

  /// Stage 1 normalizer splitting single-string `args: null` commands prior to Hook/Classifier/Exec ([D-016]).
  static Map<String, dynamic> normalizeRawArgs(Map<String, dynamic> args) {
    final normalized = SysExecCommandNormalizer.normalize(
      command: args['command'] as String,
      args: (args['args'] as List<dynamic>?)?.cast<String>(),
    );

    final out = Map<String, dynamic>.from(args);
    out['command'] = normalized.command;
    if (args['args'] != null || normalized.wasSplitFromSingleString) {
      out['args'] = normalized.args;
    }
    if (out['workingDir'] == null) {
      out['workingDir'] = VfsNamespace.virtualRoot;
    } else {
      out['workingDir'] = (out['workingDir'] as String).trim();
    }
    if (out['timeoutMs'] == null) {
      out['timeoutMs'] = defaultTimeoutMs;
    }
    return out;
  }

  static String _normalizeExeBase(String rawExe) {
    final normalized = rawExe.trim().replaceAll('/', r'\');
    final slashIdx = normalized.lastIndexOf(r'\');
    final base = slashIdx >= 0 ? normalized.substring(slashIdx + 1) : normalized;
    final lower = base.toLowerCase();
    for (final ext in const <String>['.exe', '.cmd', '.bat']) {
      if (lower.endsWith(ext)) {
        return lower.substring(0, lower.length - ext.length);
      }
    }
    return lower;
  }

  static String _quotePowerShellArg(String arg) {
    if (arg.isEmpty) {
      return "''";
    }
    final safe = RegExp(r'^[a-zA-Z0-9._:/\\-]+$');
    if (safe.hasMatch(arg)) {
      return arg;
    }
    return "'${arg.replaceAll("'", "''")}'";
  }
}
