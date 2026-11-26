import 'dart:ffi';
import 'dart:typed_data';

/// Win32 `kernel32.dll` FFI structs and bindings for verbatim `CreateProcessW`
/// execution on Windows (zero external packages — pure `dart:ffi`).
///
/// Loaded lazily only when running on Windows via [WinKernel32.instance].
const int winHeapZeroMemory = 0x00000008;
const int winHandleFlagInherit = 0x00000001;
const int winStartfUseStdHandles = 0x00000100;
const int winCreateUnicodeEnvironment = 0x00000400;
const int winCreateNoWindow = 0x08000000;
const int winCreateSuspended = 0x00000004;
const int winResumeThreadFailed = 0xFFFFFFFF;
const int winStillActive = 259;
const int winJobObjectExtendedLimitInfoClass = 9;
const int winJobObjectLimitKillOnJobClose = 0x00002000;

final class WinSecurityAttributes extends Struct {
  @Uint32()
  external int nLength;

  external Pointer<Void> lpSecurityDescriptor;

  @Int32()
  external int bInheritHandle;
}

final class WinStartupInfoW extends Struct {
  @Uint32()
  external int cb;

  external Pointer<Uint16> lpReserved;
  external Pointer<Uint16> lpDesktop;
  external Pointer<Uint16> lpTitle;

  @Uint32()
  external int dwX;
  @Uint32()
  external int dwY;
  @Uint32()
  external int dwXSize;
  @Uint32()
  external int dwYSize;
  @Uint32()
  external int dwXCountChars;
  @Uint32()
  external int dwYCountChars;
  @Uint32()
  external int dwFillAttribute;
  @Uint32()
  external int dwFlags;

  @Uint16()
  external int wShowWindow;
  @Uint16()
  external int cbReserved2;

  external Pointer<Uint8> lpReserved2;

  @IntPtr()
  external int hStdInput;
  @IntPtr()
  external int hStdOutput;
  @IntPtr()
  external int hStdError;
}

final class WinProcessInformation extends Struct {
  @IntPtr()
  external int hProcess;
  @IntPtr()
  external int hThread;

  @Uint32()
  external int dwProcessId;
  @Uint32()
  external int dwThreadId;
}

final class WinJobObjectBasicLimitInformation extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;
  @Int64()
  external int perJobUserTimeLimit;

  @Uint32()
  external int limitFlags;

  @IntPtr()
  external int minimumWorkingSetSize;
  @IntPtr()
  external int maximumWorkingSetSize;

  @Uint32()
  external int activeProcessLimit;

  @IntPtr()
  external int affinity;

  @Uint32()
  external int priorityClass;
  @Uint32()
  external int schedulingClass;
}

final class WinIoCounters extends Struct {
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

final class WinJobObjectExtendedLimitInformation extends Struct {
  external WinJobObjectBasicLimitInformation basicLimitInformation;
  external WinIoCounters ioInfo;

  @IntPtr()
  external int processMemoryLimit;
  @IntPtr()
  external int jobMemoryLimit;
  @IntPtr()
  external int peakProcessMemoryUsed;
  @IntPtr()
  external int peakJobMemoryUsed;
}

typedef _GetProcessHeapN = IntPtr Function();
typedef WinGetProcessHeapFn = int Function();
typedef _HeapAllocN = Pointer<Void> Function(IntPtr, Uint32, IntPtr);
typedef WinHeapAllocFn = Pointer<Void> Function(int, int, int);
typedef _HeapFreeN = Int32 Function(IntPtr, Uint32, Pointer<Void>);
typedef WinHeapFreeFn = int Function(int, int, Pointer<Void>);
typedef _CreatePipeN =
    Int32 Function(
      Pointer<IntPtr>,
      Pointer<IntPtr>,
      Pointer<WinSecurityAttributes>,
      Uint32,
    );
typedef WinCreatePipeFn =
    int Function(
      Pointer<IntPtr>,
      Pointer<IntPtr>,
      Pointer<WinSecurityAttributes>,
      int,
    );
typedef _SetHandleInfoN = Int32 Function(IntPtr, Uint32, Uint32);
typedef WinSetHandleInfoFn = int Function(int, int, int);
typedef _CreateProcessWN =
    Int32 Function(
      Pointer<Uint16>,
      Pointer<Uint16>,
      Pointer<Void>,
      Pointer<Void>,
      Int32,
      Uint32,
      Pointer<Void>,
      Pointer<Uint16>,
      Pointer<WinStartupInfoW>,
      Pointer<WinProcessInformation>,
    );
typedef WinCreateProcessWFn =
    int Function(
      Pointer<Uint16>,
      Pointer<Uint16>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      int,
      Pointer<Void>,
      Pointer<Uint16>,
      Pointer<WinStartupInfoW>,
      Pointer<WinProcessInformation>,
    );
typedef _PeekNamedPipeN =
    Int32 Function(
      IntPtr,
      Pointer<Void>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint32>,
    );
typedef WinPeekNamedPipeFn =
    int Function(
      int,
      Pointer<Void>,
      int,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint32>,
    );
typedef _ReadWriteFileN =
    Int32 Function(
      IntPtr,
      Pointer<Uint8>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Void>,
    );
typedef WinReadWriteFileFn =
    int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);
