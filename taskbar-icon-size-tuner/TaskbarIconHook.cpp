#define UNICODE
#define _UNICODE
#include <windows.h>
#include <commctrl.h>
#include <stdint.h>

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "user32.lib")

static const wchar_t* kAppKey = L"Software\\Taskbar Icon Size Tuner";
static const UINT kRefreshMessage = WM_APP + 0x4D1;
static const UINT_PTR kSubclassId = 0x54495354; // TIST

static volatile LONG g_initialized = 0;
static volatile LONG g_iconReloadContext = 0;
static volatile LONG g_mulDivHits = 0;
static volatile LONG g_metricHits = 0;
static DWORD g_taskbarThreadId = 0;
static HWND g_taskSwWnd = NULL;
static HWND g_trayWnd = NULL;

typedef int (WINAPI* MulDivFn)(int, int, int);
typedef int (WINAPI* GetSystemMetricsFn)(int);
typedef int (WINAPI* GetSystemMetricsForDpiFn)(int, UINT);

static MulDivFn g_originalMulDiv = NULL;
static GetSystemMetricsFn g_originalGetSystemMetrics = NULL;
static GetSystemMetricsForDpiFn g_originalGetSystemMetricsForDpi = NULL;

static void WriteDword(const wchar_t* name, DWORD value)
{
    HKEY key = NULL;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kAppKey, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL) == ERROR_SUCCESS)
    {
        RegSetValueExW(key, name, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&value), sizeof(value));
        RegCloseKey(key);
    }
}

static DWORD ReadDword(const wchar_t* name, DWORD fallback)
{
    DWORD value = fallback;
    DWORD size = sizeof(value);
    if (RegGetValueW(HKEY_CURRENT_USER, kAppKey, name, RRF_RT_REG_DWORD, NULL, &value, &size) != ERROR_SUCCESS)
        return fallback;
    return value;
}

static DWORD CustomLogicalSize()
{
    DWORD enabled = ReadDword(L"HookEnabled", 0);
    DWORD size = ReadDword(L"HookIconSize", 0);
    if (!enabled || size < 1 || size > 100)
        return 0;
    return size;
}

static UINT TaskbarDpi()
{
    if (g_trayWnd)
    {
        UINT dpi = GetDpiForWindow(g_trayWnd);
        if (dpi)
            return dpi;
    }
    HDC dc = GetDC(NULL);
    if (!dc)
        return 96;
    int dpi = GetDeviceCaps(dc, LOGPIXELSX);
    ReleaseDC(NULL, dc);
    return dpi > 0 ? (UINT)dpi : 96;
}

static int ScaleLogicalSize(DWORD logical, UINT dpi)
{
    if (!logical)
        return 0;
    return ::MulDiv((int)logical, (int)(dpi ? dpi : 96), 96);
}

static bool InTaskbarIconReload()
{
    return GetCurrentThreadId() == g_taskbarThreadId &&
           InterlockedCompareExchange(&g_iconReloadContext, 0, 0) > 0;
}

static void MarkMulDivHit()
{
    LONG hits = InterlockedIncrement(&g_mulDivHits);
    if (hits <= 8)
        WriteDword(L"DiagMulDivHits", (DWORD)hits);
}

static void MarkMetricHit()
{
    LONG hits = InterlockedIncrement(&g_metricHits);
    if (hits <= 16)
        WriteDword(L"DiagMetricHits", (DWORD)hits);
}

static int WINAPI MulDivHook(int nNumber, int nNumerator, int nDenominator)
{
    DWORD custom = CustomLogicalSize();
    if (custom && InTaskbarIconReload() && nDenominator == 96 &&
        (nNumber == 16 || nNumber == 20 || nNumber == 24 || nNumber == 32))
    {
        nNumber = (int)custom;
        MarkMulDivHit();
    }

    return g_originalMulDiv ? g_originalMulDiv(nNumber, nNumerator, nDenominator)
                            : ::MulDiv(nNumber, nNumerator, nDenominator);
}

static bool IsIconMetric(int index)
{
    return index == SM_CXSMICON || index == SM_CYSMICON ||
           index == SM_CXICON || index == SM_CYICON;
}

