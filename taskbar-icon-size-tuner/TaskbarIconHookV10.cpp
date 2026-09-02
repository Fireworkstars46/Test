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
static const wchar_t* kExplorerAdvancedKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced";
static const UINT kApplyMessage = WM_APP + 0x5A1;
static const UINT_PTR kTraySubclassId = 0x54493130;     // TI10
static const UINT_PTR kTaskListSubclassId = 0x544C3130; // TL10
static const UINT_PTR kSearchSubclassId = 0x54533130;   // TS10

static volatile LONG g_initialized = 0;
static volatile LONG g_inIdealSpan = 0;
static volatile LONG g_inTaskListReload = 0;
static volatile LONG g_mulDivHits = 0;
static volatile LONG g_idealHits = 0;
static volatile LONG g_searchHits = 0;

static DWORD g_taskbarThreadId = 0;
static HWND g_trayWnd = NULL;
static HWND g_taskListWnd = NULL;
static HWND g_searchWnd = NULL;

static void** g_idealSpanSlot = NULL;
typedef LONG_PTR (__stdcall *IdealSpanFn)(LONG_PTR*, LONG_PTR, LONG_PTR, LONG_PTR, LONG_PTR, LONG_PTR);
static IdealSpanFn g_originalIdealSpan = NULL;

typedef int (WINAPI* MulDivFn)(int, int, int);
static MulDivFn g_originalMulDiv = NULL;

static void WriteDword(const wchar_t* name, DWORD value)
{
    HKEY key = NULL;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kAppKey, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL) == ERROR_SUCCESS)
    {
        RegSetValueExW(key, name, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&value), sizeof(value));
        RegCloseKey(key);
    }
}

static DWORD ReadDwordAt(const wchar_t* path, const wchar_t* name, DWORD fallback)
{
    DWORD value = fallback;
    DWORD size = sizeof(value);
    if (RegGetValueW(HKEY_CURRENT_USER, path, name, RRF_RT_REG_DWORD, NULL, &value, &size) != ERROR_SUCCESS)
        return fallback;
    return value;
}

static DWORD ReadDword(const wchar_t* name, DWORD fallback)
{
    return ReadDwordAt(kAppKey, name, fallback);
}

static bool Enabled()
{
    return ReadDword(L"HookEnabledV10", 0) != 0;
}

static UINT TaskbarDpi()
{
    if (g_trayWnd)
    {
        UINT dpi = GetDpiForWindow(g_trayWnd);
        if (dpi) return dpi;
    }
    HDC dc = GetDC(NULL);
    if (!dc) return 96;
    int dpi = GetDeviceCaps(dc, LOGPIXELSX);
    ReleaseDC(NULL, dc);
    return dpi > 0 ? (UINT)dpi : 96;
}

static int LogicalToPhysical(int logical)
{
    return ::MulDiv(logical, (int)TaskbarDpi(), 96);
}

static int PhysicalToLogical(int physical)
{
    return ::MulDiv(physical, 96, (int)TaskbarDpi());
}

static int TaskbarThickness()
{
    RECT rc = {};
    if (!g_trayWnd || !GetWindowRect(g_trayWnd, &rc)) return 48;
    int w = rc.right - rc.left;
    int h = rc.bottom - rc.top;
    return w < h ? w : h;
}

static DWORD EffectiveIconLogical()
{
    if (!Enabled()) return 0;
    DWORD requested = ReadDword(L"IconSizeV10", 20);
    if (requested < 1) requested = 1;
    if (requested > 100) requested = 100;

    int maxPhysical = TaskbarThickness() - 8;
    if (maxPhysical < 1) maxPhysical = 1;
    int maxLogical = PhysicalToLogical(maxPhysical);
    if (maxLogical < 1) maxLogical = 1;
    DWORD effective = requested > (DWORD)maxLogical ? (DWORD)maxLogical : requested;
    WriteDword(L"DiagEffectiveIconV10", effective);
    return effective;
}