typedef _GetExitCodeN = Int32 Function(IntPtr, Pointer<Uint32>);
typedef WinGetExitCodeFn = int Function(int, Pointer<Uint32>);
typedef _TerminateN = Int32 Function(IntPtr, Uint32);
typedef WinTerminateFn = int Function(int, int);
typedef _CloseHandleN = Int32 Function(IntPtr);
typedef WinCloseHandleFn = int Function(int);
typedef _CreateJobN = IntPtr Function(Pointer<Void>, Pointer<Uint16>);
typedef WinCreateJobFn = int Function(Pointer<Void>, Pointer<Uint16>);
typedef _SetJobInfoN = Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32);
typedef WinSetJobInfoFn = int Function(int, int, Pointer<Void>, int);
typedef _AssignJobN = Int32 Function(IntPtr, IntPtr);
typedef WinAssignJobFn = int Function(int, int);
typedef _ResumeThreadN = Uint32 Function(IntPtr);
typedef WinResumeThreadFn = int Function(int);

class WinKernel32 {
  WinKernel32._(DynamicLibrary lib)
    : getProcessHeap = lib
          .lookupFunction<_GetProcessHeapN, WinGetProcessHeapFn>(
            'GetProcessHeap',
          ),
      heapAlloc = lib.lookupFunction<_HeapAllocN, WinHeapAllocFn>('HeapAlloc'),
      heapFree = lib.lookupFunction<_HeapFreeN, WinHeapFreeFn>('HeapFree'),
      createPipe = lib.lookupFunction<_CreatePipeN, WinCreatePipeFn>(
        'CreatePipe',
      ),
      setHandleInformation = lib
          .lookupFunction<_SetHandleInfoN, WinSetHandleInfoFn>(
            'SetHandleInformation',
          ),
      createProcessW = lib
          .lookupFunction<_CreateProcessWN, WinCreateProcessWFn>(
            'CreateProcessW',
          ),
      peekNamedPipe = lib.lookupFunction<_PeekNamedPipeN, WinPeekNamedPipeFn>(
        'PeekNamedPipe',
      ),
      readFile = lib.lookupFunction<_ReadWriteFileN, WinReadWriteFileFn>(
        'ReadFile',
      ),
      writeFile = lib.lookupFunction<_ReadWriteFileN, WinReadWriteFileFn>(
        'WriteFile',
      ),
      getExitCodeProcess = lib.lookupFunction<_GetExitCodeN, WinGetExitCodeFn>(
        'GetExitCodeProcess',
      ),
      terminateProcess = lib.lookupFunction<_TerminateN, WinTerminateFn>(
        'TerminateProcess',
      ),
      closeHandle = lib.lookupFunction<_CloseHandleN, WinCloseHandleFn>(
        'CloseHandle',
      ),
      createJobObjectW = lib.lookupFunction<_CreateJobN, WinCreateJobFn>(
        'CreateJobObjectW',
      ),
      setInformationJobObject = lib
          .lookupFunction<_SetJobInfoN, WinSetJobInfoFn>(
            'SetInformationJobObject',
          ),
      assignProcessToJobObject = lib
          .lookupFunction<_AssignJobN, WinAssignJobFn>(
            'AssignProcessToJobObject',
          ),
      terminateJobObject = lib.lookupFunction<_TerminateN, WinTerminateFn>(
        'TerminateJobObject',
      ),
      resumeThread = lib.lookupFunction<_ResumeThreadN, WinResumeThreadFn>(
        'ResumeThread',
      );

  static WinKernel32? _instance;
  static WinKernel32 get instance =>
      _instance ??= WinKernel32._(DynamicLibrary.open('kernel32.dll'));

  final WinGetProcessHeapFn getProcessHeap;
  final WinHeapAllocFn heapAlloc;
  final WinHeapFreeFn heapFree;
  final WinCreatePipeFn createPipe;
  final WinSetHandleInfoFn setHandleInformation;
  final WinCreateProcessWFn createProcessW;
  final WinPeekNamedPipeFn peekNamedPipe;
  final WinReadWriteFileFn readFile;
  final WinReadWriteFileFn writeFile;
  final WinGetExitCodeFn getExitCodeProcess;
  final WinTerminateFn terminateProcess;
  final WinCloseHandleFn closeHandle;
  final WinCreateJobFn createJobObjectW;
  final WinSetJobInfoFn setInformationJobObject;
  final WinAssignJobFn assignProcessToJobObject;
  final WinTerminateFn terminateJobObject;
  final WinResumeThreadFn resumeThread;

  Pointer<T> alloc<T extends NativeType>(int byteCount) {
    final ptr = heapAlloc(getProcessHeap(), winHeapZeroMemory, byteCount);
    if (ptr == nullptr) throw StateError('HeapAlloc failed');
    return ptr.cast<T>();
  }

  void free(Pointer<NativeType> ptr) {
    if (ptr != nullptr) {
      heapFree(getProcessHeap(), 0, ptr.cast<Void>());
    }
  }

  Pointer<Uint16> allocUtf16(Uint16List units) {
    final ptr = alloc<Uint16>(units.length * 2);
    ptr.asTypedList(units.length).setAll(0, units);
    return ptr;
  }
}
