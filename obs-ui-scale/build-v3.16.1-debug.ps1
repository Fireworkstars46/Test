$ErrorActionPreference = 'Stop'

# v3.16.1 DEBUG keeps the v3.16 authoritative Scene-height repair and fixes the
# test-state recovery problem exposed when the v3.15 complete test was abandoned
# before its intentional restart. A test can now restore the saved original
# settings/dock position and clear its debug state instead of leaving
# debug/restartTestActive stuck forever.
& ./build-v3.16-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.16.1 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.16.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.16.1-debug";' 'plugin version'

# Add a safe recovery helper before the complete-test entry point. If the test
# had already snapshotted the user's original settings, restore those values and
# visible dock position first, then clear every temporary test key. If no
# snapshot exists, simply clear the stale state.
$recoveryMarker = '    void BeginCompleteUserActionTest(QDoubleSpinBox *uiSpin, QDoubleSpinBox *textSpin,'
$recoveryPos = $s.IndexOf($recoveryMarker)
if ($recoveryPos -lt 0) { throw 'v3.16.1 could not locate complete-test entry point' }
$recoveryCode = @'
    void RecoverAndClearActiveTest(QDialog *parent, QLabel *status)
    {
        if (!settings_)
            return;

        const bool active = settings_->value(QStringLiteral("debug/restartTestActive"), false).toBool();
        if (!active) {
            QMessageBox::information(parent, QStringLiteral("OBS UI Scale Test Recovery"),
                                     QStringLiteral("No restart/complete test state is currently active."));
            return;
        }

        const bool haveOriginals = settings_->contains(QStringLiteral("debug/restartTestOriginalControlPercent")) &&
                                   settings_->contains(QStringLiteral("debug/restartTestOriginalTextPercent"));
        if (!haveOriginals) {
            completePreflightResults_.clear();
            ClearRestartTestKeys();
            if (status)
                status->setText(QStringLiteral("Old active-test marker cleared. You can start a new test now."));
            QMessageBox::information(parent, QStringLiteral("OBS UI Scale Test Recovery"),
                                     QStringLiteral("The old active-test marker was cleared. No saved original-state snapshot was present."));
            return;
        }

        const double originalUi = settings_->value(QStringLiteral("debug/restartTestOriginalControlPercent"), uiPercent_).toDouble();
        const double originalText = settings_->value(QStringLiteral("debug/restartTestOriginalTextPercent"), textPercent_).toDouble();
        const bool originalAuto = settings_->value(QStringLiteral("debug/restartTestOriginalAutoApply"), autoApply_).toBool();
        const bool originalSafe = settings_->value(QStringLiteral("debug/restartTestOriginalSafeTiny"), safeTinyMode_).toBool();
        const bool originalProp = settings_->value(QStringLiteral("debug/restartTestOriginalProportional"), proportionalMode_).toBool();
        const bool originalRowLock = settings_->value(QStringLiteral("debug/restartTestOriginalSceneRowLock"), sceneRowLockEnabled_).toBool();
        const int originalRows = settings_->value(QStringLiteral("debug/restartTestOriginalSceneRows"), sceneVisibleRows_).toInt();
        const int originalManual = settings_->value(QStringLiteral("debug/restartTestOriginalManualHeight"), -1).toInt();
        const int originalDock = settings_->value(QStringLiteral("debug/restartTestOriginalDockHeight"), -1).toInt();

        if (status)
            status->setText(QStringLiteral("Recovering the original settings from the abandoned test..."));

        proportionalMode_ = originalProp;
        safeTinyMode_ = originalSafe;
        sceneRowLockEnabled_ = originalRowLock;
        sceneVisibleRows_ = qBound(1, originalRows, 1000);
        autoApply_ = originalAuto;
        savedManualSceneDockHeight_ = originalManual > 0 ? originalManual : -1;
        if (savedManualSceneDockHeight_ > 0)
            settings_->setValue(QStringLiteral("ui/manualSceneDockHeight"), savedManualSceneDockHeight_);
        else
            settings_->remove(QStringLiteral("ui/manualSceneDockHeight"));

        SaveSettings(originalUi, originalText, originalAuto);
        startupApplyUsesSavedManual_ = savedManualSceneDockHeight_ > 0;
        ApplyScale(uiPercent_, textPercent_);
        startupApplyUsesSavedManual_ = false;

        QTimer::singleShot(4300, this, [this, parent, status, originalDock, originalManual]() {
            auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
            QDockWidget *sceneDock = ScenesDock();
            if (mainWindow && sceneDock && originalDock > 0) {
                const int floor = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
                restoringDockTargets_ = true;
                mainWindow->resizeDocks({sceneDock}, {qMax(floor, originalDock)}, Qt::Vertical);
                restoringDockTargets_ = false;
                ReassertSceneRowLock();
            }

            savedManualSceneDockHeight_ = originalManual > 0 ? originalManual : -1;
            if (savedManualSceneDockHeight_ > 0)
                settings_->setValue(QStringLiteral("ui/manualSceneDockHeight"), savedManualSceneDockHeight_);
            else
                settings_->remove(QStringLiteral("ui/manualSceneDockHeight"));
            settings_->sync();

            completePreflightResults_.clear();
            ClearRestartTestKeys();
            DebugWrite(QStringLiteral("ABANDONED TEST STATE RECOVERED AND CLEARED"));
            if (status)
                status->setText(QStringLiteral("Abandoned test cleared and original settings restored. You can run the Complete User-Action Test now."));
            QMessageBox::information(parent, QStringLiteral("OBS UI Scale Test Recovery"),
                                     QStringLiteral("The abandoned test was cleared and its saved original OBS UI Scale settings/dock position were restored.\n\nYou can run the Complete User-Action Test again now."));
        });
    }