static int WINAPI GetSystemMetricsHook(int index)
{
    DWORD custom = CustomLogicalSize();
    if (custom && InTaskbarIconReload() && IsIconMetric(index))
    {
        MarkMetricHit();
        return ScaleLogicalSize(custom, TaskbarDpi());
    }

    return g_originalGetSystemMetrics ? g_originalGetSystemMetrics(index)
                                      : ::GetSystemMetrics(index);
}

static int WINAPI GetSystemMetricsForDpiHook(int index, UINT dpi)
{
    DWORD custom = CustomLogicalSize();
    if (custom && InTaskbarIconReload() && IsIconMetric(index))
    {
        MarkMetricHit();
        return ScaleLogicalSize(custom, dpi);
    }

    return g_originalGetSystemMetricsForDpi ? g_originalGetSystemMetricsForDpi(index, dpi)
                                            : ::GetSystemMetricsForDpi(index, dpi);
}

static int PatchMainModuleIAT(const char* importName, void* replacement, void** original)
{
    HMODULE module = GetModuleHandleW(NULL);
    if (!module)
        return 0;

    BYTE* base = reinterpret_cast<BYTE*>(module);
    IMAGE_DOS_HEADER* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE)
        return 0;

    IMAGE_NT_HEADERS* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE)
        return 0;

    const IMAGE_DATA_DIRECTORY& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir.VirtualAddress)
        return 0;

    int patched = 0;
    IMAGE_IMPORT_DESCRIPTOR* desc = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base + dir.VirtualAddress);
    for (; desc->Name; ++desc)
    {
        IMAGE_THUNK_DATA* firstThunk = reinterpret_cast<IMAGE_THUNK_DATA*>(base + desc->FirstThunk);
        IMAGE_THUNK_DATA* nameThunk = desc->OriginalFirstThunk
            ? reinterpret_cast<IMAGE_THUNK_DATA*>(base + desc->OriginalFirstThunk)
            : firstThunk;

        for (; nameThunk->u1.AddressOfData; ++nameThunk, ++firstThunk)
        {
            if (IMAGE_SNAP_BY_ORDINAL(nameThunk->u1.Ordinal))
                continue;

            IMAGE_IMPORT_BY_NAME* byName = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base + nameThunk->u1.AddressOfData);
            if (lstrcmpA(reinterpret_cast<const char*>(byName->Name), importName) != 0)
                continue;

            DWORD oldProtect = 0;
            if (!VirtualProtect(&firstThunk->u1.Function, sizeof(firstThunk->u1.Function), PAGE_READWRITE, &oldProtect))
                continue;

            void* current = reinterpret_cast<void*>(static_cast<uintptr_t>(firstThunk->u1.Function));
            if (original && !*original)
                *original = current;

#ifdef _WIN64
            InterlockedExchangePointer(reinterpret_cast<PVOID volatile*>(&firstThunk->u1.Function), replacement);
#else
            InterlockedExchange(reinterpret_cast<LONG volatile*>(&firstThunk->u1.Function), reinterpret_cast<LONG>(replacement));
#endif

            DWORD ignored = 0;
            VirtualProtect(&firstThunk->u1.Function, sizeof(firstThunk->u1.Function), oldProtect, &ignored);
            FlushInstructionCache(GetCurrentProcess(), &firstThunk->u1.Function, sizeof(firstThunk->u1.Function));
            patched++;
        }
    }

    return patched;
}

static BOOL CALLBACK FindTaskSwProc(HWND hwnd, LPARAM lParam)
{
    wchar_t className[96] = {};
    if (GetClassNameW(hwnd, className, ARRAYSIZE(className)) && lstrcmpW(className, L"MSTaskSwWClass") == 0)
    {
        *reinterpret_cast<HWND*>(lParam) = hwnd;
        return FALSE;
    }
    return TRUE;
}

static HWND FindTaskSwWindow()
{
    HWND tray = FindWindowW(L"Shell_TrayWnd", NULL);
    if (!tray)
        return NULL;

    HWND found = NULL;
    EnumChildWindows(tray, FindTaskSwProc, reinterpret_cast<LPARAM>(&found));
    return found;
}

static bool IsIconReloadMessage(UINT msg)
{
    return msg == 0x043A || msg == 0x0446 || msg == 0x0452 || msg == 0x0467;
}

