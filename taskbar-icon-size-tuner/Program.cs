using System;
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
            bool startupMode = args != null && Array.Exists(args, a => string.Equals(a, "--startup", StringComparison.OrdinalIgnoreCase));
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm(startupMode));
        }
    }

    public sealed class MainForm : Form
    {
        private const string WindowMetricsKey = @"Control Panel\Desktop\WindowMetrics";
        private const string ExplorerAdvancedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";
        private const string SevenTtKey = @"Software\7 Taskbar Tweaker\OptionsEx";
        private const string AppKey = @"Software\Taskbar Icon Size Tuner";
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValueName = "TaskbarIconSizeTuner";
        private const int WhGetMessage = 3;
        private const uint WmNull = 0x0000;
        private const uint HookRefreshMessage = 0x8000 + 0x4D1;
        private const string HookDllResourceName = "TaskbarIconHook.dll";
        private const string HookDllFileName = "TaskbarIconHook-0.3.dll";

        private readonly NumericUpDown sizeBox = new NumericUpDown();
        private readonly CheckBox smallTaskbarCheck = new CheckBox();
        private readonly CheckBox sevenTtLargeCheck = new CheckBox();
        private readonly CheckBox closeToTrayCheck = new CheckBox();
        private readonly CheckBox startWithWindowsCheck = new CheckBox();
        private readonly Label statusLabel = new Label();
        private readonly NotifyIcon trayIcon = new NotifyIcon();
        private readonly System.Windows.Forms.Timer explorerWatchTimer = new System.Windows.Forms.Timer();
        private bool exitRequested;
        private bool trayTipShown;
        private bool loadingPreferences;
        private uint lastHookThreadId;
        private readonly bool startupMode;

        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam,
            uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, IntPtr lpfn, IntPtr hMod, uint dwThreadId);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibrary(string lpFileName);

        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FreeLibrary(IntPtr hModule);

        private static readonly IntPtr HWND_BROADCAST = new IntPtr(0xffff);
        private const uint WM_SETTINGCHANGE = 0x001A;
        private const uint SMTO_ABORTIFHUNG = 0x0002;

        public MainForm(bool startupMode)
        {
            this.startupMode = startupMode;
            Text = "Taskbar Icon Size Tuner v0.3";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            ClientSize = new Size(520, 455);
            Font = new Font("Segoe UI", 9F);

            try
            {
                Icon extracted = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                if (extracted != null)
                    Icon = extracted;
            }
            catch { }

            var title = new Label
            {
                Text = "Windows 10 Taskbar Icon Size Tuner",
                Font = new Font("Segoe UI Semibold", 14F),
                AutoSize = true,
                Location = new Point(18, 16)
            };
            Controls.Add(title);

            var info = new Label
            {
                Text = "Taskbar-only hook for Windows 10 pinned/running app icons.\n" +
                       "Range is 1-100 px. It leaves the notification tray/clock alone.",
                AutoSize = true,
                Location = new Point(20, 52)
            };
            Controls.Add(info);

            var sizeLabel = new Label
            {
                Text = "Custom taskbar icon size:",
                AutoSize = true,
                Location = new Point(20, 104)
            };
            Controls.Add(sizeLabel);

            sizeBox.Minimum = 1;
            sizeBox.Maximum = 100;
            sizeBox.Value = 20;
            sizeBox.Width = 72;
            sizeBox.Location = new Point(188, 101);
            Controls.Add(sizeBox);

            var px = new Label { Text = "px", AutoSize = true, Location = new Point(268, 104) };
            Controls.Add(px);

            smallTaskbarCheck.Text = "Use Windows small taskbar buttons";
            smallTaskbarCheck.AutoSize = true;
            smallTaskbarCheck.Location = new Point(20, 142);
            Controls.Add(smallTaskbarCheck);

            sevenTtLargeCheck.Text = "7+ Taskbar Tweaker: w10_large_icons = 1";
            sevenTtLargeCheck.AutoSize = true;
            sevenTtLargeCheck.Location = new Point(20, 170);
            Controls.Add(sevenTtLargeCheck);

            closeToTrayCheck.Text = "Minimize / close to tray (keep reapplying if Explorer restarts)";
            closeToTrayCheck.AutoSize = true;
            closeToTrayCheck.Location = new Point(20, 198);
            closeToTrayCheck.Checked = true;
            closeToTrayCheck.CheckedChanged += (s, e) => SaveAppPreferences();
            Controls.Add(closeToTrayCheck);

            startWithWindowsCheck.Text = "Start with Windows (reapply after sign-in)";
            startWithWindowsCheck.AutoSize = true;
            startWithWindowsCheck.Location = new Point(20, 226);
            startWithWindowsCheck.CheckedChanged += (s, e) => OnStartupOptionChanged();
            Controls.Add(startWithWindowsCheck);

            var apply = new Button
            {
                Text = "Apply + Restart Explorer",
                Width = 190,
                Height = 34,
                Location = new Point(20, 266)
            };
            apply.Click += (s, e) => ApplySettings(true);
            Controls.Add(apply);

            var applyOnly = new Button
            {
                Text = "Apply / Refresh",
                Width = 115,
                Height = 34,
                Location = new Point(220, 266)
            };
            applyOnly.Click += (s, e) => ApplySettings(false);
            Controls.Add(applyOnly);

            var restore = new Button
            {
                Text = "Restore Original",
                Width = 140,
                Height = 34,
                Location = new Point(345, 266)
            };
            restore.Click += (s, e) => RestoreOriginal();
            Controls.Add(restore);

            var note = new Label
            {
                Text = "Tip: with Windows small buttons ON, try 18-28 px first. Very large values can clip inside the taskbar.",
                AutoSize = false,
                Size = new Size(475, 40),
                Location = new Point(20, 312)
            };
            Controls.Add(note);

            statusLabel.AutoSize = false;
            statusLabel.Size = new Size(475, 76);
            statusLabel.Location = new Point(20, 356);
            statusLabel.Text = "Ready.";
            Controls.Add(statusLabel);

            SetupTrayIcon();
            LoadCurrent();
            LoadAppPreferences();

            Resize += OnResizeToTray;
            FormClosing += OnFormClosing;

            explorerWatchTimer.Interval = 3000;
            explorerWatchTimer.Tick += (s, e) => WatchExplorer();
            explorerWatchTimer.Start();

            Shown += (s, e) =>
            {
                if (this.startupMode)
                {
                    if (IsHookEnabled())
                        InstallHookAndRefresh(false);
                    HideToTray();
                }
            };
        }

        private void SetupTrayIcon()
        {
            var menu = new ContextMenuStrip();
            var showItem = new ToolStripMenuItem("Show");
            showItem.Click += (s, e) => ShowFromTray();
            var refreshItem = new ToolStripMenuItem("Reapply taskbar icon size");
            refreshItem.Click += (s, e) => InstallHookAndRefresh(true);
            var exitItem = new ToolStripMenuItem("Exit (hook stays until Explorer restarts)");
            exitItem.Click += (s, e) => ExitApplication();
            menu.Items.Add(showItem);
            menu.Items.Add(refreshItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(exitItem);

            trayIcon.Text = "Taskbar Icon Size Tuner";
            trayIcon.Icon = Icon ?? SystemIcons.Application;
            trayIcon.ContextMenuStrip = menu;
            trayIcon.Visible = true;
            trayIcon.DoubleClick += (s, e) => ShowFromTray();
        }

        private void OnResizeToTray(object sender, EventArgs e)
        {
            if (WindowState == FormWindowState.Minimized && closeToTrayCheck.Checked)
                HideToTray();
        }

        private void OnFormClosing(object sender, FormClosingEventArgs e)
        {
            if (!exitRequested && e.CloseReason == CloseReason.UserClosing && closeToTrayCheck.Checked)
            {
                e.Cancel = true;
                HideToTray();
            }
        }

        private void HideToTray()
        {
            Hide();
            ShowInTaskbar = false;
            if (!trayTipShown)
            {
                trayIcon.BalloonTipTitle = "Taskbar Icon Size Tuner";
                trayIcon.BalloonTipText = "Still running in the tray and watching Explorer.";
                trayIcon.ShowBalloonTip(2200);
                trayTipShown = true;
            }
        }

        private void ShowFromTray()
        {
            ShowInTaskbar = true;
            Show();
            WindowState = FormWindowState.Normal;
            Activate();
        }

        private void ExitApplication()
        {
            exitRequested = true;
            explorerWatchTimer.Stop();
            trayIcon.Visible = false;
            Close();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                explorerWatchTimer.Dispose();
                trayIcon.Dispose();
            }
            base.Dispose(disposing);
        }

        private void LoadAppPreferences()
        {
            loadingPreferences = true;
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(AppKey))
                {
                    if (key != null)
                    {
                        object close = key.GetValue("CloseToTray");
                        if (close != null)
                            closeToTrayCheck.Checked = Convert.ToInt32(close) != 0;
                    }
                }

                using (var run = Registry.CurrentUser.OpenSubKey(RunKey))
                    startWithWindowsCheck.Checked = run != null && run.GetValue(RunValueName) != null;
            }
            catch { }
            finally
            {
                loadingPreferences = false;
            }
        }

        private void SaveAppPreferences()
        {
            if (loadingPreferences)
                return;
            try
            {
                using (var key = Registry.CurrentUser.CreateSubKey(AppKey))
                    key.SetValue("CloseToTray", closeToTrayCheck.Checked ? 1 : 0, RegistryValueKind.DWord);
            }
            catch { }
        }

        private void OnStartupOptionChanged()
        {
            if (loadingPreferences)
                return;

            try
            {
                using (var key = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (startWithWindowsCheck.Checked)
                        key.SetValue(RunValueName, "\"" + Application.ExecutablePath + "\" --startup", RegistryValueKind.String);
                    else
                        key.DeleteValue(RunValueName, false);
                }
            }
            catch (Exception ex)
            {
                statusLabel.Text = "Could not change startup option: " + ex.Message;
            }
        }

        private void LoadCurrent()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(AppKey))
                {
                    if (key != null)
                    {
                        object v = key.GetValue("HookIconSize", key.GetValue("LastAppliedSize", 20));
                        int n = Convert.ToInt32(v);
                        if (n >= 1 && n <= 100)
                            sizeBox.Value = n;
                    }
                }

                using (var key = Registry.CurrentUser.OpenSubKey(ExplorerAdvancedKey))
                {
                    object v = key == null ? null : key.GetValue("TaskbarSmallIcons");
                    smallTaskbarCheck.Checked = v != null && Convert.ToInt32(v) != 0;
                }

                using (var key = Registry.CurrentUser.OpenSubKey(SevenTtKey))
                {
                    object v = key == null ? null : key.GetValue("w10_large_icons");
                    sevenTtLargeCheck.Checked = v != null && Convert.ToInt32(v) != 0;
                }
            }
            catch (Exception ex)
            {
                statusLabel.Text = "Could not read current settings: " + ex.Message;
            }
        }

        private void BackupOnce()
        {
            using (var backup = Registry.CurrentUser.CreateSubKey(AppKey))
            {
                if (Convert.ToInt32(backup.GetValue("BackupMade", 0)) == 1)
                    return;

                using (var wm = Registry.CurrentUser.OpenSubKey(WindowMetricsKey))
                {
                    object v = wm == null ? null : wm.GetValue("Shell Small Icon Size");
                    backup.SetValue("HadShellSmallIconSize", v == null ? 0 : 1, RegistryValueKind.DWord);
                    if (v != null) backup.SetValue("ShellSmallIconSize", v.ToString(), RegistryValueKind.String);
                }

                using (var adv = Registry.CurrentUser.OpenSubKey(ExplorerAdvancedKey))
                {
                    object v = adv == null ? null : adv.GetValue("TaskbarSmallIcons");
                    backup.SetValue("HadTaskbarSmallIcons", v == null ? 0 : 1, RegistryValueKind.DWord);
                    if (v != null) backup.SetValue("TaskbarSmallIcons", Convert.ToInt32(v), RegistryValueKind.DWord);
                }

                using (var tt = Registry.CurrentUser.OpenSubKey(SevenTtKey))
                {
                    object v = tt == null ? null : tt.GetValue("w10_large_icons");
                    backup.SetValue("Had7ttLarge", v == null ? 0 : 1, RegistryValueKind.DWord);
                    if (v != null) backup.SetValue("7ttLarge", Convert.ToInt32(v), RegistryValueKind.DWord);
                }

                backup.SetValue("BackupMade", 1, RegistryValueKind.DWord);
            }
        }

        private void UndoOldShellMetricIfPossible()
        {
            try
            {
                using (var backup = Registry.CurrentUser.OpenSubKey(AppKey))
                {
                    if (backup == null || Convert.ToInt32(backup.GetValue("BackupMade", 0)) != 1)
                        return;
                    RestoreValue(WindowMetricsKey, "Shell Small Icon Size", backup,
                        "HadShellSmallIconSize", "ShellSmallIconSize", RegistryValueKind.String);
                }
            }
            catch { }
        }

        private void ApplySettings(bool restartExplorer)
        {
            try
            {
                BackupOnce();
                UndoOldShellMetricIfPossible();

                using (var key = Registry.CurrentUser.CreateSubKey(ExplorerAdvancedKey))
                    key.SetValue("TaskbarSmallIcons", smallTaskbarCheck.Checked ? 1 : 0, RegistryValueKind.DWord);

                using (var key = Registry.CurrentUser.CreateSubKey(SevenTtKey))
                    key.SetValue("w10_large_icons", sevenTtLargeCheck.Checked ? 1 : 0, RegistryValueKind.DWord);

                using (var key = Registry.CurrentUser.CreateSubKey(AppKey))
                {
                    key.SetValue("HookEnabled", 1, RegistryValueKind.DWord);
                    key.SetValue("HookIconSize", (int)sizeBox.Value, RegistryValueKind.DWord);
                    key.SetValue("LastAppliedSize", (int)sizeBox.Value, RegistryValueKind.DWord);
                }

                BroadcastSettings();

                if (restartExplorer)
                {
                    statusLabel.Text = "Saved " + sizeBox.Value + " px. Restarting Explorer and loading the taskbar hook...";
                    RestartExplorerAndInject();
                }
                else
                {
                    statusLabel.Text = "Saved " + sizeBox.Value + " px. Refreshing taskbar icons...";
                    bool ok = InstallHookAndRefresh(true);
                    statusLabel.Text = ok
                        ? "Applied " + sizeBox.Value + " px to the Windows 10 taskbar icons."
                        : "The hook could not be loaded. Try Apply + Restart Explorer.";
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "Could not apply settings", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void RestoreOriginal()
        {
            try
            {
                using (var backup = Registry.CurrentUser.OpenSubKey(AppKey))
                {
                    if (backup == null || Convert.ToInt32(backup.GetValue("BackupMade", 0)) != 1)
                    {
                        MessageBox.Show(this, "No original backup has been saved yet.", "Restore", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        return;
                    }

                    RestoreValue(WindowMetricsKey, "Shell Small Icon Size", backup,
                        "HadShellSmallIconSize", "ShellSmallIconSize", RegistryValueKind.String);
                    RestoreValue(ExplorerAdvancedKey, "TaskbarSmallIcons", backup,
                        "HadTaskbarSmallIcons", "TaskbarSmallIcons", RegistryValueKind.DWord);
                    RestoreValue(SevenTtKey, "w10_large_icons", backup,
                        "Had7ttLarge", "7ttLarge", RegistryValueKind.DWord);
                }

                using (var key = Registry.CurrentUser.CreateSubKey(AppKey))
                    key.SetValue("HookEnabled", 0, RegistryValueKind.DWord);

                BroadcastSettings();
                statusLabel.Text = "Original settings restored. Restarting Explorer without the custom hook...";
                RestartExplorer(false);
                LoadCurrent();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "Could not restore settings", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private static void RestoreValue(string path, string name, RegistryKey backup, string hadName, string backupName, RegistryValueKind kind)
        {
            using (var key = Registry.CurrentUser.CreateSubKey(path))
            {
                bool had = Convert.ToInt32(backup.GetValue(hadName, 0)) == 1;
                if (!had)
                {
                    key.DeleteValue(name, false);
                    return;
                }

                object v = backup.GetValue(backupName);
                if (v != null) key.SetValue(name, v, kind);
            }
        }

        private bool IsHookEnabled()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(AppKey))
                    return key != null && Convert.ToInt32(key.GetValue("HookEnabled", 0)) != 0;
            }
            catch { return false; }
        }

        private string EnsureHookDll()
        {
            string besideExe = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, HookDllFileName);
            if (File.Exists(besideExe))
                return besideExe;

            string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Taskbar Icon Size Tuner");
            Directory.CreateDirectory(dir);
            string path = Path.Combine(dir, HookDllFileName);

            if (!File.Exists(path))
            {
                using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream(HookDllResourceName))
                {
                    if (input == null)
                        throw new FileNotFoundException("Embedded taskbar hook DLL was not found.");
                    using (FileStream output = File.Create(path))
                        input.CopyTo(output);
                }
            }

            return path;
        }

        private bool InstallHookAndRefresh(bool forceRefresh)
        {
            try
            {
                IntPtr tray = FindWindow("Shell_TrayWnd", null);
                if (tray == IntPtr.Zero)
                    return false;

                uint pid;
                uint threadId = GetWindowThreadProcessId(tray, out pid);
                if (threadId == 0)
                    return false;

                string dllPath = EnsureHookDll();
                IntPtr module = LoadLibrary(dllPath);
                if (module == IntPtr.Zero)
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not load the taskbar hook DLL.");

                try
                {
                    IntPtr proc = GetProcAddress(module, "TunerHookProc");
                    if (proc == IntPtr.Zero)
                        throw new InvalidOperationException("TunerHookProc export was not found.");

                    IntPtr hook = SetWindowsHookEx(WhGetMessage, proc, module, threadId);
                    if (hook == IntPtr.Zero)
                        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Windows would not attach the taskbar hook.");

                    try
                    {
                        PostMessage(tray, WmNull, IntPtr.Zero, IntPtr.Zero);
                        Thread.Sleep(450);
                    }
                    finally
                    {
                        UnhookWindowsHookEx(hook);
                    }
                }
                finally
                {
                    FreeLibrary(module);
                }

                lastHookThreadId = threadId;
                Thread.Sleep(150);

                if (forceRefresh)
                {
                    IntPtr taskSw = FindDescendantByClass(tray, "MSTaskSwWClass");
                    if (taskSw != IntPtr.Zero)
                        PostMessage(taskSw, HookRefreshMessage, IntPtr.Zero, IntPtr.Zero);
                }

                return true;
            }
            catch (Exception ex)
            {
                statusLabel.Text = "Hook error: " + ex.Message;
                return false;
            }
        }

        private static IntPtr FindDescendantByClass(IntPtr parent, string targetClass)
        {
            IntPtr found = IntPtr.Zero;
            EnumWindowsProc callback = delegate(IntPtr hwnd, IntPtr lParam)
            {
                var sb = new System.Text.StringBuilder(128);
                if (GetClassName(hwnd, sb, sb.Capacity) > 0 && string.Equals(sb.ToString(), targetClass, StringComparison.Ordinal))
                {
                    found = hwnd;
                    return false;
                }
                return true;
            };
            EnumChildWindows(parent, callback, IntPtr.Zero);
            GC.KeepAlive(callback);
            return found;
        }

        private void WatchExplorer()
        {
            if (!IsHookEnabled())
                return;

            IntPtr tray = FindWindow("Shell_TrayWnd", null);
            if (tray == IntPtr.Zero)
                return;

            uint pid;
            uint threadId = GetWindowThreadProcessId(tray, out pid);
            if (threadId != 0 && threadId != lastHookThreadId)
                InstallHookAndRefresh(true);
        }

        private void RestartExplorerAndInject()
        {
            RestartExplorer(true);
        }

        private void RestartExplorer(bool inject)
        {
            try
            {
                lastHookThreadId = 0;
                foreach (var p in Process.GetProcessesByName("explorer"))
                {
                    try { p.Kill(); } catch { }
                }

                Thread.Sleep(1200);
                try { Process.Start("explorer.exe"); } catch { }

                IntPtr tray = IntPtr.Zero;
                for (int i = 0; i < 50; i++)
                {
                    tray = FindWindow("Shell_TrayWnd", null);
                    if (tray != IntPtr.Zero)
                        break;
                    Thread.Sleep(200);
                }

                if (tray == IntPtr.Zero)
                {
                    statusLabel.Text = "Explorer restarted, but the taskbar did not appear yet.";
                    return;
                }

                if (inject)
                {
                    Thread.Sleep(1400);
                    bool ok = InstallHookAndRefresh(true);
                    statusLabel.Text = ok
                        ? "Applied " + sizeBox.Value + " px. The taskbar hook is active."
                        : "Explorer restarted, but the hook did not attach. Try Apply / Refresh once.";
                }
                else
                {
                    statusLabel.Text = "Explorer restarted with the original taskbar icon behavior.";
                }
            }
            catch (Exception ex)
            {
                statusLabel.Text = "Explorer restart error: " + ex.Message;
            }
        }

        private static void BroadcastSettings()
        {
            IntPtr result;
            SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE, IntPtr.Zero, "TraySettings", SMTO_ABORTIFHUNG, 2000, out result);
        }
    }
}
