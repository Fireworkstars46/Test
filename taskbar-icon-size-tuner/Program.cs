using System;
using System.ComponentModel;
using System.Diagnostics;
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
            bool startup = args != null && Array.Exists(args, a => string.Equals(a, "--startup", StringComparison.OrdinalIgnoreCase));
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm(startup));
        }
    }

    public sealed class MainForm : Form
    {
        private const string AppKey = @"Software\Taskbar Icon Size Tuner";
        private const string WindowMetricsKey = @"Control Panel\Desktop\WindowMetrics";
        private const string ExplorerAdvancedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";
        private const string SevenTtKey = @"Software\7 Taskbar Tweaker\OptionsEx";
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValue = "TaskbarIconSizeTuner";
        private const string HookDllResource = "TaskbarIconHook.dll";
        private const string HookDllName = "TaskbarIconHook-0.6.dll";
        private const int WH_GETMESSAGE = 3;
        private const uint WM_NULL = 0;
        private const uint WM_SETTINGCHANGE = 0x001A;
        private static readonly IntPtr HWND_BROADCAST = new IntPtr(0xFFFF);

        private readonly NumericUpDown sizeBox = new NumericUpDown();
        private readonly CheckBox smallButtons = new CheckBox();
        private readonly CheckBox disable7ttLarge = new CheckBox();
        private readonly CheckBox minimizeToTray = new CheckBox();
        private readonly CheckBox startWithWindows = new CheckBox();
        private readonly Label status = new Label();
        private readonly Label diagnostics = new Label();
        private readonly NotifyIcon trayIcon = new NotifyIcon();
        private readonly System.Windows.Forms.Timer watchTimer = new System.Windows.Forms.Timer();
        private readonly System.Windows.Forms.Timer liveApplyTimer = new System.Windows.Forms.Timer();

        private bool exitRequested;
        private bool loading;
        private bool restoring;
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
            Text = "Taskbar Icon Size Tuner v0.6";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            ClientSize = new Size(585, 505);
            Font = new Font("Segoe UI", 9F);

            try
            {
                Icon appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                if (appIcon != null) Icon = appIcon;
            }
            catch { }

            AddLabel("Windows 10 Taskbar Icon Size Tuner", 18, 14, 14F, true);
            AddLabel("v0.6 uses a smooth TraySettings refresh. It no longer flips Small taskbar buttons\non/off or restarts Explorer for normal size changes.", 20, 50, 9F, false);

            AddLabel("Custom taskbar icon size:", 20, 106, 9F, false);
            sizeBox.Minimum = 1;
            sizeBox.Maximum = 100;
            sizeBox.Value = 20;
            sizeBox.Width = 76;
            sizeBox.Location = new Point(188, 103);
            Controls.Add(sizeBox);
            AddLabel("px", 272, 106, 9F, false);

            smallButtons.Text = "Use Windows small taskbar buttons";
            smallButtons.AutoSize = true;
            smallButtons.Location = new Point(20, 144);
            Controls.Add(smallButtons);

            disable7ttLarge.Text = "Disable 7+ Taskbar Tweaker w10_large_icons while custom sizing is active";
            disable7ttLarge.AutoSize = true;
            disable7ttLarge.Checked = true;
            disable7ttLarge.Location = new Point(20, 172);
            Controls.Add(disable7ttLarge);

            minimizeToTray.Text = "Minimize to tray (X closes the app and restores the default size)";
            minimizeToTray.AutoSize = true;
            minimizeToTray.Checked = true;
            minimizeToTray.Location = new Point(20, 200);
            Controls.Add(minimizeToTray);

            startWithWindows.Text = "Start with Windows";
            startWithWindows.AutoSize = true;
            startWithWindows.Location = new Point(20, 228);
            Controls.Add(startWithWindows);

            Button apply = MakeButton("Apply Now", 20, 270, 155);
            apply.Click += (s, e) => ApplyCustom(true);
            Button restore = MakeButton("Restore Default", 190, 270, 155);
            restore.Click += (s, e) => RestoreOriginal(true);

            AddLabel("Live preview is automatic: change the number and the taskbar refreshes after about 0.1 sec.\nClosing the app restores your original taskbar settings without restarting Explorer.", 20, 318, 9F, false);

            diagnostics.AutoSize = false;
            diagnostics.Location = new Point(20, 370);
            diagnostics.Size = new Size(545, 45);
            diagnostics.Text = "Hook diagnostics: not applied yet.";
            Controls.Add(diagnostics);

            status.AutoSize = false;
            status.Location = new Point(20, 425);
            status.Size = new Size(545, 58);
            status.Text = "Ready.";
            Controls.Add(status);

            SetupTray();
            LoadSettings();

            liveApplyTimer.Interval = 110;
            liveApplyTimer.Tick += (s, e) =>
            {
                liveApplyTimer.Stop();
                if (!loading && !restoring)
                    ApplyCustom(false);
            };

            sizeBox.ValueChanged += (s, e) => QueueLiveApply();
            smallButtons.CheckedChanged += (s, e) => { SavePreferences(); QueueLiveApply(); };
            disable7ttLarge.CheckedChanged += (s, e) => { SavePreferences(); QueueLiveApply(); };
            minimizeToTray.CheckedChanged += (s, e) => SavePreferences();
            startWithWindows.CheckedChanged += (s, e) => SaveStartup();
            Resize += OnResize;
            FormClosing += OnClosing;

            watchTimer.Interval = 900;
            watchTimer.Tick += (s, e) =>
            {
                WatchExplorer();
                UpdateDiagnostics();
            };
            watchTimer.Start();

            Shown += (s, e) =>
            {
                if (startupMode)
                {
                    if (ReadDword(AppKey, "HookEnabledV6", 0) != 0)
                    {
                        InstallOrRefreshHook(false);
                        HideToTray();
                    }
                    else
                    {
                        exitRequested = true;
                        trayIcon.Visible = false;
                        Close();
                    }
                }
            };
        }

        private Label AddLabel(string text, int x, int y, float size, bool bold)
        {
            Label l = new Label { Text = text, AutoSize = true, Location = new Point(x, y) };
            if (size != 9F || bold)
                l.Font = new Font("Segoe UI" + (bold ? " Semibold" : ""), size);
            Controls.Add(l);
            return l;
        }

        private Button MakeButton(string text, int x, int y, int width)
        {
            Button b = new Button { Text = text, Width = width, Height = 34, Location = new Point(x, y) };
            Controls.Add(b);
            return b;
        }

        private void SetupTray()
        {
            ContextMenuStrip menu = new ContextMenuStrip();
            ToolStripMenuItem show = new ToolStripMenuItem("Show");
            show.Click += (s, e) => ShowFromTray();
            ToolStripMenuItem refresh = new ToolStripMenuItem("Refresh custom icon size");
            refresh.Click += (s, e) => ApplyCustom(true);
            ToolStripMenuItem exit = new ToolStripMenuItem("Exit + restore default");
            exit.Click += (s, e) => ExitApp();
            menu.Items.Add(show);
            menu.Items.Add(refresh);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(exit);
            trayIcon.Icon = Icon ?? SystemIcons.Application;
            trayIcon.Text = "Taskbar Icon Size Tuner";
            trayIcon.ContextMenuStrip = menu;
            trayIcon.Visible = true;
            trayIcon.DoubleClick += (s, e) => ShowFromTray();
        }

        private void LoadSettings()
        {
            loading = true;
            try
            {
                int saved = (int)ReadDword(AppKey, "HookIconSizeV6", ReadDword(AppKey, "HookIconSize", 20));
                if (saved >= 1 && saved <= 100) sizeBox.Value = saved;
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
                RestoreOldShellMetricOnly();

                WriteDword(ExplorerAdvancedKey, "TaskbarSmallIcons", smallButtons.Checked ? 1u : 0u);
                if (disable7ttLarge.Checked)
                    WriteDword(SevenTtKey, "w10_large_icons", 0);

                // Disable the older v0.3-v0.5 hook if it is still pinned in this Explorer process.
                WriteDword(AppKey, "HookEnabled", 0);
                WriteDword(AppKey, "HookEnabledV6", 1);
                WriteDword(AppKey, "HookIconSizeV6", (uint)sizeBox.Value);
                WriteDword(AppKey, "Disable7ttLarge", disable7ttLarge.Checked ? 1u : 0u);

                bool ok = InstallOrRefreshHook(showStatus);
                if (showStatus)
                    status.Text = ok ? "Applied " + sizeBox.Value + " px. No Explorer restart." : "The v0.6 hook could not attach.";
            }
            catch (Exception ex)
            {
                if (showStatus)
                    MessageBox.Show(this, ex.Message, "Could not apply", MessageBoxButtons.OK, MessageBoxIcon.Error);
                else
                    status.Text = "Apply error: " + ex.Message;
            }
        }

        private bool InstallOrRefreshHook(bool showStatus)
        {
            IntPtr tray = FindWindow("Shell_TrayWnd", null);
            if (tray == IntPtr.Zero) return false;

            uint pid;
            uint threadId = GetWindowThreadProcessId(tray, out pid);
            if (threadId == 0) return false;

            if (threadId != lastExplorerThread)
            {
                if (!AttachHook(tray, threadId))
                    return false;
                lastExplorerThread = threadId;
            }

            BroadcastTraySettings();
            if (showStatus) UpdateDiagnostics();
            return true;
        }

        private bool AttachHook(IntPtr tray, uint threadId)
        {
            try
            {
                string dll = EnsureHookDll();
                IntPtr module = LoadLibrary(dll);
                if (module == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not load hook DLL");

                try
                {
                    IntPtr proc = GetProcAddress(module, "TunerHookProc");
                    if (proc == IntPtr.Zero)
                        throw new InvalidOperationException("TunerHookProc export missing");

                    IntPtr hook = SetWindowsHookEx(WH_GETMESSAGE, proc, module, threadId);
                    if (hook == IntPtr.Zero)
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows rejected the taskbar thread hook");

                    try
                    {
                        PostMessage(tray, WM_NULL, IntPtr.Zero, IntPtr.Zero);
                        // Usually completes in a few milliseconds. Keep this short so first apply feels instant.
                        for (int i = 0; i < 8; i++)
                        {
                            Thread.Sleep(15);
                            if (ReadDword(AppKey, "DiagInjectedV6", 0) == 1)
                                break;
                        }
                    }
                    finally { UnhookWindowsHookEx(hook); }
                }
                finally { FreeLibrary(module); }

                return ReadDword(AppKey, "DiagInjectedV6", 0) == 1;
            }
            catch (Exception ex)
            {
                status.Text = "Hook error: " + ex.Message;
                return false;
            }
        }

        private static void BroadcastTraySettings()
        {
            SendNotifyMessage(HWND_BROADCAST, WM_SETTINGCHANGE, UIntPtr.Zero, "TraySettings");
        }

        private void UpdateDiagnostics()
        {
            uint injected = ReadDword(AppKey, "DiagInjectedV6", 0);
            uint traySub = ReadDword(AppKey, "DiagTraySubclassV6", 0);
            uint mul = ReadDword(AppKey, "DiagMulDivPatchedV6", 0);
            uint metrics = ReadDword(AppKey, "DiagMetricsPatchedV6", 0);
            uint metricsDpi = ReadDword(AppKey, "DiagMetricsForDpiPatchedV6", 0);
            uint mulHits = ReadDword(AppKey, "DiagMulDivHitsV6", 0);
            uint metricHits = ReadDword(AppKey, "DiagMetricHitsV6", 0);
            uint refresh = ReadDword(AppKey, "DiagSmoothRefreshesV6", 0);

            diagnostics.Text = "Hook diagnostics: Injected=" + injected + "  Tray=" + traySub +
                               "  MulDiv=" + mul + " (hits " + mulHits + ")  Metrics=" + metrics + "/" + metricsDpi +
                               " (hits " + metricHits + ")  Smooth refresh=" + refresh;
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

        private void WatchExplorer()
        {
            if (ReadDword(AppKey, "HookEnabledV6", 0) == 0) return;

            IntPtr tray = FindWindow("Shell_TrayWnd", null);
            if (tray == IntPtr.Zero) return;
            uint pid;
            uint tid = GetWindowThreadProcessId(tray, out pid);
            if (tid != 0 && tid != lastExplorerThread)
            {
                lastExplorerThread = 0;
                InstallOrRefreshHook(false);
            }
        }

        private void BackupOnce()
        {
            using (RegistryKey backup = Registry.CurrentUser.CreateSubKey(AppKey))
            {
                if (Convert.ToInt32(backup.GetValue("BackupMade", 0)) == 1) return;
                BackupValue(WindowMetricsKey, "Shell Small Icon Size", backup, "HadShellSmallIconSize", "ShellSmallIconSize", false);
                BackupValue(ExplorerAdvancedKey, "TaskbarSmallIcons", backup, "HadTaskbarSmallIcons", "TaskbarSmallIcons", true);
                BackupValue(SevenTtKey, "w10_large_icons", backup, "Had7ttLarge", "7ttLarge", true);
                backup.SetValue("BackupMade", 1, RegistryValueKind.DWord);
            }
        }

        private static void BackupValue(string path, string name, RegistryKey backup, string hadName, string valueName, bool dword)
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(path))
            {
                object v = key == null ? null : key.GetValue(name);
                backup.SetValue(hadName, v == null ? 0 : 1, RegistryValueKind.DWord);
                if (v != null)
                    backup.SetValue(valueName, dword ? (object)Convert.ToInt32(v) : v.ToString(), dword ? RegistryValueKind.DWord : RegistryValueKind.String);
            }
        }

        private void RestoreOldShellMetricOnly()
        {
            using (RegistryKey backup = Registry.CurrentUser.OpenSubKey(AppKey))
            {
                if (backup != null && Convert.ToInt32(backup.GetValue("BackupMade", 0)) == 1)
                    RestoreValue(WindowMetricsKey, "Shell Small Icon Size", backup, "HadShellSmallIconSize", "ShellSmallIconSize", RegistryValueKind.String);
            }
        }

        private void RestoreOriginal(bool showStatus)
        {
            if (restoring) return;
            restoring = true;
            liveApplyTimer.Stop();

            try
            {
                using (RegistryKey backup = Registry.CurrentUser.OpenSubKey(AppKey))
                {
                    if (backup != null && Convert.ToInt32(backup.GetValue("BackupMade", 0)) == 1)
                    {
                        RestoreValue(WindowMetricsKey, "Shell Small Icon Size", backup, "HadShellSmallIconSize", "ShellSmallIconSize", RegistryValueKind.String);
                        RestoreValue(ExplorerAdvancedKey, "TaskbarSmallIcons", backup, "HadTaskbarSmallIcons", "TaskbarSmallIcons", RegistryValueKind.DWord);
                        RestoreValue(SevenTtKey, "w10_large_icons", backup, "Had7ttLarge", "7ttLarge", RegistryValueKind.DWord);
                    }
                }

                WriteDword(AppKey, "HookEnabled", 0);
                WriteDword(AppKey, "HookEnabledV6", 0);
                BroadcastTraySettings();

                if (showStatus)
                {
                    status.Text = "Default/original taskbar size restored. No Explorer restart.";
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
                if (!had)
                    key.DeleteValue(name, false);
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

        private void OnResize(object sender, EventArgs e)
        {
            if (WindowState == FormWindowState.Minimized && minimizeToTray.Checked)
                HideToTray();
        }

        private void OnClosing(object sender, FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.WindowsShutDown)
                return;

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

        private void ExitApp()
        {
            exitRequested = true;
            Close();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                watchTimer.Dispose();
                liveApplyTimer.Dispose();
                trayIcon.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
