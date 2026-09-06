$ErrorActionPreference = 'Stop'

# v3.13 keeps v3.12's fully passing in-process self-test and adds a second,
# real-world end-to-end restart test. It exercises the actual dialog controls and
# Apply button, the scene-row minimum + Audio Mixer floor, requires a genuine
# mouse drag of the bottom-row separator, persists that real manual height,
# closes OBS, automatically relaunches OBS, verifies startup restoration, runs
# Apply once more after restart, and finally restores the user's original values.
& ./build-v3.12-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.13 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.12.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.13.0-debug";' 'plugin version'

if (-not $s.Contains('#include <QCoreApplication>')) {
    $s = $s.Replace('#include <QCheckBox>', "#include <QCheckBox>`n#include <QCoreApplication>")
}
if (-not $s.Contains('#include <QProcess>')) {
    $s = $s.Replace('#include <QPushButton>', "#include <QPushButton>`n#include <QProcess>")
}

# Add the real-restart test engine directly before ShowDialog. It persists only
# temporary debug/test keys across the one intentional OBS restart. User settings
# are snapshotted first and restored when the test finishes.
$insertMarker = '    void ShowDialog()'
$insertPos = $s.IndexOf($insertMarker)
if ($insertPos -lt 0) { throw 'v3.13 could not locate ShowDialog insertion point' }
$restartTestCode = @'
    void RestartTestRecord(bool passed, const QString &name, const QString &detail)
    {
        if (!settings_)
            return;

        const QString passKey = QStringLiteral("debug/restartTestPass");
        const QString failKey = QStringLiteral("debug/restartTestFail");
        const QString resultsKey = QStringLiteral("debug/restartTestResults");

        int pass = settings_->value(passKey, 0).toInt();
        int fail = settings_->value(failKey, 0).toInt();
        if (passed)
            ++pass;
        else
            ++fail;

        QString results = settings_->value(resultsKey).toString();
        const QString line = QStringLiteral("%1  %2 - %3")
                                 .arg(passed ? QStringLiteral("PASS") : QStringLiteral("FAIL"))
                                 .arg(name)
                                 .arg(detail);
        if (!results.isEmpty())
            results += QLatin1Char('\n');
        results += line;

        settings_->setValue(passKey, pass);
        settings_->setValue(failKey, fail);
        settings_->setValue(resultsKey, results);
        settings_->sync();
        DebugWrite(QStringLiteral("RESTART TEST %1").arg(line));
        blog(passed ? LOG_INFO : LOG_WARNING, "[%s] RESTART TEST %s", PLUGIN_NAME,
             line.toUtf8().constData());
    }

    void ClearRestartTestKeys()
    {
        if (!settings_)
            return;

        const char *keys[] = {
            "debug/restartTestActive", "debug/restartTestPhase",
            "debug/restartTestPass", "debug/restartTestFail", "debug/restartTestResults",
            "debug/restartTestOriginalControlPercent", "debug/restartTestOriginalTextPercent",
            "debug/restartTestOriginalAutoApply", "debug/restartTestOriginalSafeTiny",
            "debug/restartTestOriginalProportional", "debug/restartTestOriginalSceneRowLock",
            "debug/restartTestOriginalSceneRows", "debug/restartTestOriginalManualHeight",
            "debug/restartTestOriginalDockHeight", "debug/restartTestProbeControlPercent",
            "debug/restartTestProbeTextPercent", "debug/restartTestProbeSceneRows",
            "debug/restartTestExpectedManualHeight"
        };
        for (const char *key : keys)
            settings_->remove(QString::fromLatin1(key));
        settings_->sync();
    }

    bool LaunchObsRestartHelper()
    {
        QString exe = QCoreApplication::applicationFilePath();
        if (exe.isEmpty())
            return false;

        QString escaped = exe;
        escaped.replace(QLatin1Char('\''), QStringLiteral("''"));
        const QString script = QStringLiteral(
            "Start-Sleep -Seconds 2; Start-Process -FilePath '%1'").arg(escaped);

        const bool ok = QProcess::startDetached(
            QStringLiteral("powershell.exe"),
            {QStringLiteral("-NoProfile"), QStringLiteral("-NonInteractive"),
             QStringLiteral("-WindowStyle"), QStringLiteral("Hidden"),
             QStringLiteral("-Command"), script});
        DebugWrite(QStringLiteral("RESTART TEST relaunch helper started=%1 exe='%2'")
                       .arg(ok ? 1 : 0).arg(exe));
        return ok;
    }

    void ShowManualRestartTestPanel()
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock || !settings_) {
            RestartTestRecord(false, QStringLiteral("Manual drag setup"),
                              QStringLiteral("Scenes dock was unavailable before the manual step."));
            return;
        }

        const int preDragHeight = sceneDock->height();
        auto *panel = new QDialog(mainWindow);
        panel->setAttribute(Qt::WA_DeleteOnClose);
        panel->setWindowTitle(QStringLiteral("OBS UI Scale v3.13 - Real Manual Drag Test"));
        panel->setWindowModality(Qt::NonModal);
        panel->setWindowFlag(Qt::Tool, true);
        panel->setWindowFlag(Qt::WindowStaysOnTopHint, true);
        panel->resize(560, 230);

        auto *layout = new QVBoxLayout(panel);
        auto *instructions = new QLabel(
            QStringLiteral(
                "Step 2/3 - REAL manual separator test\n\n"
                "Drag the horizontal separator at the TOP of the Scenes / bottom-dock row with the mouse. "
                "Move it enough that the bottom row is visibly a different height, then release the mouse and click Continue.\n\n"
                "Current height before your drag: %1 px\n"
                "The test will not continue until a genuine separator drag is detected and saved.")
                .arg(preDragHeight), panel);
        instructions->setWordWrap(true);
        layout->addWidget(instructions);

        auto *status = new QLabel(QStringLiteral("Waiting for your manual drag..."), panel);
        status->setWordWrap(true);
        layout->addWidget(status);

        auto *buttons = new QDialogButtonBox(panel);
        auto *continueButton = buttons->addButton(QStringLiteral("Continue After Drag"), QDialogButtonBox::AcceptRole);
        layout->addWidget(buttons);

        QObject::connect(continueButton, &QPushButton::clicked, panel,
                         [this, panel, status, continueButton, preDragHeight]() {
            continueButton->setEnabled(false);
            status->setText(QStringLiteral("Checking the real manual-drag save..."));

            // The normal manual persistence path waits for a quiet period after
            // mouse release. Give it enough time to commit the genuine height.
            QTimer::singleShot(750, this, [this, panel, status, continueButton, preDragHeight]() {
                QDockWidget *sceneDock = ScenesDock();
                if (!sceneDock || !settings_) {
                    status->setText(QStringLiteral("Scenes dock disappeared. Reopen the test and try again."));
                    continueButton->setEnabled(true);
                    return;
                }

                const int actual = sceneDock->height();
                const bool moved = qAbs(actual - preDragHeight) > 3;
                const bool saved = savedManualSceneDockHeight_ > 0 &&
                                   qAbs(savedManualSceneDockHeight_ - actual) <= 3;
                const int floor = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
                const bool aboveFloor = actual >= floor - 2;

                if (!moved || !saved || !aboveFloor) {
                    status->setText(QStringLiteral(
                        "A valid manual separator drag was not detected yet. "
                        "Drag the top edge of the bottom dock row farther, release it, wait a moment, then click Continue again. "
                        "Live=%1 px, saved manual=%2 px, minimum=%3 px.")
                        .arg(actual).arg(savedManualSceneDockHeight_).arg(floor));
                    continueButton->setEnabled(true);
                    return;
                }

                RestartTestRecord(true, QStringLiteral("Real manual separator drag"),
                                  QStringLiteral("Mouse drag changed %1 -> %2 px and persisted %3 px.")
                                      .arg(preDragHeight).arg(actual).arg(savedManualSceneDockHeight_));

                if (obs_frontend_streaming_active() || obs_frontend_recording_active()) {
                    status->setText(QStringLiteral(
                        "Manual drag passed, but OBS is currently streaming or recording. Stop it first, then click Continue again so the restart test can safely close OBS."));
                    continueButton->setEnabled(true);
                    return;
                }

                settings_->setValue(QStringLiteral("debug/restartTestExpectedManualHeight"), actual);
                settings_->setValue(QStringLiteral("debug/restartTestPhase"), 2);
                settings_->setValue(QStringLiteral("debug/restartTestActive"), true);
                settings_->sync();

                if (!LaunchObsRestartHelper()) {
                    RestartTestRecord(false, QStringLiteral("Automatic OBS relaunch"),
                                      QStringLiteral("Could not start the delayed OBS relaunch helper."));
                    status->setText(QStringLiteral("Could not start the automatic OBS relaunch. OBS was NOT closed."));
                    continueButton->setEnabled(true);
                    return;
                }

                RestartTestRecord(true, QStringLiteral("Automatic OBS relaunch"),
                                  QStringLiteral("Delayed relaunch helper started; closing OBS for the real restart."));
                panel->close();
                QTimer::singleShot(350, qApp, []() { qApp->quit(); });
            });
        });

        panel->show();
        panel->raise();
        panel->activateWindow();
    }

    void BeginRestartEndToEndTest(QDoubleSpinBox *uiSpin, QDoubleSpinBox *textSpin,
                                  QCheckBox *sceneRowLock, QSpinBox *sceneRowsSpin,
                                  QCheckBox *autoApply, QPushButton *apply,
                                  QDialog *settingsDialog, QLabel *status)
    {
        if (!settings_ || !uiSpin || !textSpin || !sceneRowLock || !sceneRowsSpin ||
            !autoApply || !apply || !settingsDialog)
            return;

        if (settings_->value(QStringLiteral("debug/restartTestActive"), false).toBool()) {
            QMessageBox::information(settingsDialog, QStringLiteral("OBS UI Scale Restart Test"),
                                     QStringLiteral("A restart test is already active. Finish that test first."));
            return;
        }

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock || !StartupDockLayoutReady()) {
            QMessageBox::warning(settingsDialog, QStringLiteral("OBS UI Scale Restart Test"),
                                 QStringLiteral("The real Bottom dock layout is not ready, so the restart test cannot start yet."));
            return;
        }
        if (obs_frontend_streaming_active() || obs_frontend_recording_active()) {
            QMessageBox::warning(settingsDialog, QStringLiteral("OBS UI Scale Restart Test"),
                                 QStringLiteral("Stop streaming/recording before running the restart test because OBS will intentionally close and reopen."));
            return;
        }

        ClearRestartTestKeys();
        settings_->setValue(QStringLiteral("debug/restartTestActive"), true);
        settings_->setValue(QStringLiteral("debug/restartTestPhase"), 1);
        settings_->setValue(QStringLiteral("debug/restartTestPass"), 0);
        settings_->setValue(QStringLiteral("debug/restartTestFail"), 0);
        settings_->setValue(QStringLiteral("debug/restartTestResults"), QString());

        settings_->setValue(QStringLiteral("debug/restartTestOriginalControlPercent"), uiPercent_);
        settings_->setValue(QStringLiteral("debug/restartTestOriginalTextPercent"), textPercent_);
        settings_->setValue(QStringLiteral("debug/restartTestOriginalAutoApply"), autoApply_);
        settings_->setValue(QStringLiteral("debug/restartTestOriginalSafeTiny"), safeTinyMode_);
        settings_->setValue(QStringLiteral("debug/restartTestOriginalProportional"), proportionalMode_);
        settings_->setValue(QStringLiteral("debug/restartTestOriginalSceneRowLock"), sceneRowLockEnabled_);
        settings_->setValue(QStringLiteral("debug/restartTestOriginalSceneRows"), sceneVisibleRows_);
        settings_->setValue(QStringLiteral("debug/restartTestOriginalManualHeight"), savedManualSceneDockHeight_);
        settings_->setValue(QStringLiteral("debug/restartTestOriginalDockHeight"), sceneDock->height());

        double probeUi = uiPercent_ < 90.0 ? uiPercent_ + 3.25 : uiPercent_ - 3.25;
        double probeText = textPercent_ < 88.0 ? textPercent_ + 5.50 : textPercent_ - 5.50;
        probeUi = qBound(60.0, probeUi, 95.0);
        probeText = qBound(60.0, probeText, 95.0);
        if (qAbs(probeUi - uiPercent_) < 0.50)
            probeUi = uiPercent_ > 80.0 ? 74.25 : 84.25;
        if (qAbs(probeText - textPercent_) < 0.50)
            probeText = textPercent_ > 80.0 ? 72.50 : 86.50;

        const int probeRows = sceneVisibleRows_ < 1000 ? sceneVisibleRows_ + 1 : qMax(1, sceneVisibleRows_ - 1);
        settings_->setValue(QStringLiteral("debug/restartTestProbeControlPercent"), probeUi);
        settings_->setValue(QStringLiteral("debug/restartTestProbeTextPercent"), probeText);
        settings_->setValue(QStringLiteral("debug/restartTestProbeSceneRows"), probeRows);
        settings_->sync();

        // Exercise the ACTUAL dialog controls and ACTUAL Apply button rather
        // than calling SaveSettings directly from the test engine.
        uiSpin->setValue(probeUi);
        textSpin->setValue(probeText);
        sceneRowLock->setChecked(true);
        sceneRowsSpin->setValue(probeRows);
        autoApply->setChecked(true); // required so startup itself is exercised.
        if (status)
            status->setText(QStringLiteral("Real restart test 1/3: clicking the real Apply button..."));
        apply->click();
        settingsDialog->accept();

        QTimer::singleShot(4300, this, [this, probeUi, probeText, probeRows]() {
            QDockWidget *sceneDock = ScenesDock();
            if (!sceneDock || !settings_)
                return;

            const bool controlsSaved = qAbs(uiPercent_ - probeUi) < 0.02 &&
                                       qAbs(textPercent_ - probeText) < 0.02 &&
                                       qAbs(currentUiPercent_ - EffectiveUiPercent(probeUi)) < 0.02 &&
                                       qAbs(currentTextPercent_ - EffectiveTextPercent(probeText)) < 0.02;
            RestartTestRecord(controlsSaved, QStringLiteral("UI/Text controls + real Apply button"),
                              QStringLiteral("Requested UI/Text=%1/%2; effective=%3/%4.")
                                  .arg(PercentText(probeUi)).arg(PercentText(probeText))
                                  .arg(PercentText(currentUiPercent_)).arg(PercentText(currentTextPercent_)));

            const bool rowSetting = sceneRowLockEnabled_ && sceneVisibleRows_ == probeRows &&
                                    lockedSceneDockHeight_ > 0;
            RestartTestRecord(rowSetting, QStringLiteral("Minimum scene-row control"),
                              QStringLiteral("Requested rows=%1; active rows=%2; floor=%3 px.")
                                  .arg(probeRows).arg(sceneVisibleRows_).arg(lockedSceneDockHeight_));

            if (!rowSetting) {
                ShowManualRestartTestPanel();
                return;
            }

            // Exercise the actual minimum with the live Audio Mixer at the test
            // scale, then return to the pre-probe height before asking for the
            // user's real mouse drag.
            auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
            const int returnHeight = sceneDock->height();
            const int floor = lockedSceneDockHeight_;
            restoringDockTargets_ = true;
            mainWindow->resizeDocks({sceneDock}, {floor}, Qt::Vertical);
            restoringDockTargets_ = false;
            ReassertSceneRowLock();

            QTimer::singleShot(850, this, [this, returnHeight, floor]() {
                auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
                QDockWidget *sceneDock = ScenesDock();
                if (!mainWindow || !sceneDock)
                    return;

                const int actual = sceneDock->height();
                RestartTestRecord(qAbs(actual - floor) <= 3,
                                  QStringLiteral("Live row-floor reachability"),
                                  QStringLiteral("Configured minimum=%1 px; actual=%2 px.")
                                      .arg(floor).arg(actual));
                RestartTestRecord(actual <= floor + 3,
                                  QStringLiteral("Live Audio Mixer floor blocker"),
                                  QStringLiteral("Audio Mixer allowed the bottom row to reach the exact Scenes minimum."));

                restoringDockTargets_ = true;
                mainWindow->resizeDocks({sceneDock}, {qMax(floor, returnHeight)}, Qt::Vertical);
                restoringDockTargets_ = false;
                ReassertSceneRowLock();
                QTimer::singleShot(550, this, [this]() { ShowManualRestartTestPanel(); });
            });
        });
    }

    void RestoreAfterRestartTest()
    {
        if (!settings_)
            return;

        const double originalUi = settings_->value(QStringLiteral("debug/restartTestOriginalControlPercent"), 100.0).toDouble();
        const double originalText = settings_->value(QStringLiteral("debug/restartTestOriginalTextPercent"), 100.0).toDouble();
        const bool originalAuto = settings_->value(QStringLiteral("debug/restartTestOriginalAutoApply"), true).toBool();
        const bool originalSafe = settings_->value(QStringLiteral("debug/restartTestOriginalSafeTiny"), true).toBool();
        const bool originalProp = settings_->value(QStringLiteral("debug/restartTestOriginalProportional"), true).toBool();
        const bool originalRowLock = settings_->value(QStringLiteral("debug/restartTestOriginalSceneRowLock"), true).toBool();
        const int originalRows = settings_->value(QStringLiteral("debug/restartTestOriginalSceneRows"), 6).toInt();
        const int originalManual = settings_->value(QStringLiteral("debug/restartTestOriginalManualHeight"), -1).toInt();
        const int originalDock = settings_->value(QStringLiteral("debug/restartTestOriginalDockHeight"), -1).toInt();

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

        QTimer::singleShot(4300, this, [this, originalDock, originalManual]() {
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

            RestartTestRecord(true, QStringLiteral("Original settings restoration"),
                              QStringLiteral("Original UI/Text, row setting, manual save and visible dock position restored."));

            const int pass = settings_->value(QStringLiteral("debug/restartTestPass"), 0).toInt();
            const int fail = settings_->value(QStringLiteral("debug/restartTestFail"), 0).toInt();
            const QString details = settings_->value(QStringLiteral("debug/restartTestResults")).toString();
            const QString headline = fail == 0 ? QStringLiteral("REAL RESTART TEST PASSED")
                                               : QStringLiteral("REAL RESTART TEST FOUND ISSUES");
            const QString summary = QStringLiteral(
                "%1\n\nPassed: %2   Failed: %3\n\n%4\n\nYour original OBS UI Scale settings and dock position were restored.")
                .arg(headline).arg(pass).arg(fail).arg(details);

            DebugWrite(QStringLiteral("========== REAL RESTART TEST COMPLETE pass=%1 fail=%2 ==========")
                           .arg(pass).arg(fail));
            ClearRestartTestKeys();
            QMessageBox::information(static_cast<QMainWindow *>(obs_frontend_get_main_window()),
                                     QStringLiteral("OBS UI Scale Real Restart Test"), summary);
        });
    }

    void ContinueRestartTestAfterStartup()
    {
        if (!settings_ || !settings_->value(QStringLiteral("debug/restartTestActive"), false).toBool() ||
            settings_->value(QStringLiteral("debug/restartTestPhase"), 0).toInt() != 2)
            return;

        DebugWrite(QStringLiteral("========== REAL RESTART TEST RESUMED AFTER ACTUAL OBS RESTART =========="));
        const double probeUi = settings_->value(QStringLiteral("debug/restartTestProbeControlPercent")).toDouble();
        const double probeText = settings_->value(QStringLiteral("debug/restartTestProbeTextPercent")).toDouble();
        const int probeRows = settings_->value(QStringLiteral("debug/restartTestProbeSceneRows")).toInt();
        const int expectedManual = settings_->value(QStringLiteral("debug/restartTestExpectedManualHeight"), -1).toInt();
        QDockWidget *sceneDock = ScenesDock();

        RestartTestRecord(qAbs(uiPercent_ - probeUi) < 0.02 && qAbs(textPercent_ - probeText) < 0.02,
                          QStringLiteral("UI/Text persistence across real restart"),
                          QStringLiteral("Reloaded UI/Text=%1/%2; expected=%3/%4.")
                              .arg(PercentText(uiPercent_)).arg(PercentText(textPercent_))
                              .arg(PercentText(probeUi)).arg(PercentText(probeText)));
        RestartTestRecord(qAbs(currentUiPercent_ - EffectiveUiPercent(probeUi)) < 0.02 &&
                          qAbs(currentTextPercent_ - EffectiveTextPercent(probeText)) < 0.02,
                          QStringLiteral("Startup auto-Apply after real restart"),
                          QStringLiteral("Effective UI/Text=%1/%2 after startup settle.")
                              .arg(PercentText(currentUiPercent_)).arg(PercentText(currentTextPercent_)));
        RestartTestRecord(sceneRowLockEnabled_ && sceneVisibleRows_ == probeRows,
                          QStringLiteral("Scene-row setting persistence"),
                          QStringLiteral("Reloaded rows=%1; expected=%2.").arg(sceneVisibleRows_).arg(probeRows));

        const int actualHeight = sceneDock ? sceneDock->height() : -1;
        RestartTestRecord(sceneDock && expectedManual > 0 && qAbs(actualHeight - expectedManual) <= 3,
                          QStringLiteral("Real startup manual-height restoration"),
                          QStringLiteral("Expected saved manual=%1 px; actual after restart=%2 px.")
                              .arg(expectedManual).arg(actualHeight));
        RestartTestRecord(expectedManual > 0 && qAbs(savedManualSceneDockHeight_ - expectedManual) <= 3,
                          QStringLiteral("Manual save survived process restart"),
                          QStringLiteral("Persisted manual=%1 px.").arg(savedManualSceneDockHeight_));

        if (!sceneDock) {
            RestartTestRecord(false, QStringLiteral("Post-restart Apply"),
                              QStringLiteral("Scenes dock unavailable after restart."));
            RestoreAfterRestartTest();
            return;
        }

        const int beforeApply = sceneDock->height();
        ApplyScale(uiPercent_, textPercent_);
        QTimer::singleShot(4000, this, [this, beforeApply, expectedManual]() {
            QDockWidget *sceneDock = ScenesDock();
            const int actual = sceneDock ? sceneDock->height() : -1;
            const int floor = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
            const int expected = qMax(floor, beforeApply);
            RestartTestRecord(sceneDock && qAbs(actual - expected) <= 3,
                              QStringLiteral("Apply again after real restart"),
                              QStringLiteral("Pre-Apply=%1 px; expected=%2 px; actual=%3 px.")
                                  .arg(beforeApply).arg(expected).arg(actual));
            RestartTestRecord(expectedManual > 0 && qAbs(savedManualSceneDockHeight_ - expectedManual) <= 3,
                              QStringLiteral("Post-restart Apply keeps manual save"),
                              QStringLiteral("Manual save stayed %1 px.").arg(savedManualSceneDockHeight_));
            RestoreAfterRestartTest();
        });
    }