static DWORD EffectiveItemWidthLogical()
{
    if (!Enabled() || ReadDword(L"CompactItemsV10", 1) == 0) return 0;
    DWORD requested = ReadDword(L"ItemWidthV10", 28);
    if (requested < 8) requested = 8;
    if (requested > 120) requested = 120;
    DWORD icon = EffectiveIconLogical();
    DWORD minimum = icon + 6;
    if (requested < minimum) requested = minimum;
    WriteDword(L"DiagEffectiveWidthV10", requested);
    return requested;
}

static bool IsHorizontalTaskbar()
{
    RECT rc = {};
    if (!g_trayWnd || !GetWindowRect(g_trayWnd, &rc)) return true;
    return (rc.right - rc.left) >= (rc.bottom - rc.top);
}

static HWND FindDescendantByClass(HWND parent, const wchar_t* wanted)
{
    struct FindCtx { const wchar_t* wanted; HWND found; } ctx = { wanted, NULL };
    EnumChildWindows(parent, [](HWND hwnd, LPARAM lp) -> BOOL {
        FindCtx* c = reinterpret_cast<FindCtx*>(lp);
        wchar_t name[96] = {};
        if (GetClassNameW(hwnd, name, 95) > 0 && lstrcmpW(name, c->wanted) == 0)
        {
            c->found = hwnd;
            return FALSE;
        }
        return TRUE;
    }, reinterpret_cast<LPARAM>(&ctx));
    return ctx.found;
}

static int PatchMainModuleIAT(const char* importName, void* replacement, void** original)
{
    HMODULE module = GetModuleHandleW(NULL);
    if (!module) return 0;
    BYTE* base = reinterpret_cast<BYTE*>(module);
    IMAGE_DOS_HEADER* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
    IMAGE_NT_HEADERS* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return 0;
    const IMAGE_DATA_DIRECTORY& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir.VirtualAddress) return 0;

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
            if (IMAGE_SNAP_BY_ORDINAL(nameThunk->u1.Ordinal)) continue;
            IMAGE_IMPORT_BY_NAME* byName = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base + nameThunk->u1.AddressOfData);
            if (lstrcmpA(reinterpret_cast<const char*>(byName->Name), importName) != 0) continue;

            DWORD oldProtect = 0;
            if (!VirtualProtect(&firstThunk->u1.Function, sizeof(firstThunk->u1.Function), PAGE_READWRITE, &oldProtect)) continue;
            void* current = reinterpret_cast<void*>(static_cast<uintptr_t>(firstThunk->u1.Function));
            if (original && !*original) *original = current;
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

static bool InTaskbarIconSizingContext()
{
    if (GetCurrentThreadId() != g_taskbarThreadId) return false;
    return InterlockedCompareExchange(&g_inIdealSpan, 0, 0) > 0 ||
           InterlockedCompareExchange(&g_inTaskListReload, 0, 0) > 0;
}

static int WINAPI MulDivHook(int nNumber, int nNumerator, int nDenominator)
{
    DWORD custom = EffectiveIconLogical();
    if (custom && InTaskbarIconSizingContext() && nDenominator == 96)
    {
        bool smallButtons = ReadDwordAt(kExplorerAdvancedKey, L"TaskbarSmallIcons", 0) != 0;
        int stockBase = smallButtons ? 16 : 24;
        if (nNumber == stockBase)
        {
            nNumber = (int)custom;
            LONG hits = InterlockedIncrement(&g_mulDivHits);
            if (hits <= 9999) WriteDword(L"DiagMulDivHitsV10", (DWORD)hits);
        }
    }
    return g_originalMulDiv ? g_originalMulDiv(nNumber, nNumerator, nDenominator)
                            : ::MulDiv(nNumber, nNumerator, nDenominator);
}

