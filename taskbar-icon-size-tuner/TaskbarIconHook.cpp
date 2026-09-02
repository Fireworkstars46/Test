#define UNICODE
#define _UNICODE
#include <windows.h>
#include <commctrl.h>
#include <stdint.h>

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "advapi32.lib")

static const wchar_t* kAppKey = L"Software\\Taskbar Icon Size Tuner";
static const UINT kRefreshMessage = WM_APP + 0x4D1;
static const UINT_PTR kSubclassId = 0x54495354; // 'TIST'

static volatile LONG g_initialized = 0;
static volatile LONG g_iconReloadContext = 0;
static DWORD g_taskbarThreadId = 0;
static HWND g_taskSwWnd = NULL;

typedef int (WINAPI* MulDivFn)(int, int, int);
static MulDivFn g_originalMulDiv = NULL;

static DWORD ReadDword(const wchar_t* name, DWORD fallback)
{
    DWORD value = fallback;
    DWORD size = sizeof(value);
    if (RegGetValueW(HKEY_CURRENT_USER, kAppKey, name, RRF_RT_REG_DWORD, NULL, &value, &size) != ERROR_SUCCESS)
        return fallback;
    return value;
}

static int WINAPI MulDivHook(int nNumber, int nNumerator, int nDenominator)
{
    if (g_originalMulDiv && GetCurrentThreadId() == g_taskbarThreadId &&
        InterlockedCompareExchange(&g_iconReloadContext, 0, 0) > 0 &&
        nDenominator == 96 && (nNumber == 16 || nNumber == 24))
    {
        DWORD enabled = ReadDword(L"HookEnabled", 0);
        DWORD customSize = ReadDword(L"HookIconSize", 0);
        if (enabled && customSize >= 1 && customSize <= 100)
            nNumber = (int)customSize;
    }

    return g_originalMulDiv ? g_originalMulDiv(nNumber, nNumerator, nDenominator)
                            : ::MulDiv(nNumber, nNumerator, nDenominator);
}

static bool PatchMainModuleIAT(const char* importName, void* replacement, void** original)
{
    HMODULE module = GetModuleHandleW(NULL);
    if (!module)
        return false;

    BYTE* base = reinterpret_cast<BYTE*>(module);
    IMAGE_DOS_HEADER* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE)
        return false;

    IMAGE_NT_HEADERS* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE)
        return false;

    const IMAGE_DATA_DIRECTORY& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir.VirtualAddress)
        return false;

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
                return false;

            void* current = reinterpret_cast<void*>(static_cast<uintptr_t>(firstThunk->u1.Function));
            if (original)
                *original = current;

#ifdef _WIN64
            InterlockedExchangePointer(reinterpret_cast<PVOID volatile*>(&firstThunk->u1.Function), replacement);
#else
            InterlockedExchange(reinterpret_cast<LONG volatile*>(&firstThunk->u1.Function), reinterpret_cast<LONG>(replacement));
#endif

            DWORD ignored = 0;
            VirtualProtect(&firstThunk->u1.Function, sizeof(firstThunk->u1.Function), oldProtect, &ignored);
            FlushInstructionCache(GetCurrentProcess(), &firstThunk->u1.Function, sizeof(firstThunk->u1.Function));
            return true;
        }
    }

    return false;
}

static BOOL CALLBACK FindTaskSwProc(HWND hwnd, LPARAM lParam)
{
    wchar_t className[64] = {};
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
        LRESULT result = DefSubclassProc(hwnd, 0x0452, 0, 0);
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

    HWND tray = FindWindowW(L"Shell_TrayWnd", NULL);
    if (!tray)
    {
        InterlockedExchange(&g_initialized, 0);
        return;
    }

    GetWindowThreadProcessId(tray, NULL);
    g_taskbarThreadId = GetWindowThreadProcessId(tray, NULL);
    if (!g_taskbarThreadId)
    {
        InterlockedExchange(&g_initialized, 0);
        return;
    }

    // Keep the hook DLL loaded after the temporary SetWindowsHookEx hook is removed.
    HMODULE self = NULL;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                       reinterpret_cast<LPCWSTR>(&SetupHook), &self);

    g_taskSwWnd = FindTaskSwWindow();
    if (g_taskSwWnd)
        SetWindowSubclass(g_taskSwWnd, TaskSwSubclassProc, kSubclassId, 0);

    void* original = NULL;
    if (PatchMainModuleIAT("MulDiv", reinterpret_cast<void*>(&MulDivHook), &original))
        g_originalMulDiv = reinterpret_cast<MulDivFn>(original);

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
