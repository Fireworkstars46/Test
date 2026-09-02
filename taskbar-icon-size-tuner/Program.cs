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
        private const string HookDllName = "TaskbarIconHook-0.4.dll";
        private const int WH_GETMESSAGE = 3;
        private const uint WM_NULL = 0;
        private const uint HookRefreshMessage = 0x8000 + 0x4D1;

        private readonly NumericUpDown sizeBox = new NumericUpDown();
        private readonly CheckBox smallButtons = new CheckBox();
        private readonly CheckBox disable7ttLarge = new CheckBox();
        private readonly CheckBox closeToTray = new CheckBox();
        private readonly CheckBox startWithWindows = new CheckBox();
        private readonly Label status = new Label();
        private readonly Label diagnostics = new Label();
        private readonly NotifyIcon trayIcon = new NotifyIcon();
        private readonly Timer watchTimer = new Timer();
        private bool exitRequested;
        private bool loading;
        private uint lastExplorerThread;
        private readonly bool startupMode;

        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

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
        [DllImport("user32.dll")]
        private static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hwnd, System.Text.StringBuilder className, int max);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibrary(string fileName);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string procName);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FreeLibrary(IntPtr module);

        public MainForm(bool startup)
        {
            startupMode = startup;
            Text = "Taskbar Icon Size Tuner v0.4";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            ClientSize = new Size(570, 500);
            Font = new Font("Segoe UI", 9F);

            try
            {
                Icon appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                if (appIcon != null) Icon = appIcon;
            }
            catch { }

            AddLabel("Windows 10 Taskbar Icon Size Tuner", 18, 14, 14F, true);
            AddLabel("v0.4 targets the taskbar's own icon-loading calls instead of the old shell metric.\nThe tray/clock is not intentionally resized.", 20, 50, 9F, false);

            AddLabel("Custom taskbar icon size:", 20, 104, 9F, false);
            sizeBox.Minimum = 1;
            sizeBox.Maximum = 100;
            sizeBox.Value = 20;
            sizeBox.Width = 76;
            sizeBox.Location = new Point(188, 101);
            Controls.Add(sizeBox);
            AddLabel("px", 272, 104, 9F, false);

            smallButtons.Text = "Use Windows small taskbar buttons";
            smallButtons.AutoSize = true;
            smallButtons.Location = new Point(20, 142);
            Controls.Add(smallButtons);

            disable7ttLarge.Text = "Disable 7+ Taskbar Tweaker w10_large_icons while custom sizing is active";
            disable7ttLarge.AutoSize = true;
            disable7ttLarge.Checked = true;
            disable7ttLarge.Location = new Point(20, 170);
            Controls.Add(disable7ttLarge);

            closeToTray.Text = "Minimize / close to tray and reapply if Explorer restarts";
            closeToTray.AutoSize = true;
            closeToTray.Checked = true;
            closeToTray.Location = new Point(20, 198);
            Controls.Add(closeToTray);

            startWithWindows.Text = "Start with Windows";
            startWithWindows.AutoSize = true;
            startWithWindows.Location = new Point(20, 226);
            Controls.Add(startWithWindows);

            Button applyRestart = MakeButton("Apply + Restart Explorer", 20, 266, 190);
            applyRestart.Click += (s, e) => Apply(true);
            Button applyRefresh = MakeButton("Apply / Refresh", 220, 266, 120);
            applyRefresh.Click += (s, e) => Apply(false);
            Button restore = MakeButton("Restore Original", 350, 266, 145);
            restore.Click += (s, e) => RestoreOriginal();

            AddLabel("For your setup, keep Small taskbar buttons ON and start around 20-28 px.\nIf a value has no visible effect, the diagnostics below tell us exactly which hook path Windows used.", 20, 316, 9F, false);

            diagnostics.AutoSize = false;
            diagnostics.Location = new Point(20, 366);
            diagnostics.Size = new Size(525, 45);
            diagnostics.Text = "Hook diagnostics: not applied yet.";
            Controls.Add(diagnostics);

            status.AutoSize = false;
            status.Location = new Point(20, 420);
            status.Size = new Size(525, 58);
            status.Text = "Ready.";
            Controls.Add(status);

            SetupTray();
            LoadSettings();

            smallButtons.CheckedChanged += (s, e) => SavePreferences();
            disable7ttLarge.CheckedChanged += (s, e) => SavePreferences();
            closeToTray.CheckedChanged += (s, e) => SavePreferences();
            startWithWindows.CheckedChanged += (s, e) => SaveStartup();
            Resize += OnResize;
            FormClosing += OnClosing;

            watchTimer.Interval = 3000;
            watchTimer.Tick += (s, e) => WatchExplorer();
            watchTimer.Start();

            Shown += (s, e) =>
            {
                if (startupMode)
                {
                    if (ReadDword(AppKey, "HookEnabled", 0) != 0)
                        InstallHookAndRefresh();
                    HideToTray();
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
            ToolStripMenuItem refresh = new ToolStripMenuItem("Reapply taskbar icon size");
            refresh.Click += (s, e) => { InstallHookAndRefresh(); UpdateDiagnostics(); };
            ToolStripMenuItem exit = new ToolStripMenuItem("Exit");
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
                int saved = (int)ReadDword(AppKey, "HookIconSize", 20);
                if (saved >= 1 && saved <= 100) sizeBox.Value = saved;
                smallButtons.Checked = ReadDword(ExplorerAdvancedKey, "TaskbarSmallIcons", 0) != 0;
                disable7ttLarge.Checked = ReadDword(AppKey, "Disable7ttLarge", 1) != 0;
                closeToTray.Checked = ReadDword(AppKey, "CloseToTray", 1) != 0;
                using (RegistryKey run = Registry.CurrentUser.OpenSubKey(RunKey))
                    startWithWindows.Checked = run != null && run.GetValue(RunValue) != null;
            }
            finally { loading = false; }
            UpdateDiagnostics();
        }

        private void SavePreferences()
        {
            if (loading) return;
            WriteDword(AppKey, "CloseToTray", closeToTray.Checked ? 1u : 0u);
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

        private void Apply(bool restartExplorer)
        {
            try
            {
                BackupOnce();
                RestoreOldShellMetricOnly();

                WriteDword(ExplorerAdvancedKey, "TaskbarSmallIcons", smallButtons.Checked ? 1u : 0u);
                if (disable7ttLarge.Checked)
                    WriteDword(SevenTtKey, "w10_large_icons", 0);

                WriteDword(AppKey, "HookEnabled", 1);
                WriteDword(AppKey, "HookIconSize", (uint)sizeBox.Value);
                WriteDword(AppKey, "Disable7ttLarge", disable7ttLarge.Checked ? 1u : 0u);
                ClearDiagnostics();

                if (restartExplorer)
                {
                    status.Text = "Restarting Explorer and attaching the v0.4 hook...";
                    RestartExplorer(true);
                }
                else
                {
                    bool ok = InstallHookAndRefresh();
                    Thread.Sleep(700);
                    UpdateDiagnostics();
                    status.Text = ok ? "Refresh sent. Check the taskbar and diagnostics." : "The hook could not attach.";
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "Could not apply", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private bool InstallHookAndRefresh()
        {
            try
            {
                IntPtr tray = FindWindow("Shell_TrayWnd", null);
                if (tray == IntPtr.Zero) return false;

                uint pid;
                uint threadId = GetWindowThreadProcessId(tray, out pid);
                if (threadId == 0) return false;

                string dll = EnsureHookDll();
                IntPtr module = LoadLibrary(dll);
                if (module == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not load hook DLL");

                try
                {
                    IntPtr proc = GetProcAddress(module, "TunerHookProc");
                    if (proc == IntPtr.Zero) throw new InvalidOperationException("TunerHookProc export missing");
                    IntPtr hook = SetWindowsHookEx(WH_GETMESSAGE, proc, module, threadId);
                    if (hook == IntPtr.Zero)
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows rejected the thread hook");
                    try
                    {
                        PostMessage(tray, WM_NULL, IntPtr.Zero, IntPtr.Zero);
                        Thread.Sleep(500);
                    }
                    finally { UnhookWindowsHookEx(hook); }
                }
                finally { FreeLibrary(module); }

                lastExplorerThread = threadId;
                IntPtr taskSw = FindDescendantByClass(tray, "MSTaskSwWClass");
                if (taskSw != IntPtr.Zero)
                    PostMessage(taskSw, HookRefreshMessage, IntPtr.Zero, IntPtr.Zero);
                Thread.Sleep(500);
                return ReadDword(AppKey, "DiagInjected", 0) == 1;
            }
            catch (Exception ex)
            {
                status.Text = "Hook error: " + ex.Message;
                return false;
            }
        }

        private void UpdateDiagnostics()
        {
            uint injected = ReadDword(AppKey, "DiagInjected", 0);
            uint taskSw = ReadDword(AppKey, "DiagTaskSwFound", 0);
            uint mul = ReadDword(AppKey, "DiagMulDivPatched", 0);
            uint metrics = ReadDword(AppKey, "DiagMetricsPatched", 0);
            uint metricsDpi = ReadDword(AppKey, "DiagMetricsForDpiPatched", 0);
            uint mulHits = ReadDword(AppKey, "DiagMulDivHits", 0);
            uint metricHits = ReadDword(AppKey, "DiagMetricHits", 0);
            uint refresh = ReadDword(AppKey, "DiagRefreshMessages", 0);

            diagnostics.Text = "Hook diagnostics: Injected=" + injected + "  TaskSw=" + taskSw +
                               "  MulDiv=" + mul + " (hits " + mulHits + ")  Metrics=" + metrics + "/" + metricsDpi +
                               " (hits " + metricHits + ")  Refresh=" + refresh;
        }

        private void ClearDiagnostics()
        {
            string[] names = { "DiagInjected", "DiagTaskSwFound", "DiagMulDivPatched", "DiagMetricsPatched", "DiagMetricsForDpiPatched", "DiagMulDivHits", "DiagMetricHits", "DiagRefreshMessages" };
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(AppKey))
                foreach (string name in names) key.SetValue(name, 0, RegistryValueKind.DWord);
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

        private static IntPtr FindDescendantByClass(IntPtr parent, string target)
        {
            IntPtr found = IntPtr.Zero;
            EnumWindowsProc cb = delegate(IntPtr hwnd, IntPtr lp)
            {
                System.Text.StringBuilder sb = new System.Text.StringBuilder(96);
                if (GetClassName(hwnd, sb, sb.Capacity) > 0 && string.Equals(sb.ToString(), target, StringComparison.Ordinal))
                {
                    found = hwnd;
                    return false;
                }
                return true;
            };
            EnumChildWindows(parent, cb, IntPtr.Zero);
            GC.KeepAlive(cb);
            return found;
        }

        private void RestartExplorer(bool inject)
        {
            lastExplorerThread = 0;
            foreach (Process p in Process.GetProcessesByName("explorer"))
                try { p.Kill(); } catch { }
            Thread.Sleep(1200);
            try { Process.Start("explorer.exe"); } catch { }

            IntPtr tray = IntPtr.Zero;
            for (int i = 0; i < 50 && tray == IntPtr.Zero; i++)
            {
                Thread.Sleep(200);
                tray = FindWindow("Shell_TrayWnd", null);
            }
            if (tray == IntPtr.Zero)
            {
                status.Text = "Explorer restarted, but the taskbar has not appeared yet.";
                return;
            }

            if (inject)
            {
                Thread.Sleep(1400);
                bool ok = InstallHookAndRefresh();
                Thread.Sleep(700);
                UpdateDiagnostics();
                status.Text = ok ? "v0.4 attached. Check the taskbar and diagnostic counters." : "Explorer restarted, but the hook did not attach.";
            }
            else status.Text = "Explorer restarted with original taskbar behavior.";
        }

        private void WatchExplorer()
        {
            if (ReadDword(AppKey, "HookEnabled", 0) == 0) return;
            IntPtr tray = FindWindow("Shell_TrayWnd", null);
            if (tray == IntPtr.Zero) return;
            uint pid;
            uint tid = GetWindowThreadProcessId(tray, out pid);
            if (tid != 0 && tid != lastExplorerThread)
            {
                InstallHookAndRefresh();
                UpdateDiagnostics();
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
                if (v != null) backup.SetValue(valueName, dword ? (object)Convert.ToInt32(v) : v.ToString(), dword ? RegistryValueKind.DWord : RegistryValueKind.String);
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

        private void RestoreOriginal()
        {
            try
            {
                using (RegistryKey backup = Registry.CurrentUser.OpenSubKey(AppKey))
                {
                    if (backup == null || Convert.ToInt32(backup.GetValue("BackupMade", 0)) != 1)
                    {
                        MessageBox.Show(this, "No original backup is available yet.", "Restore Original");
                        return;
                    }
                    RestoreValue(WindowMetricsKey, "Shell Small Icon Size", backup, "HadShellSmallIconSize", "ShellSmallIconSize", RegistryValueKind.String);
                    RestoreValue(ExplorerAdvancedKey, "TaskbarSmallIcons", backup, "HadTaskbarSmallIcons", "TaskbarSmallIcons", RegistryValueKind.DWord);
                    RestoreValue(SevenTtKey, "w10_large_icons", backup, "Had7ttLarge", "7ttLarge", RegistryValueKind.DWord);
                }
                WriteDword(AppKey, "HookEnabled", 0);
                ClearDiagnostics();
                RestartExplorer(false);
                LoadSettings();
            }
            catch (Exception ex) { status.Text = "Restore error: " + ex.Message; }
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
            if (WindowState == FormWindowState.Minimized && closeToTray.Checked) HideToTray();
        }

        private void OnClosing(object sender, FormClosingEventArgs e)
        {
            if (!exitRequested && e.CloseReason == CloseReason.UserClosing && closeToTray.Checked)
            {
                e.Cancel = true;
                HideToTray();
            }
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
            watchTimer.Stop();
            trayIcon.Visible = false;
            Close();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                watchTimer.Dispose();
                trayIcon.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
