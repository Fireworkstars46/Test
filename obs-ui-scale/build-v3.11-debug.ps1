$ErrorActionPreference = 'Stop'

# v3.11 keeps the v3.10 Apply/current-height fix and adds a one-click, non-destructive
# live self-test. The button deliberately exercises the failure modes found during
# v3.5-v3.10: row-floor geometry, Audio Mixer floor blocking, programmatic resize
# persistence isolation, normal Apply preserving the CURRENT visible height, and
# startup Apply restoring the persisted manual height. Every temporary dock change
# is restored at the end, including the saved manual-height setting if a test fails.
& ./build-v3.10-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.11 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.10.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.11.0-debug";' 'plugin version'

if (-not $s.Contains('#include <QMessageBox>')) {
    $s = $s.Replace('#include <QMainWindow>', "#include <QMainWindow>`n#include <QMessageBox>`n#include <QPointer>")
}

# Add the asynchronous self-test engine immediately before the dialog. It never
# fakes mouse input and never changes the user's saved scale/row-count settings.
# A real physical separator drag is therefore not synthesized; instead the suite
# verifies the important guard from v3.9 by proving programmatic resizes do NOT
# change the persisted manual height.
$insertMarker = '    void ShowDialog()'
$insertPos = $s.IndexOf($insertMarker)
if ($insertPos -lt 0) { throw 'v3.11 could not locate ShowDialog insertion point' }
$selfTest = @'
    struct SelfTestState {
        int originalDockHeight = -1;
        int originalSavedManualHeight = -1;
        int applyProbeHeight = -1;
        int rowPitch = -1;
        int passCount = 0;
        int failCount = 0;
        int skipCount = 0;
        QString details;
        QPointer<QLabel> status;
        QPointer<QPushButton> button;
    };

    void SelfTestRecord(const std::shared_ptr<SelfTestState> &state, const QString &name,
                        bool passed, const QString &detail)
    {
        if (!state)
            return;

        if (passed)
            ++state->passCount;
        else
            ++state->failCount;

        const QString line = QStringLiteral("%1  %2 - %3")
                                 .arg(passed ? QStringLiteral("PASS") : QStringLiteral("FAIL"))
                                 .arg(name)
                                 .arg(detail);
        state->details += line + QLatin1Char('\n');
        DebugWrite(QStringLiteral("SELF-TEST %1").arg(line));
        blog(passed ? LOG_INFO : LOG_WARNING, "[%s] SELF-TEST %s", PLUGIN_NAME,
             line.toUtf8().constData());
    }

    void SelfTestSkip(const std::shared_ptr<SelfTestState> &state, const QString &name,
                      const QString &detail)
    {
        if (!state)
            return;
        ++state->skipCount;
        const QString line = QStringLiteral("SKIP  %1 - %2").arg(name).arg(detail);
        state->details += line + QLatin1Char('\n');
        DebugWrite(QStringLiteral("SELF-TEST %1").arg(line));
    }

    void FinishSelfTest(const std::shared_ptr<SelfTestState> &state)
    {
        if (!state)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();

        // The suite is intentionally non-destructive. Restore both the visible
        // dock position and the exact persisted manual value that existed when
        // the button was pressed, even if the code under test misbehaved.
        if (mainWindow && sceneDock && state->originalDockHeight > 0) {
            const int floorHeight = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
            const int restoreHeight = qMax(floorHeight, state->originalDockHeight);
            restoringDockTargets_ = true;
            mainWindow->resizeDocks({sceneDock}, {restoreHeight}, Qt::Vertical);
            restoringDockTargets_ = false;
            ReassertSceneRowLock();
        }

        savedManualSceneDockHeight_ = state->originalSavedManualHeight;
        if (settings_) {
            if (savedManualSceneDockHeight_ > 0)
                settings_->setValue(QStringLiteral("ui/manualSceneDockHeight"), savedManualSceneDockHeight_);
            else
                settings_->remove(QStringLiteral("ui/manualSceneDockHeight"));
            settings_->sync();
        }

        selfTestRunning_ = false;
        if (state->button) {
            state->button->setEnabled(true);
            state->button->setText(QStringLiteral("Run Full Self-Test"));
        }

        const bool allPassed = state->failCount == 0;
        const QString headline = allPassed ? QStringLiteral("SELF-TEST PASSED")
                                           : QStringLiteral("SELF-TEST FOUND ISSUES");
        const QString summary = QStringLiteral("%1\n\nPassed: %2   Failed: %3   Skipped: %4\n\n%5")
                                    .arg(headline)
                                    .arg(state->passCount)
                                    .arg(state->failCount)
                                    .arg(state->skipCount)
                                    .arg(state->details.trimmed());

        if (state->status)
            state->status->setText(QStringLiteral("%1 - %2 passed, %3 failed, %4 skipped")
                                       .arg(headline)
                                       .arg(state->passCount)
                                       .arg(state->failCount)
                                       .arg(state->skipCount));

        DebugWrite(QStringLiteral("========== SELF-TEST COMPLETE pass=%1 fail=%2 skip=%3 ==========")
                       .arg(state->passCount)
                       .arg(state->failCount)
                       .arg(state->skipCount));

        QMessageBox::information(mainWindow, QStringLiteral("OBS UI Scale Full Self-Test"), summary);
    }

    void RunFullSelfTest(QLabel *status, QPushButton *button)
    {
        if (selfTestRunning_) {
            if (status)
                status->setText(QStringLiteral("Self-test is already running..."));
            return;
        }

        auto state = std::make_shared<SelfTestState>();
        state->status = status;
        state->button = button;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        QListWidget *scenes = ScenesList();
        QStackedWidget *mixer = StackedMixerArea();
        QDockWidget *mixerDock = AudioMixerDock();

        if (!mainWindow || !sceneDock || !scenes || !mixer) {
            SelfTestRecord(state, QStringLiteral("OBS dock discovery"), false,
                           QStringLiteral("Scenes/scene list/Audio Mixer was not available."));
            FinishSelfTest(state);
            return;
        }

        selfTestRunning_ = true;
        if (button) {
            button->setEnabled(false);
            button->setText(QStringLiteral("Testing..."));
        }
        if (status)
            status->setText(QStringLiteral("Self-test 1/4: checking live OBS layout..."));

        state->originalDockHeight = sceneDock->height();
        state->originalSavedManualHeight = savedManualSceneDockHeight_;
        state->rowPitch = CurrentSceneRowHeight();

        DebugWrite(QStringLiteral("========== SELF-TEST START currentH=%1 savedManual=%2 rows=%3 pitch=%4 ==========")
                       .arg(state->originalDockHeight)
                       .arg(state->originalSavedManualHeight)
                       .arg(sceneVisibleRows_)
                       .arg(state->rowPitch));

        SelfTestRecord(state, QStringLiteral("Real dock layout"),
                       StartupDockLayoutReady(),
                       QStringLiteral("Scenes is visible/restored in the real Bottom dock layout."));
        SelfTestRecord(state, QStringLiteral("Scenes dock area"),
                       !sceneDock->isFloating() && mainWindow->dockWidgetArea(sceneDock) == Qt::BottomDockWidgetArea,
                       QStringLiteral("Scenes must be docked in the Bottom area for row-floor tests."));
        SelfTestRecord(state, QStringLiteral("Scene row geometry"),
                       state->rowPitch > 0 && CalculateSceneDockHeightForRows() > 0,
                       QStringLiteral("Live visual row pitch=%1 px, calculated floor=%2 px.")
                           .arg(state->rowPitch)
                           .arg(CalculateSceneDockHeightForRows()));
        SelfTestRecord(state, QStringLiteral("Audio Mixer discovery"), mixerDock != nullptr,
                       mixerDock ? QStringLiteral("mixerDock found.") : QStringLiteral("mixerDock not found."));

        if (!sceneRowLockEnabled_ || lockedSceneDockHeight_ <= 0) {
            SelfTestSkip(state, QStringLiteral("Minimum scene-row floor"),
                         QStringLiteral("Minimum scene rows is disabled; floor/mixer-floor tests skipped."));
        }

        // Create an intentionally UNSAVED current dock position before Apply.
        // This is the exact condition that exposed the v3.9 Apply bug: old saved
        // manual height != what is visibly on screen when Apply is pressed.
        const int floorNow = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
        const int pitch = qMax(8, state->rowPitch);
        int probeHeight;
        if (state->originalDockHeight >= floorNow + pitch * 4)
            probeHeight = state->originalDockHeight - pitch * 2;
        else
            probeHeight = floorNow + pitch * 2;

        const int practicalMax = qMax(floorNow, mainWindow->height() - 140);
        probeHeight = qBound(floorNow, probeHeight, practicalMax);
        if (state->originalSavedManualHeight > 0 && qAbs(probeHeight - state->originalSavedManualHeight) <= 3)
            probeHeight = qBound(floorNow, probeHeight + pitch, practicalMax);

        restoringDockTargets_ = true;
        mainWindow->resizeDocks({sceneDock}, {probeHeight}, Qt::Vertical);
        restoringDockTargets_ = false;
        ReassertSceneRowLock();

        QTimer::singleShot(600, this, [this, state]() {
            QDockWidget *sceneDock = ScenesDock();
            if (!sceneDock) {
                SelfTestRecord(state, QStringLiteral("Apply probe setup"), false,
                               QStringLiteral("Scenes dock disappeared during test."));
                FinishSelfTest(state);
                return;
            }

            state->applyProbeHeight = sceneDock->height();
            SelfTestRecord(state, QStringLiteral("Programmatic resize isolation"),
                           savedManualSceneDockHeight_ == state->originalSavedManualHeight,
                           QStringLiteral("Temporary resize=%1 px; persisted manual remained %2 px.")
                               .arg(state->applyProbeHeight)
                               .arg(state->originalSavedManualHeight));

            if (state->status)
                state->status->setText(QStringLiteral("Self-test 2/4: testing Apply preservation..."));

            // Normal Apply must preserve the CURRENT probe height, not the old
            // persisted manual height. This directly regression-tests v3.10.
            startupApplyUsesSavedManual_ = false;
            ApplyScale(uiPercent_, textPercent_);

            QTimer::singleShot(3900, this, [this, state]() {
                auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
                QDockWidget *sceneDock = ScenesDock();
                if (!mainWindow || !sceneDock) {
                    SelfTestRecord(state, QStringLiteral("Apply preservation"), false,
                                   QStringLiteral("Scenes dock unavailable after Apply."));
                    FinishSelfTest(state);
                    return;
                }

                const int floorAfterApply = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
                const int expected = qMax(floorAfterApply, state->applyProbeHeight);
                const int actual = sceneDock->height();
                SelfTestRecord(state, QStringLiteral("Current-height Apply preservation"),
                               qAbs(actual - expected) <= 3,
                               QStringLiteral("Expected %1 px from visible pre-Apply position; got %2 px.")
                                   .arg(expected)
                                   .arg(actual));
                SelfTestRecord(state, QStringLiteral("Apply does not rewrite manual save"),
                               savedManualSceneDockHeight_ == state->originalSavedManualHeight,
                               QStringLiteral("Persisted manual before/after Apply=%1/%2 px.")
                                   .arg(state->originalSavedManualHeight)
                                   .arg(savedManualSceneDockHeight_));
                SelfTestRecord(state, QStringLiteral("Apply settle state"),
                               applyPreservedSceneDockHeight_ < 0 && !suppressManualDockCapture_,
                               QStringLiteral("Temporary Apply ceiling/suppression fully released."));

                if (state->status)
                    state->status->setText(QStringLiteral("Self-test 3/4: testing scene-row and mixer floor..."));

                if (!sceneRowLockEnabled_ || lockedSceneDockHeight_ <= 0) {
                    SelfTestSkip(state, QStringLiteral("Exact row-floor reachability"),
                                 QStringLiteral("Minimum scene rows is disabled."));
                    SelfTestSkip(state, QStringLiteral("Audio Mixer floor blocker"),
                                 QStringLiteral("Minimum scene rows is disabled."));
                } else {
                    const int floor = lockedSceneDockHeight_;
                    restoringDockTargets_ = true;
                    mainWindow->resizeDocks({sceneDock}, {floor}, Qt::Vertical);
                    restoringDockTargets_ = false;
                    ReassertSceneRowLock();
                }

                QTimer::singleShot(900, this, [this, state]() {
                    auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
                    QDockWidget *sceneDock = ScenesDock();
                    QListWidget *scenes = ScenesList();
                    if (!mainWindow || !sceneDock || !scenes) {
                        SelfTestRecord(state, QStringLiteral("Row-floor verification"), false,
                                       QStringLiteral("Scenes widgets unavailable during floor verification."));
                        FinishSelfTest(state);
                        return;
                    }

                    if (sceneRowLockEnabled_ && lockedSceneDockHeight_ > 0) {
                        const int floor = lockedSceneDockHeight_;
                        const int actual = sceneDock->height();
                        const int pitchNow = qMax(1, CurrentSceneRowHeight());
                        const int viewportHeight = scenes->viewport() ? scenes->viewport()->height() : -1;
                        const int fullRowsByPitch = viewportHeight > 0 ? viewportHeight / pitchNow : -1;

                        SelfTestRecord(state, QStringLiteral("Exact row-floor reachability"),
                                       qAbs(actual - floor) <= 3,
                                       QStringLiteral("Configured floor=%1 px; actual minimum=%2 px.")
                                           .arg(floor)
                                           .arg(actual));
                        SelfTestRecord(state, QStringLiteral("Visible scene-row capacity"),
                                       fullRowsByPitch == sceneVisibleRows_,
                                       QStringLiteral("Configured rows=%1; live viewport fits %2 full %3 px rows.")
                                           .arg(sceneVisibleRows_)
                                           .arg(fullRowsByPitch)
                                           .arg(pitchNow));
                        SelfTestRecord(state, QStringLiteral("Audio Mixer floor blocker"),
                                       actual <= floor + 3,
                                       QStringLiteral("Bottom row can reach the Scenes floor; mixer is not forcing it taller."));
                    }

                    SelfTestRecord(state, QStringLiteral("Floor resize does not rewrite manual save"),
                                   savedManualSceneDockHeight_ == state->originalSavedManualHeight,
                                   QStringLiteral("Persisted manual remains %1 px.")
                                       .arg(state->originalSavedManualHeight));

                    if (state->status)
                        state->status->setText(QStringLiteral("Self-test 4/4: simulating startup restore..."));

                    // Simulate the dedicated startup Apply path without actually
                    // restarting OBS. This confirms that startup still prefers the
                    // persisted genuine manual height while normal Apply does not.
                    if (state->originalSavedManualHeight <= 0) {
                        SelfTestSkip(state, QStringLiteral("Startup persisted-height restore"),
                                     QStringLiteral("No persisted manual height exists yet."));
                        FinishSelfTest(state);
                        return;
                    }

                    const int floor = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
                    const int pitchNow = qMax(8, CurrentSceneRowHeight());
                    const int practicalMax = qMax(floor, mainWindow->height() - 140);
                    int alternate = qBound(floor, floor + pitchNow * 2, practicalMax);
                    if (qAbs(alternate - state->originalSavedManualHeight) <= 3)
                        alternate = qBound(floor, alternate + pitchNow, practicalMax);

                    restoringDockTargets_ = true;
                    mainWindow->resizeDocks({sceneDock}, {alternate}, Qt::Vertical);
                    restoringDockTargets_ = false;
                    ReassertSceneRowLock();

                    QTimer::singleShot(500, this, [this, state]() {
                        startupApplyUsesSavedManual_ = true;
                        ApplyScale(uiPercent_, textPercent_);
                        startupApplyUsesSavedManual_ = false;

                        QTimer::singleShot(3900, this, [this, state]() {
                            QDockWidget *sceneDock = ScenesDock();
                            if (!sceneDock) {
                                SelfTestRecord(state, QStringLiteral("Startup persisted-height restore"), false,
                                               QStringLiteral("Scenes dock unavailable after simulated startup Apply."));
                                FinishSelfTest(state);
                                return;
                            }

                            const int floor = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
                            const int expected = qMax(floor, state->originalSavedManualHeight);
                            const int actual = sceneDock->height();
                            SelfTestRecord(state, QStringLiteral("Startup persisted-height restore"),
                                           qAbs(actual - expected) <= 3,
                                           QStringLiteral("Expected saved startup target %1 px; got %2 px.")
                                               .arg(expected)
                                               .arg(actual));
                            SelfTestRecord(state, QStringLiteral("Startup simulation keeps save intact"),
                                           savedManualSceneDockHeight_ == state->originalSavedManualHeight,
                                           QStringLiteral("Persisted manual stayed %1 px.")
                                               .arg(state->originalSavedManualHeight));
                            FinishSelfTest(state);
                        });
                    });
                });
            });
        });
    }