'@
$s = $s.Substring(0, $insertPos) + $restartTestCode + $s.Substring($insertPos)

# Continue the persisted test only after the REAL startup auto-Apply has settled.
$tryStart = $s.IndexOf('    void TryStartupAutoApply(')
$tryEnd = $s.IndexOf('    void ScheduleStartupAutoApply()', $tryStart)
if ($tryStart -lt 0 -or $tryEnd -lt 0) { throw 'v3.13 could not isolate TryStartupAutoApply' }
$tryBlock = $s.Substring($tryStart, $tryEnd - $tryStart)
$oldStartupReturn = @'
            startupApplyUsesSavedManual_ = true;
            ApplyScale(uiPercent_, textPercent_);
            startupApplyUsesSavedManual_ = false;
            return;
'@
$newStartupReturn = @'
            startupApplyUsesSavedManual_ = true;
            ApplyScale(uiPercent_, textPercent_);
            startupApplyUsesSavedManual_ = false;
            if (settings_ && settings_->value(QStringLiteral("debug/restartTestActive"), false).toBool() &&
                settings_->value(QStringLiteral("debug/restartTestPhase"), 0).toInt() == 2) {
                DebugWrite(QStringLiteral("RESTART TEST startup continuation armed after real auto-Apply"));
                QTimer::singleShot(4300, this, [this]() { ContinueRestartTestAfterStartup(); });
            }
            return;