static LONG_PTR __stdcall IdealSpanHook(LONG_PTR* buttonGroup, LONG_PTR a2, LONG_PTR a3,
                                         LONG_PTR a4, LONG_PTR a5, LONG_PTR a6)
{
    IdealSpanFn original = g_originalIdealSpan;
    if (!original) return 0;

    InterlockedIncrement(&g_inIdealSpan);
    LONG_PTR result = original(buttonGroup, a2, a3, a4, a5, a6);
    InterlockedDecrement(&g_inIdealSpan);

    DWORD logicalWidth = EffectiveItemWidthLogical();
    if (!logicalWidth || !buttonGroup || result <= 0) return result;

    int groupType = 0;
    int buttonsCount = 1;
    __try
    {
        groupType = (int)buttonGroup[8]; // Win10 x64 CTaskBtnGroup type
        LONG_PTR* buttonDpa = reinterpret_cast<LONG_PTR*>(buttonGroup[7]);
        if (buttonDpa && (int)buttonDpa[0] > 0) buttonsCount = (int)buttonDpa[0];
    }
    __except(EXCEPTION_EXECUTE_HANDLER)
    {
        return result;
    }

    if (groupType != 1 && groupType != 2 && groupType != 3 && groupType != 4)
        return result;

    int target = LogicalToPhysical((int)logicalWidth);
    if (target < 1) target = 1;

    LONG_PTR compactResult = target;
    if ((groupType == 1 || groupType == 3) && buttonsCount > 1)
    {
        // A combined group is still one visual slot. An uncombined group has a much
        // wider original span; in that case preserve one compact slot per button.
        int thickness = TaskbarThickness();
        if (result > (LONG_PTR)(thickness * 3 / 2))
            compactResult = (LONG_PTR)target * buttonsCount;
    }

    LONG hits = InterlockedIncrement(&g_idealHits);
    if (hits <= 9999) WriteDword(L"DiagIdealHitsV10", (DWORD)hits);
    return compactResult;
}

static bool PatchIdealSpan()
{
    if (!g_taskListWnd || !IsWindow(g_taskListWnd)) return false;
    if (g_idealSpanSlot && g_originalIdealSpan)
    {
        WriteDword(L"DiagIdealPatchedV10", 1);
        return true;
    }

    __try
    {
        LONG_PTR taskListObject = GetWindowLongPtrW(g_taskListWnd, 0);
        if (!taskListObject) return false;

        // Windows 10 19045 x64: CTaskListWnd button-groups HDPA is at +0xD8.
        LONG_PTR* dpa = *reinterpret_cast<LONG_PTR**>(taskListObject + 0xD8);
        if (!dpa || (int)dpa[0] <= 0 || !dpa[1]) return false;
        LONG_PTR** groups = reinterpret_cast<LONG_PTR**>(dpa[1]);
        LONG_PTR* firstGroup = groups[0];
        if (!firstGroup || !firstGroup[0]) return false;
        void** vtable = reinterpret_cast<void**>(firstGroup[0]);
        void** slot = &vtable[13]; // CTaskBtnGroup::GetIdealSpan on Win10+
        if (!*slot) return false;

        if (*slot == reinterpret_cast<void*>(&IdealSpanHook))
        {
            g_idealSpanSlot = slot;
            WriteDword(L"DiagIdealPatchedV10", 1);
            return g_originalIdealSpan != NULL;
        }

        g_originalIdealSpan = reinterpret_cast<IdealSpanFn>(*slot);
        DWORD oldProtect = 0;
        if (!VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &oldProtect)) return false;
        InterlockedExchangePointer(reinterpret_cast<PVOID volatile*>(slot), reinterpret_cast<void*>(&IdealSpanHook));
        DWORD ignored = 0;
        VirtualProtect(slot, sizeof(void*), oldProtect, &ignored);
        FlushInstructionCache(GetCurrentProcess(), slot, sizeof(void*));
        g_idealSpanSlot = slot;
        WriteDword(L"DiagIdealPatchedV10", 1);
        return true;
    }
    __except(EXCEPTION_EXECUTE_HANDLER)
    {
        WriteDword(L"DiagIdealPatchedV10", 2);
        return false;
    }
}

static bool SearchResizeEnabled()
{
    return Enabled() && ReadDword(L"ResizeSearchV10", 1) != 0;
}