static LRESULT CALLBACK TaskSwSubclassProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam,
                                           UINT_PTR, DWORD_PTR)
{
    if (msg == kRefreshMessage)
    {
        InterlockedIncrement(&g_iconReloadContext);
        WriteDword(L"DiagRefreshMessages", ReadDword(L"DiagRefreshMessages", 0) + 1);

        // This is the same taskband refresh path used on DPI/icon reloads.
        LRESULT result = DefSubclassProc(hwnd, 0x0452, 0, 0);
        DefSubclassProc(hwnd, 0x043A, 0, 0);

        InterlockedDecrement(&g_iconReloadContext);
        InvalidateRect(hwnd, NULL, TRUE);
        UpdateWindow(hwnd);
        return result;
    }

    if (IsIconReloadMessage(msg))
    {
        InterlockedIncrement(&g_iconReloadContext);
        LRESULT result = DefSubclassProc(hwnd, msg, wParam, lParam);
        InterlockedDecrement(&g_iconReloadContext);
        return result;
    }

    return DefSubclassProc(hwnd, msg, wParam, lParam);
}

static void SetupHook()
{
    if (InterlockedCompareExchange(&g_initialized, 1, 0) != 0)
        return;

    WriteDword(L"DiagInjected", 1);
    WriteDword(L"DiagTaskSwFound", 0);
    WriteDword(L"DiagMulDivPatched", 0);
    WriteDword(L"DiagMetricsPatched", 0);
    WriteDword(L"DiagMetricsForDpiPatched", 0);
    WriteDword(L"DiagMulDivHits", 0);
    WriteDword(L"DiagMetricHits", 0);

    g_trayWnd = FindWindowW(L"Shell_TrayWnd", NULL);
    if (!g_trayWnd)
    {
        WriteDword(L"DiagInjected", 2);
        InterlockedExchange(&g_initialized, 0);
        return;
    }

    g_taskbarThreadId = GetWindowThreadProcessId(g_trayWnd, NULL);
    if (!g_taskbarThreadId)
    {
        WriteDword(L"DiagInjected", 3);
        InterlockedExchange(&g_initialized, 0);
        return;
    }

    // Keep this DLL loaded after the temporary SetWindowsHookEx hook is removed.
    HMODULE self = NULL;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                       reinterpret_cast<LPCWSTR>(&SetupHook), &self);

    g_taskSwWnd = FindTaskSwWindow();
    if (g_taskSwWnd)
    {
        WriteDword(L"DiagTaskSwFound", 1);
        SetWindowSubclass(g_taskSwWnd, TaskSwSubclassProc, kSubclassId, 0);
    }

    void* original = NULL;
    int count = PatchMainModuleIAT("MulDiv", reinterpret_cast<void*>(&MulDivHook), &original);
    if (count > 0)
    {
        g_originalMulDiv = reinterpret_cast<MulDivFn>(original);
        WriteDword(L"DiagMulDivPatched", (DWORD)count);
    }

    original = NULL;
    count = PatchMainModuleIAT("GetSystemMetrics", reinterpret_cast<void*>(&GetSystemMetricsHook), &original);
    if (count > 0)
    {
        g_originalGetSystemMetrics = reinterpret_cast<GetSystemMetricsFn>(original);
        WriteDword(L"DiagMetricsPatched", (DWORD)count);
    }

    original = NULL;
    count = PatchMainModuleIAT("GetSystemMetricsForDpi", reinterpret_cast<void*>(&GetSystemMetricsForDpiHook), &original);
    if (count > 0)
    {
        g_originalGetSystemMetricsForDpi = reinterpret_cast<GetSystemMetricsForDpiFn>(original);
        WriteDword(L"DiagMetricsForDpiPatched", (DWORD)count);
    }

    if (g_taskSwWnd)
        PostMessageW(g_taskSwWnd, kRefreshMessage, 0, 0);
}

extern "C" __declspec(dllexport) LRESULT CALLBACK TunerHookProc(int code, WPARAM wParam, LPARAM lParam)
{
    if (code >= 0)
        SetupHook();
    return CallNextHookEx(NULL, code, wParam, lParam);
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH)
        DisableThreadLibraryCalls(instance);
    return TRUE;
}