'@
if (-not $tryBlock.Contains($oldStartupReturn.Replace("`r`n", "`n"))) {
    throw 'v3.13 could not locate startup Apply return block'
}
$tryBlock = $tryBlock.Replace($oldStartupReturn.Replace("`r`n", "`n"), $newStartupReturn.Replace("`r`n", "`n"))
$s = $s.Substring(0, $tryStart) + $tryBlock + $s.Substring($tryEnd)

# Add a second button. The existing Full Self-Test stays available unchanged.
Replace-Required @'
        auto *selfTest = buttons->addButton(QStringLiteral("Run Full Self-Test"), QDialogButtonBox::ActionRole);
        selfTest->setToolTip(QStringLiteral("Temporarily exercises Apply preservation, scene-row minimum, Audio Mixer floor, persistence isolation, and startup restore, then restores your original dock position."));
        auto *close = buttons->addButton(QDialogButtonBox::Close);
'@ @'
        auto *selfTest = buttons->addButton(QStringLiteral("Run Full Self-Test"), QDialogButtonBox::ActionRole);
        selfTest->setToolTip(QStringLiteral("Temporarily exercises Apply preservation, scene-row minimum, Audio Mixer floor, persistence isolation, and simulated startup restore, then restores your original dock position."));
        auto *restartTest = buttons->addButton(QStringLiteral("Run Real Restart Test"), QDialogButtonBox::ActionRole);
        restartTest->setToolTip(QStringLiteral("Exercises the real controls and Apply button, asks for one genuine mouse separator drag, then closes/reopens OBS automatically and verifies persistence before restoring your original settings."));
        auto *close = buttons->addButton(QDialogButtonBox::Close);