static void SaveSearchBackupIfNeeded(HWND search)
{
    if (!search || ReadDword(L"SearchBackupMadeV10", 0) != 0) return;
    RECT rc = {};
    if (GetWindowRect(search, &rc))
    {
        WriteDword(L"SearchBackupWidthV10", (DWORD)(rc.right - rc.left));
        WriteDword(L"SearchBackupHeightV10", (DWORD)(rc.bottom - rc.top));
        WriteDword(L"SearchBackupMadeV10", 1);
    }
}

static void GetDesiredSearchPhysical(int* width, int* height, int* y)
{
    int logicalW = (int)ReadDword(L"SearchWidthV10", 280);
    int logicalH = (int)ReadDword(L"SearchHeightV10", 40);
    if (logicalW < 40) logicalW = 40;
    if (logicalW > 800) logicalW = 800;
    if (logicalH < 16) logicalH = 16;
    if (logicalH > 100) logicalH = 100;

    int w = LogicalToPhysical(logicalW);
    int h = LogicalToPhysical(logicalH);
    RECT trayClient = {};
    GetClientRect(g_trayWnd, &trayClient);
    int trayW = trayClient.right - trayClient.left;
    int trayH = trayClient.bottom - trayClient.top;

    if (IsHorizontalTaskbar())
    {
        HWND notify = FindWindowExW(g_trayWnd, NULL, L"TrayNotifyWnd", NULL);
        int currentX = 0;
        if (g_searchWnd)
        {
            RECT sr = {};
            RECT tr = {};
            if (GetWindowRect(g_searchWnd, &sr) && GetWindowRect(g_trayWnd, &tr))
                currentX = sr.left - tr.left;
        }
        int rightLimit = trayW - 8;
        if (notify)
        {
            RECT nr = {}, tr = {};
            if (GetWindowRect(notify, &nr) && GetWindowRect(g_trayWnd, &tr))
                rightLimit = nr.left - tr.left - 8;
        }
        int maxW = rightLimit - currentX - 8;
        if (maxW < 40) maxW = 40;
        if (w > maxW) w = maxW;
        if (h > trayH - 2) h = trayH - 2;
        if (h < 1) h = 1;
        *y = (trayH - h) / 2;
    }
    else
    {
        if (w > trayW - 2) w = trayW - 2;
        if (h > trayH - 8) h = trayH - 8;
        *y = 0;
    }

    *width = w;
    *height = h;
    WriteDword(L"DiagSearchWidthV10", (DWORD)(w > 0 ? w : 0));
    WriteDword(L"DiagSearchHeightV10", (DWORD)(h > 0 ? h : 0));
}

