using System;
using System.ComponentModel;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace TaskbarIconSizeTuner
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            bool startup = args != null && Array.Exists(args, delegate(string a) { return string.Equals(a, "--startup", StringComparison.OrdinalIgnoreCase); });
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm(startup));
        }
    }

    public sealed class MainForm : Form
    {
        private const string AppKey = @"Software\Taskbar Icon Size Tuner";
        private const string ExplorerAdvancedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";
        private const string SevenTtKey = @"Software\7 Taskbar Tweaker\OptionsEx";
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValue = "TaskbarIconSizeTuner";
        private const string HookDllResource = "TaskbarIconHook.dll";
        private const string HookDllName = "TaskbarIconHook-1.0.dll";
        private const int WH_GETMESSAGE = 3;
        private const uint WM_NULL = 0;
        private const uint ApplyMessage = 0x8000 + 0x5A1;
        private const uint SMTO_ABORTIFHUNG = 0x0002;
        private const int SevenTtReloadOptionsEx = 104;

        private readonly NumericUpDown iconSizeBox = new NumericUpDown();
        private readonly CheckBox compactItems = new CheckBox();
        private readonly NumericUpDown itemWidthBox = new NumericUpDown();
        private readonly CheckBox resizeSearch = new CheckBox();
        private readonly NumericUpDown searchWidthBox = new NumericUpDown();
        private readonly NumericUpDown searchHeightBox = new NumericUpDown();
        private readonly CheckBox smallButtons = new CheckBox();
        private readonly CheckBox disable7ttLarge = new CheckBox();
        private readonly CheckBox minimizeToTray = new CheckBox();
        private readonly CheckBox startWithWindows = new CheckBox();
        private readonly Label diagnostics = new Label();
        private readonly Label status = new Label();
        private readonly NotifyIcon trayIcon = new NotifyIcon();
        private readonly System.Windows.Forms.Timer liveApplyTimer = new System.Windows.Forms.Timer();
        private readonly System.Windows.Forms.Timer watchTimer = new System.Windows.Forms.Timer();

        private bool loading;
        private bool restoring;
        private bool intentionalExit;
        private uint lastExplorerThread;
        private readonly bool startupMode;

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindWindow(string className, string windowName);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, IntPtr proc, IntPtr module, uint threadId);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint RegisterWindowMessage(string message);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, UIntPtr wParam, IntPtr lParam,
                                                        uint flags, uint timeout, out UIntPtr result);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibrary(string fileName);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string procName);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FreeLibrary(IntPtr module);

        public MainForm(bool startup)
        {
            startupMode = startup;
            Text = "Taskbar Icon Size Tuner v1.0";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            ClientSize = new Size(640, 690);
            Font = new Font("Segoe UI", 9F);

            try
            {
                Icon appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                if (appIcon != null) Icon = appIcon;
            }
            catch { }

            AddLabel("Windows 10 Taskbar Icon + Layout Tuner", 18, 14, 14F, true);
            AddLabel("v1.0 resizes both the icon image and its real taskbar slot, so smaller values\nmove icons left and make room for more. Changes are live; no Apply button.", 20, 50, 9F, false);

            AddLabel("Taskbar app icon size:", 20, 106, 9F, false);
            SetupNumber(iconSizeBox, 1, 100, 18, 196, 103, 78);
            AddLabel("logical px", 282, 106, 9F, false);

            compactItems.Text = "Compact the actual taskbar item/button slots";
            compactItems.AutoSize = true;
            compactItems.Checked = true;
            compactItems.Location = new Point(20, 142);
            Controls.Add(compactItems);

            AddLabel("Taskbar item/button width:", 42, 176, 9F, false);
            SetupNumber(itemWidthBox, 8, 120, 26, 218, 173, 78);
            AddLabel("logical px", 304, 176, 9F, false);
            AddLabel("The slot can never be smaller than the icon + a small safety gap.", 42, 204, 8.5F, false);

            resizeSearch.Text = "Resize Windows taskbar Search box";
            resizeSearch.AutoSize = true;
            resizeSearch.Checked = true;
            resizeSearch.Location = new Point(20, 238);
            Controls.Add(resizeSearch);

            AddLabel("Search width:", 42, 272, 9F, false);
            SetupNumber(searchWidthBox, 40, 800, 280, 145, 269, 82);
            AddLabel("logical px", 235, 272, 9F, false);

            AddLabel("Search height:", 340, 272, 9F, false);
            SetupNumber(searchHeightBox, 16, 100, 40, 447, 269, 78);
            AddLabel("logical px", 533, 272, 9F, false);
            AddLabel("Search sizing targets Windows' full Search box mode, not the magnifying-glass-only mode.", 42, 301, 8.5F, false);

            smallButtons.Text = "Use Windows small taskbar buttons";
            smallButtons.AutoSize = true;
            smallButtons.Location = new Point(20, 338);
            Controls.Add(smallButtons);

            disable7ttLarge.Text = "Disable 7+ Taskbar Tweaker w10_large_icons while custom sizing is active";
            disable7ttLarge.AutoSize = true;
            disable7ttLarge.Checked = true;
            disable7ttLarge.Location = new Point(20, 366);
            Controls.Add(disable7ttLarge);

            minimizeToTray.Text = "Minimize to tray (X exits and restores the original taskbar)";
            minimizeToTray.AutoSize = true;
            minimizeToTray.Checked = true;
            minimizeToTray.Location = new Point(20, 394);
            Controls.Add(minimizeToTray);

            startWithWindows.Text = "Start with Windows";
            startWithWindows.AutoSize = true;
            startWithWindows.Location = new Point(20, 422);
            Controls.Add(startWithWindows);

            Button restore = new Button();
            restore.Text = "Restore Default";
            restore.Width = 165;
            restore.Height = 34;
            restore.Location = new Point(20, 462);
            restore.Click += delegate { RestoreOriginal(true); };
            Controls.Add(restore);

            AddLabel("Icon redraw is forced immediately now; you should not need to hover over icons to update them.", 20, 510, 8.5F, false);

            diagnostics.AutoSize = false;
            diagnostics.Location = new Point(20, 538);
            diagnostics.Size = new Size(600, 70);
            diagnostics.Text = "Diagnostics: not applied yet.";
            Controls.Add(diagnostics);

            status.AutoSize = false;
            status.Location = new Point(20, 615);
            status.Size = new Size(600, 55);
            status.Text = "Ready.";
            Controls.Add(status);

            SetupTray();
            LoadSettings();

            liveApplyTimer.Interval = 35;
            liveApplyTimer.Tick += delegate
            {
                liveApplyTimer.Stop();
                if (!loading && !restoring) ApplyCustom(false);
            };

            watchTimer.Interval = 500;
            watchTimer.Tick += delegate
            {
                if (!restoring && ReadDword(AppKey, "HookEnabledV10", 0) != 0) WatchExplorer();
                UpdateDiagnostics();
            };
            watchTimer.Start();

            iconSizeBox.ValueChanged += delegate { QueueLiveApply(); };
            compactItems.CheckedChanged += delegate { SavePreferences(); QueueLiveApply(); };
            itemWidthBox.ValueChanged += delegate { QueueLiveApply(); };
            resizeSearch.CheckedChanged += delegate { SavePreferences(); QueueLiveApply(); };
            searchWidthBox.ValueChanged += delegate { QueueLiveApply(); };
            searchHeightBox.ValueChanged += delegate { QueueLiveApply(); };
            smallButtons.CheckedChanged += delegate { QueueLiveApply(); };
            disable7ttLarge.CheckedChanged += delegate { SavePreferences(); QueueLiveApply(); };
            minimizeToTray.CheckedChanged += delegate { SavePreferences(); };
            startWithWindows.CheckedChanged += delegate { SaveStartup(); };
            Resize += OnResize;
            FormClosing += OnClosing;

            Shown += delegate
            {
                if (startupMode)
                {
                    if (ReadDword(AppKey, "HookEnabledV10", 0) != 0)
                    {
                        ApplyCustom(false);
                        HideToTray();
                    }
                    else
                    {
                        intentionalExit = true;
                        trayIcon.Visible = false;
                        Close();
                    }
                }
            };
        }

        private void SetupNumber(NumericUpDown box, decimal min, decimal max, decimal value, int x, int y, int width)
        {
            box.Minimum = min;
            box.Maximum = max;
            box.Value = value;
            box.Width = width;
            box.Location = new Point(x, y);
            Controls.Add(box);
        }

        private Label AddLabel(string text, int x, int y, float size, bool bold)
        {
            Label l = new Label();
            l.Text = text;
            l.AutoSize = true;
            l.Location = new Point(x, y);
            if (size != 9F || bold) l.Font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular);
            Controls.Add(l);
            return l;
        }

        private void SetupTray()
        {
            ContextMenuStrip menu = new ContextMenuStrip();
            ToolStripMenuItem show = new ToolStripMenuItem("Show");
            show.Click += delegate { ShowFromTray(); };
            ToolStripMenuItem refresh = new ToolStripMenuItem("Refresh taskbar now");
            refresh.Click += delegate { ApplyCustom(true); };
            ToolStripMenuItem exit = new ToolStripMenuItem("Exit + restore default");
            exit.Click += delegate { intentionalExit = true; Close(); };
            menu.Items.Add(show);
            menu.Items.Add(refresh);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(exit);
            trayIcon.Icon = Icon ?? SystemIcons.Application;
            trayIcon.Text = "Taskbar Icon Size Tuner";
            trayIcon.ContextMenuStrip = menu;
            trayIcon.Visible = true;
            trayIcon.DoubleClick += delegate { ShowFromTray(); };
        }

        private void LoadSettings()
        {
            loading = true;
            try
            {
                SetNumberIfValid(iconSizeBox, (int)ReadDword(AppKey, "IconSizeV10", ReadDword(AppKey, "HookIconSizeV9", 18)));
                SetNumberIfValid(itemWidthBox, (int)ReadDword(AppKey, "ItemWidthV10", 26));
                SetNumberIfValid(searchWidthBox, (int)ReadDword(AppKey, "SearchWidthV10", ReadDword(AppKey, "SearchWidthV9", 280)));
                SetNumberIfValid(searchHeightBox, (int)ReadDword(AppKey, "SearchHeightV10", ReadDword(AppKey, "SearchHeightV9", 40)));
                compactItems.Checked = ReadDword(AppKey, "CompactItemsV10", 1) != 0;
                resizeSearch.Checked = ReadDword(AppKey, "ResizeSearchV10", 1) != 0;
                smallButtons.Checked = ReadDword(ExplorerAdvancedKey, "TaskbarSmallIcons", 0) != 0;
                disable7ttLarge.Checked = ReadDword(AppKey, "Disable7ttLargeV10", 1) != 0;
                minimizeToTray.Checked = ReadDword(AppKey, "MinimizeToTray", 1) != 0;
                using (RegistryKey run = Registry.CurrentUser.OpenSubKey(RunKey))
                    startWithWindows.Checked = run != null && run.GetValue(RunValue) != null;
            }
            finally { loading = false; }
            UpdateDiagnostics();
        }

        private static void SetNumberIfValid(NumericUpDown box, int value)
        {
            if (value >= box.Minimum && value <= box.Maximum) box.Value = value;
        }

        private void QueueLiveApply()
        {
            if (loading || restoring) return;
            liveApplyTimer.Stop();
            liveApplyTimer.Start();
        }

        private void SavePreferences()
        {
            if (loading) return;
            WriteDword(AppKey, "CompactItemsV10", compactItems.Checked ? 1u : 0u);
            WriteDword(AppKey, "ResizeSearchV10", resizeSearch.Checked ? 1u : 0u);
            WriteDword(AppKey, "Disable7ttLargeV10", disable7ttLarge.Checked ? 1u : 0u);
            WriteDword(AppKey, "MinimizeToTray", minimizeToTray.Checked ? 1u : 0u);
        }

        private void SaveStartup()
        {
            if (loading) return;
            try
            {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (startWithWindows.Checked)
                        key.SetValue(RunValue, "\"" + Application.ExecutablePath + "\" --startup", RegistryValueKind.String);
                    else
                        key.DeleteValue(RunValue, false);
                }
            }
            catch (Exception ex) { status.Text = "Startup setting error: " + ex.Message; }
        }

        private void ApplyCustom(bool showStatus)
        {
            if (restoring) return;
            try
            {
                BackupOnce();
                DisableOldHooks();

                WriteDword(ExplorerAdvancedKey, "TaskbarSmallIcons", smallButtons.Checked ? 1u : 0u);
                WriteDword(AppKey, "HookEnabledV10", 1);
                WriteDword(AppKey, "IconSizeV10", (uint)iconSizeBox.Value);
                WriteDword(AppKey, "CompactItemsV10", compactItems.Checked ? 1u : 0u);
                WriteDword(AppKey, "ItemWidthV10", (uint)itemWidthBox.Value);
                WriteDword(AppKey, "ResizeSearchV10", resizeSearch.Checked ? 1u : 0u);
                WriteDword(AppKey, "SearchWidthV10", (uint)searchWidthBox.Value);
                WriteDword(AppKey, "SearchHeightV10", (uint)searchHeightBox.Value);
                WriteDword(AppKey, "Disable7ttLargeV10", disable7ttLarge.Checked ? 1u : 0u);
                WriteDword(AppKey, "MinimizeToTray", minimizeToTray.Checked ? 1u : 0u);

                ApplySevenTtPreference();
                bool ok = InstallOrRefreshHook();
                if (showStatus)
                    status.Text = ok ? "Applied immediately. Icon image + taskbar slot + Search refresh sent." : "The v1.0 Explorer hook could not attach.";
            }
            catch (Exception ex)
            {
                if (showStatus) MessageBox.Show(this, ex.Message, "Could not apply", MessageBoxButtons.OK, MessageBoxIcon.Error);
                else status.Text = "Apply error: " + ex.Message;
            }
        }

        private void ApplySevenTtPreference()
        {
            if (disable7ttLarge.Checked)
            {
                WriteDword(SevenTtKey, "w10_large_icons", 0);
            }
            else
            {
                using (RegistryKey backup = Registry.CurrentUser.OpenSubKey(AppKey))
                {
                    if (backup != null && Convert.ToInt32(backup.GetValue("BackupMadeV10", 0)) == 1)
                        RestoreValue(SevenTtKey, "w10_large_icons", backup, "Had7ttLargeV10", "7ttLargeV10", RegistryValueKind.DWord);
                }
            }
            ReloadSevenTaskbarTweakerOptionsEx();
        }

        private void ReloadSevenTaskbarTweakerOptionsEx()
        {
            try
            {
                IntPtr tray = FindWindow("Shell_TrayWnd", null);
                if (tray == IntPtr.Zero) return;
                uint msg = RegisterWindowMessage("7 Taskbar Tweaker");
                if (msg != 0) PostMessage(tray, msg, IntPtr.Zero, new IntPtr(SevenTtReloadOptionsEx));
            }
            catch { }
        }

        private void DisableOldHooks()
        {
            WriteDword(AppKey, "HookEnabled", 0);
            WriteDword(AppKey, "HookEnabledV6", 0);
            WriteDword(AppKey, "HookEnabledV7", 0);
            WriteDword(AppKey, "HookEnabledV8", 0);
            WriteDword(AppKey, "HookEnabledV9", 0);
        }

        private bool InstallOrRefreshHook()
        {
            IntPtr tray = FindWindow("Shell_TrayWnd", null);
            if (tray == IntPtr.Zero) return false;
            uint pid;
            uint threadId = GetWindowThreadProcessId(tray, out pid);
            if (threadId == 0) return false;

            if (threadId != lastExplorerThread)
            {
                if (!AttachHook(tray, threadId)) return false;
                lastExplorerThread = threadId;
            }

            UIntPtr result;
            SendMessageTimeout(tray, ApplyMessage, UIntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, 800, out result);
            return ReadDword(AppKey, "DiagInjectedV10", 0) == 1;
        }

        private bool AttachHook(IntPtr tray, uint threadId)
        {
            try
            {
                string dll = EnsureHookDll();
                IntPtr module = LoadLibrary(dll);
                if (module == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not load v1.0 hook DLL");
                try
                {
                    IntPtr proc = GetProcAddress(module, "TunerHookProc");
                    if (proc == IntPtr.Zero) throw new InvalidOperationException("TunerHookProc export missing");
                    IntPtr hook = SetWindowsHookEx(WH_GETMESSAGE, proc, module, threadId);
                    if (hook == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows rejected the taskbar-thread hook");
                    try
                    {
                        PostMessage(tray, WM_NULL, IntPtr.Zero, IntPtr.Zero);
                        for (int i = 0; i < 20; i++)
                        {
                            Thread.Sleep(15);
                            if (ReadDword(AppKey, "DiagInjectedV10", 0) == 1) break;
                        }
                    }
                    finally { UnhookWindowsHookEx(hook); }
                }
                finally { FreeLibrary(module); }
                return ReadDword(AppKey, "DiagInjectedV10", 0) == 1;
            }
            catch (Exception ex)
            {
                status.Text = "Hook error: " + ex.Message;
                return false;
            }
        }

        private string EnsureHookDll()
        {
            string beside = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, HookDllName);
            if (File.Exists(beside)) return beside;

            string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Taskbar Icon Size Tuner");
            Directory.CreateDirectory(dir);
            string path = Path.Combine(dir, HookDllName);
            if (!File.Exists(path))
            {
                using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream(HookDllResource))
                {
                    if (input == null) throw new FileNotFoundException("Embedded v1.0 hook DLL missing");
                    using (FileStream output = File.Create(path)) input.CopyTo(output);
                }
            }
            return path;
        }

        private void WatchExplorer()
        {
            IntPtr tray = FindWindow("Shell_TrayWnd", null);
            if (tray == IntPtr.Zero) return;
            uint pid;
            uint tid = GetWindowThreadProcessId(tray, out pid);
            if (tid != 0 && tid != lastExplorerThread)
            {
                lastExplorerThread = 0;
                InstallOrRefreshHook();
            }
        }

        private void UpdateDiagnostics()
        {
            uint injected = ReadDword(AppKey, "DiagInjectedV10", 0);
            uint taskList = ReadDword(AppKey, "DiagTaskListV10", 0);
            uint mul = ReadDword(AppKey, "DiagMulDivPatchedV10", 0);
            uint mulHits = ReadDword(AppKey, "DiagMulDivHitsV10", 0);
            uint ideal = ReadDword(AppKey, "DiagIdealPatchedV10", 0);
            uint idealHits = ReadDword(AppKey, "DiagIdealHitsV10", 0);
            uint search = ReadDword(AppKey, "DiagSearchFoundV10", 0);
            uint searchHits = ReadDword(AppKey, "DiagSearchHitsV10", 0);
            uint effIcon = ReadDword(AppKey, "DiagEffectiveIconV10", 0);
            uint effWidth = ReadDword(AppKey, "DiagEffectiveWidthV10", 0);
            uint apply = ReadDword(AppKey, "DiagApplyV10", 0);

            diagnostics.Text = "Diagnostics: Injected=" + injected + "  TaskList=" + taskList + "  MulDiv=" + mul + " (hits " + mulHits + ")\r\n" +
                               "Slot hook=" + ideal + " (hits " + idealHits + ")  Search=" + search + " (hits " + searchHits + ")  Effective icon/slot=" + effIcon + "/" + effWidth + "  Refresh=" + apply;
        }

        private void BackupOnce()
        {
            using (RegistryKey backup = Registry.CurrentUser.CreateSubKey(AppKey))
            {
                if (Convert.ToInt32(backup.GetValue("BackupMadeV10", 0)) == 1) return;
                BackupValue(ExplorerAdvancedKey, "TaskbarSmallIcons", backup, "HadTaskbarSmallIconsV10", "TaskbarSmallIconsV10", true);
                BackupValue(SevenTtKey, "w10_large_icons", backup, "Had7ttLargeV10", "7ttLargeV10", true);
                backup.SetValue("BackupMadeV10", 1, RegistryValueKind.DWord);
            }
        }

        private static void BackupValue(string path, string name, RegistryKey backup, string hadName, string valueName, bool dword)
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(path))
            {
                object value = key == null ? null : key.GetValue(name);
                backup.SetValue(hadName, value == null ? 0 : 1, RegistryValueKind.DWord);
                if (value != null)
                    backup.SetValue(valueName, dword ? (object)Convert.ToInt32(value) : value.ToString(), dword ? RegistryValueKind.DWord : RegistryValueKind.String);
            }
        }

        private void RestoreOriginal(bool showStatus)
        {
            if (restoring) return;
            restoring = true;
            liveApplyTimer.Stop();
            try
            {
                WriteDword(AppKey, "HookEnabledV10", 0);
                DisableOldHooks();

                using (RegistryKey backup = Registry.CurrentUser.OpenSubKey(AppKey))
                {
                    if (backup != null && Convert.ToInt32(backup.GetValue("BackupMadeV10", 0)) == 1)
                    {
                        RestoreValue(ExplorerAdvancedKey, "TaskbarSmallIcons", backup, "HadTaskbarSmallIconsV10", "TaskbarSmallIconsV10", RegistryValueKind.DWord);
                        RestoreValue(SevenTtKey, "w10_large_icons", backup, "Had7ttLargeV10", "7ttLargeV10", RegistryValueKind.DWord);
                    }
                }
                ReloadSevenTaskbarTweakerOptionsEx();

                IntPtr tray = FindWindow("Shell_TrayWnd", null);
                if (tray != IntPtr.Zero)
                {
                    uint pid;
                    uint tid = GetWindowThreadProcessId(tray, out pid);
                    if (tid != 0 && tid != lastExplorerThread)
                    {
                        lastExplorerThread = 0;
                        AttachHook(tray, tid);
                        lastExplorerThread = tid;
                    }
                    UIntPtr result;
                    SendMessageTimeout(tray, ApplyMessage, UIntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, 800, out result);
                }

                if (showStatus)
                {
                    status.Text = "Original Windows taskbar/Search sizing restored.";
                    LoadSettings();
                }
            }
            catch (Exception ex)
            {
                if (showStatus) status.Text = "Restore error: " + ex.Message;
            }
            finally { restoring = false; }
        }

        private static void RestoreValue(string path, string name, RegistryKey backup, string hadName, string valueName, RegistryValueKind kind)
        {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(path))
            {
                bool had = Convert.ToInt32(backup.GetValue(hadName, 0)) != 0;
                if (!had) key.DeleteValue(name, false);
                else
                {
                    object value = backup.GetValue(valueName);
                    if (value != null) key.SetValue(name, value, kind);
                }
            }
        }

        private static uint ReadDword(string path, string name, uint fallback)
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(path))
                {
                    object value = key == null ? null : key.GetValue(name);
                    return value == null ? fallback : Convert.ToUInt32(value);
                }
            }
            catch { return fallback; }
        }

        private static void WriteDword(string path, string name, uint value)
        {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(path))
                key.SetValue(name, value, RegistryValueKind.DWord);
        }

        private void OnResize(object sender, EventArgs e)
        {
            if (WindowState == FormWindowState.Minimized && minimizeToTray.Checked) HideToTray();
        }

        private void OnClosing(object sender, FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.WindowsShutDown)
            {
                trayIcon.Visible = false;
                return;
            }

            watchTimer.Stop();
            liveApplyTimer.Stop();
            RestoreOriginal(false);
            trayIcon.Visible = false;
        }

        private void HideToTray()
        {
            Hide();
            ShowInTaskbar = false;
        }

        private void ShowFromTray()
        {
            ShowInTaskbar = true;
            Show();
            WindowState = FormWindowState.Normal;
            Activate();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                liveApplyTimer.Dispose();
                watchTimer.Dispose();
                trayIcon.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