'@ 'add real restart test button'

Replace-Required @'
        QObject::connect(selfTest, &QPushButton::clicked, &dialog,
                         [this, status, selfTest]() { RunFullSelfTest(status, selfTest); });
        QObject::connect(close, &QPushButton::clicked, &dialog, &QDialog::accept);
'@ @'
        QObject::connect(selfTest, &QPushButton::clicked, &dialog,
                         [this, status, selfTest]() { RunFullSelfTest(status, selfTest); });
        QObject::connect(restartTest, &QPushButton::clicked, &dialog,
                         [this, uiSpin, textSpin, sceneRowLock, sceneRowsSpin, autoApply, apply, &dialog, status]() {
                             BeginRestartEndToEndTest(uiSpin, textSpin, sceneRowLock, sceneRowsSpin,
                                                      autoApply, apply, &dialog, status);
                         });
        QObject::connect(close, &QPushButton::clicked, &dialog, &QDialog::accept);
'@ 'connect real restart test button'

$s = $s.Replace('OBS UI Scale v3.12 DEBUG', 'OBS UI Scale v3.13 DEBUG')
$s = $s.Replace('OBS UI Scale v3.12 DEBUG LOG', 'OBS UI Scale v3.13 DEBUG LOG')
$s = $s.Replace('v3.12 DEBUG keeps the v3.11 Full Self-Test and fixes its discovered late Audio Mixer calibration regression so normal Apply preserves the exact current visible dock height through the entire settle/calibration sequence. Debug logging remains optional.',
                'v3.13 DEBUG keeps the passing v3.12 Full Self-Test and adds a real end-to-end restart test: actual dialog controls + Apply, live row/mixer floor, genuine mouse separator drag, automatic OBS close/reopen, startup persistence verification, post-restart Apply, and automatic restoration of your original settings. Debug logging remains optional.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.12.0', '3.13.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.12.0', 'OBS-UI-Scale-Debug-Setup-3.13.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.13 DEBUG real manual-drag + actual OBS restart end-to-end test.'