static void EnforceSearchSize()
{
    if (!g_searchWnd || !IsWindow(g_searchWnd) || !SearchResizeEnabled()) return;
    int w = 0, h = 0, y = 0;
    GetDesiredSearchPhysical(&w, &h, &y);
    if (w <= 0 || h <= 0) return;

    RECT sr = {}, tr = {};
    int x = 0;
    if (GetWindowRect(g_searchWnd, &sr) && GetWindowRect(g_trayWnd, &tr))
        x = sr.left - tr.left;
    SetWindowPos(g_searchWnd, NULL, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    RedrawWindow(g_searchWnd, NULL, NULL, RDW_INVALIDATE | RDW_ERASE | RDW_UPDATENOW | RDW_ALLCHILDREN | RDW_FRAME);
}

static void RestoreSearchSize()
{
    if (!g_searchWnd || !IsWindow(g_searchWnd)) return;
    if (ReadDword(L"SearchBackupMadeV10", 0) == 0) return;
    int w = (int)ReadDword(L"SearchBackupWidthV10", 0);
    int h = (int)ReadDword(L"SearchBackupHeightV10", 0);
    if (w <= 0 || h <= 0) return;

    RECT sr = {}, tr = {}, trayClient = {};
    int x = 0, y = 0;
    if (GetWindowRect(g_searchWnd, &sr) && GetWindowRect(g_trayWnd, &tr)) x = sr.left - tr.left;
    if (GetClientRect(g_trayWnd, &trayClient) && IsHorizontalTaskbar()) y = ((trayClient.bottom - trayClient.top) - h) / 2;
    SetWindowPos(g_searchWnd, NULL, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    RedrawWindow(g_searchWnd, NULL, NULL, RDW_INVALIDATE | RDW_ERASE | RDW_UPDATENOW | RDW_ALLCHILDREN | RDW_FRAME);
}

static LRESULT CALLBACK SearchSubclassProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam,
                                           UINT_PTR, DWORD_PTR)
{
    if (msg == WM_NCDESTROY)
    {
        RemoveWindowSubclass(hwnd, SearchSubclassProc, kSearchSubclassId);
        if (g_searchWnd == hwnd) g_searchWnd = NULL;
        return DefSubclassProc(hwnd, msg, wParam, lParam);
    }

    if (msg == WM_WINDOWPOSCHANGING && SearchResizeEnabled())
    {
        WINDOWPOS* wp = reinterpret_cast<WINDOWPOS*>(lParam);
        if (wp)
        {
            int w = 0, h = 0, y = 0;
            GetDesiredSearchPhysical(&w, &h, &y);
            wp->cx = w;
            wp->cy = h;
            if (IsHorizontalTaskbar()) wp->y = y;
            wp->flags &= ~SWP_NOSIZE;
            if (IsHorizontalTaskbar()) wp->flags &= ~SWP_NOMOVE;
            LONG hits = InterlockedIncrement(&g_searchHits);
            if (hits <= 9999) WriteDword(L"DiagSearchHitsV10", (DWORD)hits);
        }
    }
    return DefSubclassProc(hwnd, msg, wParam, lParam);
}

static void SetupSearchSubclass()
{
    HWND search = FindWindowExW(g_trayWnd, NULL, L"TrayDummySearchControl", NULL);
    if (!search)
    {
        WriteDword(L"DiagSearchFoundV10", 0);
        g_searchWnd = NULL;
        return;
    }

    if (g_searchWnd != search)
    {
        g_searchWnd = search;
        SaveSearchBackupIfNeeded(search);
        SetWindowSubclass(search, SearchSubclassProc, kSearchSubclassId, 0);
    }
    WriteDword(L"DiagSearchFoundV10", 1);
}

static bool IsTraySettingsMessage(UINT msg, LPARAM lParam)
{
    return msg == WM_SETTINGCHANGE && lParam && lstrcmpW(reinterpret_cast<const wchar_t*>(lParam), L"TraySettings") == 0;
}

static LRESULT CALLBACK TaskListSubclassProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam,
                                             UINT_PTR, DWORD_PTR)
{
    if (msg == WM_NCDESTROY)
    {
        RemoveWindowSubclass(hwnd, TaskListSubclassProc, kTaskListSubclassId);
        if (g_taskListWnd == hwnd) g_taskListWnd = NULL;
        return DefSubclassProc(hwnd, msg, wParam, lParam);
    }

    if (IsTraySettingsMessage(msg, lParam))
    {
        InterlockedIncrement(&g_inTaskListReload);
        LRESULT r = DefSubclassProc(hwnd, msg, wParam, lParam);
        InterlockedDecrement(&g_inTaskListReload);
        return r;
    }
    return DefSubclassProc(hwnd, msg, wParam, lParam);
}

static void SetupTaskList()
{
    HWND list = FindDescendantByClass(g_trayWnd, L"MSTaskListWClass");
    if (!list)
    {
        WriteDword(L"DiagTaskListV10", 0);
        return;
    }
    if (g_taskListWnd != list)
    {
        g_taskListWnd = list;
        g_idealSpanSlot = NULL;
        g_originalIdealSpan = NULL;
        SetWindowSubclass(list, TaskListSubclassProc, kTaskListSubclassId, 0);
    }
    WriteDword(L"DiagTaskListV10", 1);
    PatchIdealSpan();
}

