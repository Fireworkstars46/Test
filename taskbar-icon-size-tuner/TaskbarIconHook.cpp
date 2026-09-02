#define UNICODE
#define _UNICODE
#include <windows.h>
#include <commctrl.h>
#include <stdint.h>

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")

static const wchar_t* kAppKey = L"Software\\Taskbar Icon Size Tuner";
static const UINT_PTR kTraySubclassId = 0x54495356; // TISV

static volatile LONG g_initialized = 0;
static volatile LONG g_reloadContext = 0;
static volatile LONG g_mulDivHits = 0;
static volatile LONG g_metricHits = 0;
static DWORD g_taskbarThreadId = 0;
static HWND g_trayWnd = NULL;
static ULONGLONG g_sizingWindowUntil = 0;

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
    if (ReadDword(L"HookEnabledV6", 0) == 0)
        return 0;

    DWORD size = ReadDword(L"HookIconSizeV6", 0);
    if (size < 1 || size > 100)
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
    return ::MulDiv((int)logical, (int)(dpi ? dpi : 96), 96);
}

static bool InTaskbarSizingWindow()
{
    if (GetCurrentThreadId() != g_taskbarThreadId)
        return false;

    if (InterlockedCompareExchange(&g_reloadContext, 0, 0) > 0)
        return true;

    return GetTickCount64() <= g_sizingWindowUntil;
}

static void MarkMulDivHit()
{
    LONG hits = InterlockedIncrement(&g_mulDivHits);
    if (hits <= 9999)
        WriteDword(L"DiagMulDivHitsV6", (DWORD)hits);
}

static void MarkMetricHit()
{
    LONG hits = InterlockedIncrement(&g_metricHits);
    if (hits <= 9999)
        WriteDword(L"DiagMetricHitsV6", (DWORD)hits);
}

static int WINAPI MulDivHook(int nNumber, int nNumerator, int nDenominator)
{
    DWORD custom = CustomLogicalSize();
    if (custom && InTaskbarSizingWindow() && nDenominator == 96 &&
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
    if (custom && InTaskbarSizingWindow() && IsIconMetric(index))
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
    if (custom && InTaskbarSizingWindow() && IsIconMetric(index))
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

static bool IsTraySettingsMessage(UINT msg, LPARAM lParam)
{
    if (msg != WM_SETTINGCHANGE || !lParam)
        return false;

    const wchar_t* text = reinterpret_cast<const wchar_t*>(lParam);
    return lstrcmpW(text, L"TraySettings") == 0;
}

static LRESULT CALLBACK TraySubclassProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam,
                                         UINT_PTR, DWORD_PTR)
{
    if (IsTraySettingsMessage(msg, lParam))
    {
        // Windows 10 reloads the taskbar icons synchronously from this message.
        // Keep the custom sizing hook active only for that short reload window.
        g_sizingWindowUntil = GetTickCount64() + 700;
        InterlockedIncrement(&g_reloadContext);
        WriteDword(L"DiagSmoothRefreshesV6", ReadDword(L"DiagSmoothRefreshesV6", 0) + 1);
        LRESULT result = DefSubclassProc(hwnd, msg, wParam, lParam);
        InterlockedDecrement(&g_reloadContext);
        InvalidateRect(hwnd, NULL, FALSE);
        return result;
    }

    return DefSubclassProc(hwnd, msg, wParam, lParam);
}

static void SetupHook()
{
    if (InterlockedCompareExchange(&g_initialized, 1, 0) != 0)
        return;

    WriteDword(L"DiagInjectedV6", 1);
    WriteDword(L"DiagTraySubclassV6", 0);
    WriteDword(L"DiagMulDivPatchedV6", 0);
    WriteDword(L"DiagMetricsPatchedV6", 0);
    WriteDword(L"DiagMetricsForDpiPatchedV6", 0);
    WriteDword(L"DiagMulDivHitsV6", 0);
    WriteDword(L"DiagMetricHitsV6", 0);
    WriteDword(L"DiagSmoothRefreshesV6", 0);

    g_trayWnd = FindWindowW(L"Shell_TrayWnd", NULL);
    if (!g_trayWnd)
    {
        WriteDword(L"DiagInjectedV6", 2);
        InterlockedExchange(&g_initialized, 0);
        return;
    }

    g_taskbarThreadId = GetWindowThreadProcessId(g_trayWnd, NULL);
    if (!g_taskbarThreadId)
    {
        WriteDword(L"DiagInjectedV6", 3);
        InterlockedExchange(&g_initialized, 0);
        return;
    }

    // Keep the hook alive while Explorer is running. It becomes inert when HookEnabledV6=0.
    HMODULE self = NULL;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                       reinterpret_cast<LPCWSTR>(&SetupHook), &self);

    if (SetWindowSubclass(g_trayWnd, TraySubclassProc, kTraySubclassId, 0))
        WriteDword(L"DiagTraySubclassV6", 1);

    void* original = NULL;
    int count = PatchMainModuleIAT("MulDiv", reinterpret_cast<void*>(&MulDivHook), &original);
    if (count > 0)
    {
        g_originalMulDiv = reinterpret_cast<MulDivFn>(original);
        WriteDword(L"DiagMulDivPatchedV6", (DWORD)count);
    }

    original = NULL;
    count = PatchMainModuleIAT("GetSystemMetrics", reinterpret_cast<void*>(&GetSystemMetricsHook), &original);
    if (count > 0)
    {
        g_originalGetSystemMetrics = reinterpret_cast<GetSystemMetricsFn>(original);
        WriteDword(L"DiagMetricsPatchedV6", (DWORD)count);
    }

    original = NULL;
    count = PatchMainModuleIAT("GetSystemMetricsForDpi", reinterpret_cast<void*>(&GetSystemMetricsForDpiHook), &original);
    if (count > 0)
    {
        g_originalGetSystemMetricsForDpi = reinterpret_cast<GetSystemMetricsForDpiFn>(original);
        WriteDword(L"DiagMetricsForDpiPatchedV6", (DWORD)count);
    }
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
