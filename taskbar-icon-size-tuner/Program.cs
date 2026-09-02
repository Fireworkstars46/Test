using System;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace TaskbarIconSizeTuner
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    public sealed class MainForm : Form
    {
        private const string WindowMetricsKey = @"Control Panel\Desktop\WindowMetrics";
        private const string ExplorerAdvancedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";
        private const string SevenTtKey = @"Software\7 Taskbar Tweaker\OptionsEx";
        private const string AppKey = @"Software\Taskbar Icon Size Tuner";

        private readonly NumericUpDown sizeBox = new NumericUpDown();
        private readonly CheckBox smallTaskbarCheck = new CheckBox();
        private readonly CheckBox sevenTtLargeCheck = new CheckBox();
        private readonly CheckBox closeToTrayCheck = new CheckBox();
        private readonly Label statusLabel = new Label();
        private readonly NotifyIcon trayIcon = new NotifyIcon();
        private bool exitRequested;
        private bool trayTipShown;

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam,
            uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

        private static readonly IntPtr HWND_BROADCAST = new IntPtr(0xffff);
        private const uint WM_SETTINGCHANGE = 0x001A;
        private const uint SMTO_ABORTIFHUNG = 0x0002;

        public MainForm()
        {
            Text = "Taskbar Icon Size Tuner v0.2";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            ClientSize = new Size(490, 385);
            Font = new Font("Segoe UI", 9F);

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
                Text = "Experimental, no injection: changes the Windows shell small-icon metric.\n" +
                       "Range is 1-100 px. Extreme values may be ignored or look broken.",
                AutoSize = true,
                Location = new Point(20, 52)
            };
            Controls.Add(info);

            var sizeLabel = new Label
            {
                Text = "Custom small icon size:",
                AutoSize = true,
                Location = new Point(20, 104)
            };
            Controls.Add(sizeLabel);

            sizeBox.Minimum = 1;
            sizeBox.Maximum = 100;
            sizeBox.Value = 20;
            sizeBox.Width = 72;
            sizeBox.Location = new Point(180, 101);
            Controls.Add(sizeBox);

            var px = new Label { Text = "px", AutoSize = true, Location = new Point(258, 104) };
            Controls.Add(px);

            smallTaskbarCheck.Text = "Use Windows small taskbar buttons";
            smallTaskbarCheck.AutoSize = true;
            smallTaskbarCheck.Location = new Point(20, 142);
            Controls.Add(smallTaskbarCheck);

            sevenTtLargeCheck.Text = "7+ Taskbar Tweaker: w10_large_icons = 1";
            sevenTtLargeCheck.AutoSize = true;
            sevenTtLargeCheck.Location = new Point(20, 170);
            Controls.Add(sevenTtLargeCheck);

            closeToTrayCheck.Text = "Minimize / close to tray (settings stay saved)";
            closeToTrayCheck.AutoSize = true;
            closeToTrayCheck.Location = new Point(20, 198);
            closeToTrayCheck.Checked = true;
            closeToTrayCheck.CheckedChanged += (s, e) => SaveAppPreferences();
            Controls.Add(closeToTrayCheck);

            var apply = new Button
            {
                Text = "Apply + Restart Explorer",
                Width = 185,
                Height = 34,
                Location = new Point(20, 238)
            };
            apply.Click += (s, e) => ApplySettings(true);
            Controls.Add(apply);

            var applyOnly = new Button
            {
                Text = "Apply Only",
                Width = 105,
                Height = 34,
                Location = new Point(215, 238)
            };
            applyOnly.Click += (s, e) => ApplySettings(false);
            Controls.Add(applyOnly);

            var restore = new Button
            {
                Text = "Restore Original",
                Width = 130,
                Height = 34,
                Location = new Point(330, 238)
            };
            restore.Click += (s, e) => RestoreOriginal();
            Controls.Add(restore);

            statusLabel.AutoSize = false;
            statusLabel.Size = new Size(450, 75);
            statusLabel.Location = new Point(20, 292);
            statusLabel.Text = "Ready. Applied settings remain active even if this app is fully exited.";
            Controls.Add(statusLabel);

            SetupTrayIcon();
            LoadCurrent();
            LoadAppPreferences();

            Resize += OnResizeToTray;
            FormClosing += OnFormClosing;
        }

        private void SetupTrayIcon()
        {
            var menu = new ContextMenuStrip();
            var showItem = new ToolStripMenuItem("Show");
            showItem.Click += (s, e) => ShowFromTray();
            var exitItem = new ToolStripMenuItem("Exit (keep settings)");
            exitItem.Click += (s, e) => ExitApplication();
            menu.Items.Add(showItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(exitItem);

            trayIcon.Text = "Taskbar Icon Size Tuner";
            trayIcon.Icon = SystemIcons.Application;
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
                trayIcon.BalloonTipText = "Still running in the tray. Your applied icon setting is saved either way.";
                trayIcon.ShowBalloonTip(2500);
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
            trayIcon.Visible = false;
            Close();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
                trayIcon.Dispose();
            base.Dispose(disposing);
        }

        private void LoadAppPreferences()
        {
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
            }
            catch { }
        }

        private void SaveAppPreferences()
        {
            try
            {
                using (var key = Registry.CurrentUser.CreateSubKey(AppKey))
                    key.SetValue("CloseToTray", closeToTrayCheck.Checked ? 1 : 0, RegistryValueKind.DWord);
            }
            catch { }
        }

        private void LoadCurrent()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(WindowMetricsKey))
                {
                    object v = key == null ? null : key.GetValue("Shell Small Icon Size");
                    int n;
                    if (v != null && int.TryParse(v.ToString(), out n) && n >= 1 && n <= 100)
                        sizeBox.Value = n;
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

        private void ApplySettings(bool restartExplorer)
        {
            try
            {
                BackupOnce();

                using (var key = Registry.CurrentUser.CreateSubKey(WindowMetricsKey))
                    key.SetValue("Shell Small Icon Size", ((int)sizeBox.Value).ToString(), RegistryValueKind.String);

                using (var key = Registry.CurrentUser.CreateSubKey(ExplorerAdvancedKey))
                    key.SetValue("TaskbarSmallIcons", smallTaskbarCheck.Checked ? 1 : 0, RegistryValueKind.DWord);

                using (var key = Registry.CurrentUser.CreateSubKey(SevenTtKey))
                    key.SetValue("w10_large_icons", sevenTtLargeCheck.Checked ? 1 : 0, RegistryValueKind.DWord);

                using (var key = Registry.CurrentUser.CreateSubKey(AppKey))
                    key.SetValue("LastAppliedSize", (int)sizeBox.Value, RegistryValueKind.DWord);

                BroadcastSettings();
                statusLabel.Text = "Applied " + sizeBox.Value + " px. The setting is saved and stays active after closing the app. " +
                                   (restartExplorer ? "Restarting Explorer..." : "Restart Explorer or sign out to fully apply.");

                if (restartExplorer)
                    RestartExplorer();
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

                BroadcastSettings();
                statusLabel.Text = "Original settings restored. Restarting Explorer...";
                RestartExplorer();
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

        private static void BroadcastSettings()
        {
            IntPtr result;
            SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE, IntPtr.Zero, "WindowMetrics", SMTO_ABORTIFHUNG, 2000, out result);
            SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE, IntPtr.Zero, "TraySettings", SMTO_ABORTIFHUNG, 2000, out result);
        }

        private static void RestartExplorer()
        {
            try
            {
                foreach (var p in Process.GetProcessesByName("explorer"))
                {
                    try { p.Kill(); } catch { }
                }
                Thread.Sleep(1200);
                Process.Start("explorer.exe");
            }
            catch { }
        }
    }
}