'@
$s = $s.Substring(0, $insertPos) + $selfTest + $s.Substring($insertPos)

# Put the test button in the existing bottom button bar.
Replace-Required @'
        auto *apply = buttons->addButton(QStringLiteral("Apply"), QDialogButtonBox::ApplyRole);
        auto *restore = buttons->addButton(QStringLiteral("Restore 100% / 100%"), QDialogButtonBox::ResetRole);
        auto *close = buttons->addButton(QDialogButtonBox::Close);
'@ @'
        auto *apply = buttons->addButton(QStringLiteral("Apply"), QDialogButtonBox::ApplyRole);
        auto *restore = buttons->addButton(QStringLiteral("Restore 100% / 100%"), QDialogButtonBox::ResetRole);
        auto *selfTest = buttons->addButton(QStringLiteral("Run Full Self-Test"), QDialogButtonBox::ActionRole);
        selfTest->setToolTip(QStringLiteral("Temporarily exercises Apply preservation, scene-row minimum, Audio Mixer floor, persistence isolation, and startup restore, then restores your original dock position."));
        auto *close = buttons->addButton(QDialogButtonBox::Close);
'@ 'add self-test button'

Replace-Required @'
        QObject::connect(close, &QPushButton::clicked, &dialog, &QDialog::accept);
