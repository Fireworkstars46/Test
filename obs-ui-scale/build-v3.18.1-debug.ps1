$ErrorActionPreference = 'Stop'

# v3.18.1 DEBUG keeps the v3.18 bidirectional Scene-height fix + full action
# matrix, but fixes the Matrix 3/Apply crash. v3.18 stored a raw pointer to the
# settings dialog's Apply button, then the restart-test setup closed that dialog.
# Matrix 3 later called click() through the destroyed QPushButton.
#
# The matrix now opens a FRESH real OBS UI Scale settings dialog whenever an
# Apply combination is due. The user clicks the actual Apply button once and
# closes that dialog; an Apply counter proves the real button path ran.
& ./build-v3.18-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.18.1 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.18.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.18.1-debug";' 'plugin version'

# Remove the dangling raw Apply-button pointer. Keep a counter instead so the
# matrix can prove that a freshly opened REAL settings dialog's Apply button was
# actually clicked.
Replace-Required @'
    int sceneGuardTargetHeight_ = -1;
    int lastSceneGuardManualSerial_ = 0;
    QPushButton *restartTestApplyButton_ = nullptr;
    int lastImmediateManualSceneDockHeight_ = -1;
'@ @'
    int sceneGuardTargetHeight_ = -1;
    int lastSceneGuardManualSerial_ = 0;
    int completeApplyCounter_ = 0;
    int lastImmediateManualSceneDockHeight_ = -1;
'@ 'replace stale Apply pointer with Apply counter'

Replace-Required @'
        restartTestApplyButton_ = apply;

'@ '' 'remove stale Apply pointer assignment'

Replace-Required @'
        if (!mainWindow || !sceneDock || !settings_ || !restartTestApplyButton_) {
            RestartTestRecord(false, QStringLiteral("Manual action-matrix setup"),
                              QStringLiteral("Scenes dock/settings/Apply button were unavailable."));
'@ @'
        if (!mainWindow || !sceneDock || !settings_) {
            RestartTestRecord(false, QStringLiteral("Manual action-matrix setup"),
                              QStringLiteral("Scenes dock/settings were unavailable."));
'@ 'matrix setup no longer requires stale Apply pointer'

# Count only the NORMAL settings dialog's real Apply button path. This exact
# SaveSettings call occurs in the normal Apply clicked handler.
$applyNeedle = '                             SaveSettings(uiSpin->value(), textSpin->value(), autoApply->isChecked());'
$applyCount = ([regex]::Matches($s, [regex]::Escape($applyNeedle))).Count
if ($applyCount -ne 1) { throw "v3.18.1 expected exactly one real Apply SaveSettings call, found $applyCount" }
$s = $s.Replace($applyNeedle, @'
                             ++completeApplyCounter_;
                             DebugWrite(QStringLiteral("REAL SETTINGS APPLY BUTTON CLICKED serial=%1")
                                            .arg(completeApplyCounter_));
                             SaveSettings(uiSpin->value(), textSpin->value(), autoApply->isChecked());
'@.Replace("`r`n", "`n").TrimEnd("`n"))

# Fresh-dialog helper. ShowDialog() creates a brand-new real settings dialog, so
# its Apply button remains valid for the entire click. The matrix cannot continue
# unless the real Apply counter advances.
$helperMarker = '    void ShowManualRestartTestPanel()'
$helperPos = $s.IndexOf($helperMarker)
if ($helperPos -lt 0) { throw 'v3.18.1 could not locate manual matrix panel insertion point' }
$helper = @'
    bool RunFreshRealApplyForMatrix(QDialog *matrixPanel, QLabel *status)
    {
        const int before = completeApplyCounter_;
        if (status)
            status->setText(QStringLiteral(
                "A fresh OBS UI Scale settings window is opening. Click Apply ONCE, then click Close."));

        QMessageBox::information(
            matrixPanel, QStringLiteral("OBS UI Scale Matrix - Real Apply"),
            QStringLiteral(
                "The real OBS UI Scale settings window will open now.\n\n"
                "Do not change any values. Click Apply once, then click Close.\n\n"
                "The matrix will verify that exact real Apply action before continuing."));

        ShowDialog();

        const bool clicked = completeApplyCounter_ > before;
        DebugWrite(QStringLiteral("MATRIX FRESH REAL APPLY before=%1 after=%2 clicked=%3")
                       .arg(before).arg(completeApplyCounter_).arg(clicked ? 1 : 0));
        if (!clicked) {
            if (status)
                status->setText(QStringLiteral(
                    "Apply was not detected. Click Continue again, then click Apply once in the fresh settings window and Close."));
            return false;
        }
        return true;
    }

'@
$s = $s.Substring(0, $helperPos) + $helper.Replace("`r`n", "`n") + $s.Substring($helperPos)

# Replace all four stale-pointer clicks used by the combination matrix. Each
# stage now opens a fresh settings dialog and requires a genuine Apply click.
$staleClick = '                restartTestApplyButton_->click();'
$staleCount = ([regex]::Matches($s, [regex]::Escape($staleClick))).Count
if ($staleCount -ne 4) { throw "v3.18.1 expected 4 stale matrix Apply clicks, found $staleCount" }
$s = $s.Replace($staleClick, @'
                if (!RunFreshRealApplyForMatrix(panel, status)) {
                    continueButton->setEnabled(true);
                    return;
                }
'@.Replace("`r`n", "`n").TrimEnd("`n"))

# Update instructions so every Apply combination explicitly tells the user that
# a fresh real settings window will open and the actual Apply button must be used.
$s = $s.Replace('Click Continue; the test will click the real Apply button and verify the height.',
                'Click Continue. A fresh real OBS UI Scale settings window will open; click Apply once, then Close. The matrix will verify the height.')
$s = $s.Replace('Drag UP, release, then click Continue. The test will click the real Apply button.',
                'Drag UP, release, then click Continue. A fresh real OBS UI Scale settings window will open; click Apply once, then Close.')
$s = $s.Replace('then Continue. The test will click the real Apply button afterward.',
                'then Continue. A fresh real OBS UI Scale settings window will open; click Apply once, then Close.')
$s = $s.Replace('then Continue. The test will click real Apply and, if it stays exact, perform the real OBS restart.',
                'then Continue. A fresh real OBS UI Scale settings window will open; click Apply once, then Close. If it stays exact, the test performs the real OBS restart.')

# Self-identifying build text.
$s = $s.Replace('OBS UI Scale v3.18 DEBUG LOG', 'OBS UI Scale v3.18.1 DEBUG LOG')
$s = $s.Replace('OBS UI Scale v3.18 DEBUG', 'OBS UI Scale v3.18.1 DEBUG')
$s = $s.Replace('OBS UI Scale v3.18 -', 'OBS UI Scale v3.18.1 -')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.18.0', '3.18.1')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.18.1 DEBUG fresh real-Apply matrix crash fix.'
