using System;
using System.ComponentModel;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
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
        private const string HookDllName = "TaskbarIconHook-0.9.dll";
        private const int WH_GETMESSAGE = 3;
        private const uint WM_NULL = 0;
        private const uint WM_SETTINGCHANGE = 0x001A;
        private const uint SWP_NOMOVE = 0x0002;
        private const uint SWP_NOZORDER = 0x0004;
        private const uint SWP_NOACTIVATE = 0x0010;
        private static readonly IntPtr HWND_BROADCAST = new IntPtr(0xFFFF);

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

        private readonly NumericUpDown iconSizeBox = new NumericUpDown();
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
        private readonly System.Windows.Forms.Timer keepAppliedTimer = new System.Windows.Forms.Timer();

        private bool loading;
        private bool restoring;
        private uint lastExplorerThread;
        private readonly bool startupMode;

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindWindow(string className, string windowName);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hwnd, StringBuilder className, int maxCount);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, IntPtr proc, IntPtr module, uint threadId);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool SendNotifyMessage(IntPtr hwnd, uint msg, UIntPtr wParam, string lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibrary(string fileName);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string procName);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FreeLibrary(IntPtr module);

        public MainForm(bool startup)
        {
            startupMode = startup;
            Text = "Taskbar Icon Size Tuner v0.9";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            ClientSize = new Size(610, 610);
            Font = new Font("Segoe UI", 9F);

            try
            {
                Icon appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                if (appIcon != null) Icon = appIcon;
            }
            catch { }

            AddLabel("Windows 10 Taskbar Icon + Search Size Tuner", 18, 14, 14F, true);
            AddLabel("Live changes. App icons are capped to the taskbar. Search width/height are separate.\nX closes the app and restores the original taskbar/search sizes.", 20, 50, 9F, false);

            AddLabel("Taskbar app icon size:", 20, 105, 9F, false);
            iconSizeBox.Minimum = 1;
            iconSizeBox.Maximum = 100;
            iconSizeBox.Value = 20;
            iconSizeBox.Width = 78;
            iconSizeBox.Location = new Point(190, 102);
            Controls.Add(iconSizeBox);
            AddLabel("px", 276, 105, 9F, false);

            resizeSearch.Text = "Resize Windows taskbar Search area";
            resizeSearch.AutoSize = true;
            resizeSearch.Checked = true;
            resizeSearch.Location = new Point(20, 145);
            Controls.Add(resizeSearch);

            AddLabel("Search width:", 42, 178, 9F, false);
            searchWidthBox.Minimum = 40;
            searchWidthBox.Maximum = 800;
            searchWidthBox.Value = 280;
            searchWidthBox.Width = 78;
            searchWidthBox.Location = new Point(145, 175);
            Controls.Add(searchWidthBox);
            AddLabel("px", 232, 178, 9F, false);

            AddLabel("Search height:", 300, 178, 9F, false);
            searchHeightBox.Minimum = 16;
            searchHeightBox.Maximum = 100;
            searchHeightBox.Value = 40;
            searchHeightBox.Width = 78;
            searchHeightBox.Location = new Point(405, 175);
            Controls.Add(searchHeightBox);
            AddLabel("px", 492, 178, 9F, false);

            AddLabel("If Search is set to icon-only, width changes its clickable area. For a real box,\nright-click taskbar > Search > Show search box.", 42, 207, 8.5F, false);

            smallButtons.Text = "Use Windows small taskbar buttons";
            smallButtons.AutoSize = true;
            smallButtons.Location = new Point(20, 252);
            Controls.Add(smallButtons);

            disable7ttLarge.Text = "Disable 7+ Taskbar Tweaker w10_large_icons while custom sizing is active";
            disable7ttLarge.AutoSize = true;
            disable7ttLarge.Checked = true;
            disable7ttLarge.Location = new Point(20, 280);
            Controls.Add(disable7ttLarge);

            minimizeToTray.Text = "Minimize to tray (X still exits + restores default)";
            minimizeToTray.AutoSize = true;
            minimizeToTray.Checked = true;
            minimizeToTray.Location = new Point(20, 308);
            Controls.Add(minimizeToTray);

            startWithWindows.Text = "Start with Windows";
            startWithWindows.AutoSize = true;
            startWithWindows.Location = new Point(20, 336);
            Controls.Add(startWithWindows);

            Button restore = new Button();
            restore.Text = "Restore Default";
            restore.Width = 165;
            restore.Height = 34;
            restore.Location = new Point(20, 378);
            restore.Click += delegate { RestoreOriginal(true); };
            Controls.Add(restore);

            diagnostics.AutoSize = false;
            diagnostics.Location = new Point(20, 430);
            diagnostics.Size = new Size(565, 60);
            diagnostics.Text = "Diagnostics: not applied yet.";
            Controls.Add(diagnostics);

            status.AutoSize = false;
            status.Location = new Point(20, 505);
            status.Size = new Size(565, 75);
            status.Text = "Ready.";
            Controls.Add(status);

            SetupTray();
            LoadSettings();

            liveApplyTimer.Interval = 25;
            liveApplyTimer.Tick += delegate
            {
                liveApplyTimer.Stop();
                if (!loading && !restoring) ApplyCustom(false);
            };

            keepAppliedTimer.Interval = 250;
            keepAppliedTimer.Tick += delegate
            {
                if (restoring) return;
                WatchExplorer();
                if (resizeSearch.Checked && ReadDword(AppKey, "HookEnabledV9", 0) != 0)
                    ApplySearchSize(false);
                UpdateDiagnostics();
            };
            keepAppliedTimer.Start();

            iconSizeBox.ValueChanged += delegate { QueueLiveApply(); };
            resizeSearch.CheckedChanged += delegate { SavePreferences(); QueueLiveApply(); };
            searchWidthBox.ValueChanged += delegate { QueueLiveApply(); };
            searchHeightBox.ValueChanged += delegate { QueueLiveApply(); };
            smallButtons.CheckedChanged += delegate { SavePreferences(); QueueLiveApply(); };
            disable7ttLarge.CheckedChanged += delegate { SavePreferences(); QueueLiveApply(); };
            minimizeToTray.CheckedChanged += delegate { SavePreferences(); };
            startWithWindows.CheckedChanged += delegate { SaveStartup(); };
            Resize += OnResize;
            FormClosing += OnClosing;

            Shown += delegate
            {
                if (startupMode)
                {
                    if (ReadDword(AppKey, "HookEnabledV9", 0) != 0)
                    {
                        ApplyCustom(false);
                        HideToTray();
                    }
                    else
                    {
                        trayIcon.Visible = false;
                        Close();
                    }
                }
            };
        }

        private Label AddLabel(string text, int x, int y, float size, bool bold)
        {
            Label l = new Label();
            l.Text = text;
            l.AutoSize = true;
            l.Location = new Point(x, y);
            if (size != 9F || bold)
                l.Font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular);
            Controls.Add(l);
            return l;
        }

        private void SetupTray()
        {
            ContextMenuStrip menu = new ContextMenuStrip();
            ToolStripMenuItem show = new ToolStripMenuItem("Show");
            show.Click += delegate { ShowFromTray(); };
            ToolStripMenuItem refresh = new ToolStripMenuItem("Refresh sizes");
            refresh.Click += delegate { ApplyCustom(true); };
            ToolStripMenuItem exit = new ToolStripMenuItem("Exit + restore default");
            exit.Click += delegate { Close(); };
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
                int icon = (int)ReadDword(AppKey, "HookIconSizeV9", ReadDword(AppKey, "HookIconSizeV8", 20));
                if (icon >= 1 && icon <= 100) iconSizeBox.Value = icon;
                int sw = (int)ReadDword(AppKey, "SearchWidthV9", 280);
                if (sw >= 40 && sw <= 800) searchWidthBox.Value = sw;
                int sh = (int)ReadDword(AppKey, "SearchHeightV9", 40);
                if (sh >= 16 && sh <= 100) searchHeightBox.Value = sh;
                resizeSearch.Checked = ReadDword(AppKey, "ResizeSearchV9", 1) != 0;
                smallButtons.Checked = ReadDword(ExplorerAdvancedKey, "TaskbarSmallIcons", 0) != 0;
                disable7ttLarge.Checked = ReadDword(AppKey, "Disable7ttLarge", 1) != 0;
                minimizeToTray.Checked = ReadDword(AppKey, "MinimizeToTray", 1) != 0;
                using (RegistryKey run = Registry.CurrentUser.OpenSubKey(RunKey))
                    startWithWindows.Checked = run != null && run.GetValue(RunValue) != null;
            }
            finally { loading = false; }
            UpdateDiagnostics();
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
            WriteDword(AppKey, "MinimizeToTray", minimizeToTray.Checked ? 1u : 0u);
            WriteDword(AppKey, "Disable7ttLarge", disable7ttLarge.Checked ? 1u : 0u);
            WriteDword(AppKey, "ResizeSearchV9", resizeSearch.Checked ? 1u : 0u);
            WriteDword(AppKey, "SearchWidthV9", (uint)searchWidthBox.Value);
            WriteDword(AppKey, "SearchHeightV9", (uint)searchHeightBox.Value);
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
                WriteDword(ExplorerAdvancedKey, "TaskbarSmallIcons", smallButtons.Checked ? 1u : 0u);
                if (disable7ttLarge.Checked) WriteDword(SevenTtKey, "w10_large_icons", 0);

                DisableOldHooks();
                WriteDword(AppKey, "HookEnabledV9", 1);
                WriteDword(AppKey, "HookIconSizeV9", (uint)iconSizeBox.Value);
                SavePreferences();

                bool hookOk = InstallOrRefreshHook();
                bool searchOk = !resizeSearch.Checked || ApplySearchSize(true);
                if (showStatus)
                {
                    status.Text = "App icons: " + (hookOk ? "active" : "hook failed") + ". Search: " +
                                  (resizeSearch.Checked ? (searchOk ? "resized" : "not found") : "unchanged") + ".";
                }
            }
            catch (Exception ex)
            {
                if (showStatus) MessageBox.Show(this, ex.Message, "Could not apply", MessageBoxButtons.OK, MessageBoxIcon.Error);
                else status.Text = "Apply error: " + ex.Message;
            }
        }

        private void DisableOldHooks()
        {
            WriteDword(AppKey, "HookEnabled", 0);
            WriteDword(AppKey, "HookEnabledV6", 0);
            WriteDword(AppKey, "HookEnabledV7", 0);
            WriteDword(AppKey, "HookEnabledV8", 0);
        }

        private bool InstallOrRefreshHook()
        {
            IntPtr tray = FindWindow("Shell_TrayWnd", null);
            if (tray == IntPtr.Zero) return false;
            uint pid;
            uint tid = GetWindowThreadProcessId(tray, out pid);
            if (tid == 0) return false;

            if (tid != lastExplorerThread)
            {
                if (!AttachHook(tray, tid)) return false;
                lastExplorerThread = tid;
            }
            BroadcastTraySettings();
            return true;
        }

        private bool AttachHook(IntPtr tray, uint threadId)
        {
            try
            {
                string dll = EnsureHookDll();
                IntPtr module = LoadLibrary(dll);
                if (module == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not load hook DLL");
                try
                {
                    IntPtr proc = GetProcAddress(module, "TunerHookProc");
                    if (proc == IntPtr.Zero) throw new InvalidOperationException("TunerHookProc export missing");
                    IntPtr hook = SetWindowsHookEx(WH_GETMESSAGE, proc, module, threadId);
                    if (hook == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows rejected the taskbar thread hook");
                    try
                    {
                        PostMessage(tray, WM_NULL, IntPtr.Zero, IntPtr.Zero);
                        for (int i = 0; i < 8; i++)
                        {
                            Thread.Sleep(15);
                            if (ReadDword(AppKey, "DiagInjectedV9", 0) == 1) break;
                        }
                    }
                    finally { UnhookWindowsHookEx(hook); }
                }
                finally { FreeLibrary(module); }
                return ReadDword(AppKey, "DiagInjectedV9", 0) == 1;
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
                    if (input == null) throw new FileNotFoundException("Embedded hook DLL missing");
                    using (FileStream output = File.Create(path)) input.CopyTo(output);
                }
            }
            return path;
        }

        private static void BroadcastTraySettings()
        {
            SendNotifyMessage(HWND_BROADCAST, WM_SETTINGCHANGE, UIntPtr.Zero, "TraySettings");
        }

        private IntPtr FindSearchControl()
        {
            IntPtr tray = FindWindow("Shell_TrayWnd", null);
            if (tray == IntPtr.Zero) return IntPtr.Zero;

            IntPtr direct = FindWindowEx(tray, IntPtr.Zero, "TrayDummySearchControl", null);
            if (direct != IntPtr.Zero) return direct;

            IntPtr found = IntPtr.Zero;
            EnumChildWindows(tray, delegate(IntPtr hwnd, IntPtr lParam)
            {
                StringBuilder cls = new StringBuilder(128);
                if (GetClassName(hwnd, cls, cls.Capacity) > 0 &&
                    string.Equals(cls.ToString(), "TrayDummySearchControl", StringComparison.OrdinalIgnoreCase))
                {
                    found = hwnd;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            return found;
        }

        private bool ApplySearchSize(bool saveBackup)
        {
            IntPtr search = FindSearchControl();
            if (search == IntPtr.Zero) return false;
            IntPtr tray = FindWindow("Shell_TrayWnd", null);
            if (tray == IntPtr.Zero) return false;

            RECT sr;
            RECT tr;
            if (!GetWindowRect(search, out sr) || !GetWindowRect(tray, out tr)) return false;

            if (saveBackup && ReadDword(AppKey, "SearchBackupMadeV9", 0) == 0)
            {
                WriteDword(AppKey, "SearchBackupWidthV9", (uint)Math.Max(1, sr.Right - sr.Left));
                WriteDword(AppKey, "SearchBackupHeightV9", (uint)Math.Max(1, sr.Bottom - sr.Top));
                WriteDword(AppKey, "SearchBackupMadeV9", 1);
            }

            int requestedWidth = (int)searchWidthBox.Value;
            int requestedHeight = (int)searchHeightBox.Value;
            int taskbarWidth = Math.Max(1, tr.Right - tr.Left);
            int taskbarHeight = Math.Max(1, tr.Bottom - tr.Top);

            IntPtr trayNotify = FindWindowEx(tray, IntPtr.Zero, "TrayNotifyWnd", null);
            int rightLimit = tr.Right - 8;
            RECT nr;
            if (trayNotify != IntPtr.Zero && GetWindowRect(trayNotify, out nr)) rightLimit = nr.Left - 8;

            int maxWidth = rightLimit - sr.Left - 48;
            if (maxWidth < 40) maxWidth = Math.Max(40, taskbarWidth / 3);
            if (maxWidth > 800) maxWidth = 800;
            int maxHeight = Math.Max(16, taskbarHeight - 2);
            if (maxHeight > 100) maxHeight = 100;

            int width = Math.Max(40, Math.Min(requestedWidth, maxWidth));
            int height = Math.Max(16, Math.Min(requestedHeight, maxHeight));

            bool ok = SetWindowPos(search, IntPtr.Zero, 0, 0, width, height, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
            WriteDword(AppKey, "DiagSearchFoundV9", 1);
            WriteDword(AppKey, "DiagSearchWidthV9", (uint)width);
            WriteDword(AppKey, "DiagSearchHeightV9", (uint)height);
            return ok;
        }

        private void RestoreSearchSize()
        {
            if (ReadDword(AppKey, "SearchBackupMadeV9", 0) == 0) return;
            IntPtr search = FindSearchControl();
            if (search == IntPtr.Zero) return;
            int width = (int)ReadDword(AppKey, "SearchBackupWidthV9", 0);
            int height = (int)ReadDword(AppKey, "SearchBackupHeightV9", 0);
            if (width > 0 && height > 0)
                SetWindowPos(search, IntPtr.Zero, 0, 0, width, height, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        }

        private void BackupOnce()
        {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(AppKey))
            {
                if (Convert.ToInt32(key.GetValue("BackupMadeV9", 0)) == 1) return;
                using (RegistryKey adv = Registry.CurrentUser.OpenSubKey(ExplorerAdvancedKey))
                {
                    object v = adv == null ? null : adv.GetValue("TaskbarSmallIcons");
                    key.SetValue("HadTaskbarSmallIconsV9", v == null ? 0 : 1, RegistryValueKind.DWord);
                    if (v != null) key.SetValue("TaskbarSmallIconsV9", Convert.ToInt32(v), RegistryValueKind.DWord);
                }
                using (RegistryKey tt = Registry.CurrentUser.OpenSubKey(SevenTtKey))
                {
                    object v = tt == null ? null : tt.GetValue("w10_large_icons");
                    key.SetValue("Had7ttLargeV9", v == null ? 0 : 1, RegistryValueKind.DWord);
                    if (v != null) key.SetValue("7ttLargeV9", Convert.ToInt32(v), RegistryValueKind.DWord);
                }
                key.SetValue("BackupMadeV9", 1, RegistryValueKind.DWord);
            }
            ApplySearchSize(true);
        }

        private void RestoreOriginal(bool showStatus)
        {
            if (restoring) return;
            restoring = true;
            liveApplyTimer.Stop();
            try
            {
                WriteDword(AppKey, "HookEnabledV9", 0);
                DisableOldHooks();

                using (RegistryKey backup = Registry.CurrentUser.OpenSubKey(AppKey))
                {
                    if (backup != null && Convert.ToInt32(backup.GetValue("BackupMadeV9", 0)) == 1)
                    {
                        RestoreDword(ExplorerAdvancedKey, "TaskbarSmallIcons", backup, "HadTaskbarSmallIconsV9", "TaskbarSmallIconsV9");
                        RestoreDword(SevenTtKey, "w10_large_icons", backup, "Had7ttLargeV9", "7ttLargeV9");
                    }
                }
                RestoreSearchSize();
                BroadcastTraySettings();
                if (showStatus) status.Text = "Original taskbar app-icon and Search sizes restored.";
            }
            catch (Exception ex)
            {
                if (showStatus) status.Text = "Restore error: " + ex.Message;
            }
            finally { restoring = false; }
        }

        private static void RestoreDword(string path, string name, RegistryKey backup, string hadName, string valueName)
        {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(path))
            {
                bool had = Convert.ToInt32(backup.GetValue(hadName, 0)) != 0;
                if (!had) key.DeleteValue(name, false);
                else
                {
                    object value = backup.GetValue(valueName);
                    if (value != null) key.SetValue(name, value, RegistryValueKind.DWord);
                }
            }
        }

        private void WatchExplorer()
        {
            if (ReadDword(AppKey, "HookEnabledV9", 0) == 0) return;
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
            uint injected = ReadDword(AppKey, "DiagInjectedV9", 0);
            uint hits = ReadDword(AppKey, "DiagMulDivHitsV9", 0);
            uint effective = ReadDword(AppKey, "DiagEffectiveSizeV9", 0);
            uint maxFit = ReadDword(AppKey, "DiagMaxFitSizeV9", 0);
            uint searchFound = ReadDword(AppKey, "DiagSearchFoundV9", 0);
            uint sw = ReadDword(AppKey, "DiagSearchWidthV9", 0);
            uint sh = ReadDword(AppKey, "DiagSearchHeightV9", 0);
            diagnostics.Text = "Diagnostics: Hook=" + injected + "  icon hits=" + hits + "  effective icon=" + effective +
                               " px  max-fit=" + maxFit + " px\nSearch found=" + searchFound + "  applied=" + sw + " x " + sh + " px";
        }

        private void OnResize(object sender, EventArgs e)
        {
            if (WindowState == FormWindowState.Minimized && minimizeToTray.Checked) HideToTray();
        }

        private void OnClosing(object sender, FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.WindowsShutDown) return;
            keepAppliedTimer.Stop();
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

        private static uint ReadDword(string path, string name, uint fallback)
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(path))
                {
                    object v = key == null ? null : key.GetValue(name);
                    return v == null ? fallback : Convert.ToUInt32(v);
                }
            }
            catch { return fallback; }
        }

        private static void WriteDword(string path, string name, uint value)
        {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(path))
                key.SetValue(name, value, RegistryValueKind.DWord);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                liveApplyTimer.Dispose();
                keepAppliedTimer.Dispose();
                trayIcon.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