'@ @'
        QObject::connect(selfTest, &QPushButton::clicked, &dialog,
                         [this, status, selfTest]() { RunFullSelfTest(status, selfTest); });
        QObject::connect(close, &QPushButton::clicked, &dialog, &QDialog::accept);
'@ 'connect self-test button'

Replace-Required @'
    bool startupApplyUsesSavedManual_ = false;
'@ @'
    bool startupApplyUsesSavedManual_ = false;
    bool selfTestRunning_ = false;
'@ 'self-test running member'

$s = $s.Replace('OBS UI Scale v3.10 DEBUG', 'OBS UI Scale v3.11 DEBUG')
$s = $s.Replace('OBS UI Scale v3.10 DEBUG LOG', 'OBS UI Scale v3.11 DEBUG LOG')
$s = $s.Replace('v3.10 DEBUG keeps the v3.9 persistence fix and makes normal Apply preserve the exact currently visible dock height while startup Apply alone restores the persisted manual height. Debug logging remains optional.',
                'v3.11 DEBUG keeps the v3.10 Apply fix and adds a one-click Full Self-Test for current-height Apply preservation, exact scene-row floor, Audio Mixer blocking, persistence isolation, and simulated startup restoration. Debug logging remains optional.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.10.0', '3.11.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.10.0', 'OBS-UI-Scale-Debug-Setup-3.11.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.11 DEBUG full automatic self-test button.'