static void RefreshTaskbarNow()
{
    SetupTaskList();
    SetupSearchSubclass();

    static const wchar_t traySettings[] = L"TraySettings";
    // Let Explorer recalculate its own layout first.
    SendMessageW(g_trayWnd, WM_SETTINGCHANGE, 0, reinterpret_cast<LPARAM>(traySettings));

    // Then explicitly refresh the task-list subtree while our narrow sizing context is active.
    if (g_taskListWnd && IsWindow(g_taskListWnd))
    {
        SendMessageW(g_taskListWnd, WM_SETTINGCHANGE, 0, reinterpret_cast<LPARAM>(traySettings));
        RECT rc = {};
        if (GetClientRect(g_taskListWnd, &rc))
            SendMessageW(g_taskListWnd, WM_SIZE, SIZE_RESTORED, MAKELPARAM(rc.right - rc.left, rc.bottom - rc.top));
        RedrawWindow(g_taskListWnd, NULL, NULL,
                     RDW_INVALIDATE | RDW_ERASE | RDW_UPDATENOW | RDW_ALLCHILDREN | RDW_FRAME);
    }

    if (Enabled()) EnforceSearchSize();
    else RestoreSearchSize();

    RedrawWindow(g_trayWnd, NULL, NULL,
                 RDW_INVALIDATE | RDW_ERASE | RDW_UPDATENOW | RDW_ALLCHILDREN | RDW_FRAME);
    WriteDword(L"DiagApplyV10", ReadDword(L"DiagApplyV10", 0) + 1);
}

static LRESULT CALLBACK TraySubclassProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam,
                                         UINT_PTR, DWORD_PTR)
{
    if (msg == kApplyMessage)
    {
        RefreshTaskbarNow();
        return 0;
    }
    if (msg == WM_SETTINGCHANGE)
    {
        LRESULT r = DefSubclassProc(hwnd, msg, wParam, lParam);
        SetupSearchSubclass();
        if (Enabled()) EnforceSearchSize();
        return r;
    }
    if (msg == WM_NCDESTROY)
    {
        RemoveWindowSubclass(hwnd, TraySubclassProc, kTraySubclassId);
        return DefSubclassProc(hwnd, msg, wParam, lParam);
    }
    return DefSubclassProc(hwnd, msg, wParam, lParam);
}

static void SetupHook()
{
    if (InterlockedCompareExchange(&g_initialized, 1, 0) != 0) return;

    WriteDword(L"DiagInjectedV10", 1);
    WriteDword(L"DiagMulDivPatchedV10", 0);
    WriteDword(L"DiagMulDivHitsV10", 0);
    WriteDword(L"DiagIdealPatchedV10", 0);
    WriteDword(L"DiagIdealHitsV10", 0);
    WriteDword(L"DiagSearchHitsV10", 0);

    g_trayWnd = FindWindowW(L"Shell_TrayWnd", NULL);
    if (!g_trayWnd)
    {
        WriteDword(L"DiagInjectedV10", 2);
        InterlockedExchange(&g_initialized, 0);
        return;
    }
    g_taskbarThreadId = GetWindowThreadProcessId(g_trayWnd, NULL);
    if (!g_taskbarThreadId)
    {
        WriteDword(L"DiagInjectedV10", 3);
        InterlockedExchange(&g_initialized, 0);
        return;
    }

    HMODULE self = NULL;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                       reinterpret_cast<LPCWSTR>(&SetupHook), &self);

    SetWindowSubclass(g_trayWnd, TraySubclassProc, kTraySubclassId, 0);
    SetupTaskList();
    SetupSearchSubclass();

    void* original = NULL;
    int patched = PatchMainModuleIAT("MulDiv", reinterpret_cast<void*>(&MulDivHook), &original);
    if (patched > 0)
    {
        g_originalMulDiv = reinterpret_cast<MulDivFn>(original);
        WriteDword(L"DiagMulDivPatchedV10", (DWORD)patched);
    }

    RefreshTaskbarNow();
}

extern "C" __declspec(dllexport) LRESULT CALLBACK TunerHookProc(int code, WPARAM wParam, LPARAM lParam)
{
    if (code >= 0) SetupHook();
    return CallNextHookEx(NULL, code, wParam, lParam);
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(instance);
    return TRUE;
}