'@
$s = $s.Substring(0, $recoveryPos) + $recoveryCode.Replace("`r`n", "`n") + $s.Substring($recoveryPos)

# Instead of the old dead-end popup, both comprehensive and standalone restart
# tests now offer to recover/clear the abandoned state. The recovery is async so
# the user starts the requested test again after the restore-complete message.
Replace-Required @'
        if (settings_->value(QStringLiteral("debug/restartTestActive"), false).toBool()) {
            QMessageBox::information(settingsDialog, QStringLiteral("OBS UI Scale Complete Test"),
                                     QStringLiteral("A restart/complete test is already active. Finish it first."));
            return;
        }
'@ @'
        if (settings_->value(QStringLiteral("debug/restartTestActive"), false).toBool()) {
            const auto answer = QMessageBox::question(
                settingsDialog, QStringLiteral("OBS UI Scale Complete Test"),
                QStringLiteral("A previous restart/complete test is still marked active.\n\nRestore its saved original settings and clear that abandoned test now?"),
                QMessageBox::Yes | QMessageBox::No, QMessageBox::Yes);
            if (answer == QMessageBox::Yes)
                RecoverAndClearActiveTest(settingsDialog, status);
            return;
        }
'@ 'complete test abandoned-state recovery prompt'

Replace-Required @'
        if (settings_->value(QStringLiteral("debug/restartTestActive"), false).toBool()) {
            QMessageBox::information(settingsDialog, QStringLiteral("OBS UI Scale Restart Test"),
                                     QStringLiteral("A restart test is already active. Finish that test first."));
            return;
        }
'@ @'
        if (settings_->value(QStringLiteral("debug/restartTestActive"), false).toBool()) {
            const auto answer = QMessageBox::question(
                settingsDialog, QStringLiteral("OBS UI Scale Restart Test"),
                QStringLiteral("A previous restart/complete test is still marked active.\n\nRestore its saved original settings and clear that abandoned test now?"),
                QMessageBox::Yes | QMessageBox::No, QMessageBox::Yes);
            if (answer == QMessageBox::Yes)
                RecoverAndClearActiveTest(settingsDialog, status);
            return;
        }
'@ 'restart test abandoned-state recovery prompt'

# Add an explicit recovery button as a fallback for any phase, including a stuck
# phase-2 restart continuation. It restores originals before clearing keys.
Replace-Required @'
        auto *completeTest = buttons->addButton(QStringLiteral("Run Complete User-Action Test"), QDialogButtonBox::ActionRole);
        completeTest->setToolTip(QStringLiteral("Tests every normal OBS UI Scale control/button, real manual drag-to-minimum, immediate and repeated real Scene clicks, real OBS restart, startup restore, and Apply after restart."));
        auto *close = buttons->addButton(QDialogButtonBox::Close);
'@ @'
        auto *completeTest = buttons->addButton(QStringLiteral("Run Complete User-Action Test"), QDialogButtonBox::ActionRole);
        completeTest->setToolTip(QStringLiteral("Tests every normal OBS UI Scale control/button, real manual drag-to-minimum, immediate and repeated real Scene clicks, real OBS restart, startup restore, and Apply after restart."));
        auto *clearActiveTest = buttons->addButton(QStringLiteral("Clear/Restore Active Test"), QDialogButtonBox::ActionRole);
        clearActiveTest->setToolTip(QStringLiteral("If a test was interrupted, restores its saved original OBS UI Scale settings/dock position and clears the stuck active-test marker."));
        auto *close = buttons->addButton(QDialogButtonBox::Close);
'@ 'add active-test recovery button'

Replace-Required @'
        QObject::connect(completeTest, &QPushButton::clicked, &dialog,
                         [this, uiSpin, textSpin, matchButton, proportional, safeTiny, autoApply,
                          sceneRowLock, sceneRowsSpin, debugLogging, apply, restore, &dialog, status]() {
                             BeginCompleteUserActionTest(uiSpin, textSpin, matchButton,
                                                         proportional, safeTiny, autoApply,
                                                         sceneRowLock, sceneRowsSpin, debugLogging,
                                                         apply, restore, &dialog, status);
                         });
        QObject::connect(close, &QPushButton::clicked, &dialog, &QDialog::accept);
'@ @'
        QObject::connect(completeTest, &QPushButton::clicked, &dialog,
                         [this, uiSpin, textSpin, matchButton, proportional, safeTiny, autoApply,
                          sceneRowLock, sceneRowsSpin, debugLogging, apply, restore, &dialog, status]() {
                             BeginCompleteUserActionTest(uiSpin, textSpin, matchButton,
                                                         proportional, safeTiny, autoApply,
                                                         sceneRowLock, sceneRowsSpin, debugLogging,
                                                         apply, restore, &dialog, status);
                         });
        QObject::connect(clearActiveTest, &QPushButton::clicked, &dialog,
                         [this, &dialog, status]() {
                             if (!settings_ || !settings_->value(QStringLiteral("debug/restartTestActive"), false).toBool()) {
                                 QMessageBox::information(&dialog, QStringLiteral("OBS UI Scale Test Recovery"),
                                                          QStringLiteral("No restart/complete test state is currently active."));
                                 return;
                             }
                             const auto answer = QMessageBox::question(
                                 &dialog, QStringLiteral("OBS UI Scale Test Recovery"),
                                 QStringLiteral("Restore the saved original settings/dock position and clear the active test state?"),
                                 QMessageBox::Yes | QMessageBox::No, QMessageBox::Yes);
                             if (answer == QMessageBox::Yes)
                                 RecoverAndClearActiveTest(&dialog, status);
                         });
        QObject::connect(close, &QPushButton::clicked, &dialog, &QDialog::accept);
'@ 'connect active-test recovery button'

# Self-identifying build text.
$s = $s.Replace('OBS UI Scale v3.16 DEBUG', 'OBS UI Scale v3.16.1 DEBUG')
$s = $s.Replace('OBS UI Scale v3.16 DEBUG LOG', 'OBS UI Scale v3.16.1 DEBUG LOG')
$s = $s.Replace('OBS UI Scale v3.16 -', 'OBS UI Scale v3.16.1 -')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.16.0', '3.16.1')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.16.1 DEBUG abandoned-test restore/clear recovery.'
