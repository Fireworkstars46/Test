$ErrorActionPreference = 'Stop'

# v3.15 DEBUG starts from the validated v3.14 stable build and fixes the newly
# discovered race: a genuine separator drag was only persisted after a 300 ms
# quiet timer. Clicking a Scene immediately after releasing the mouse could arm
# the scene guard first, cancel that timer, and restore the older dock height.
#
# The fix makes a gesture-qualified separator resize authoritative immediately:
# the live stable-row target, in-memory manual height, and persisted manual height
# are updated during the real drag itself. Scene changes therefore cannot race
# ahead of the user's latest position.
#
# v3.15 also adds a comprehensive user-action test. It exercises the ACTUAL
# settings controls/buttons (UI, Text, Match, proportional, safe-tiny, Auto Apply,
# scene-row lock/count, debug logging, Apply, Restore 100), then runs the real
# manual/restart test. The manual portion now requires a real drag to the minimum,
# a second real drag upward followed IMMEDIATELY by a real Scene click, repeated
# Scene clicks, a real OBS close/reopen, and post-restart Apply/persistence checks.
& ./build-v3.14-stable.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.15 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

function Replace-Block([string]$startMarker, [string]$endMarker, [string]$newBlock, [string]$label) {
    $start = $script:s.IndexOf($startMarker)
    if ($start -lt 0) { throw "v3.15 could not locate start of $label" }
    $end = $script:s.IndexOf($endMarker, $start)
    if ($end -lt 0) { throw "v3.15 could not locate end of $label" }
    $script:s = $script:s.Substring(0, $start) + $newBlock.Replace("`r`n", "`n") + $script:s.Substring($end)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.14.0";' 'static constexpr const char *PLUGIN_VERSION = "3.15.0-debug";' 'plugin version'

if (-not $s.Contains('#include <QList>')) {
    $s = $s.Replace('#include <QLabel>', "#include <QLabel>`n#include <QList>")
}

# ---------------------------------------------------------------------------
# FIX: persist a genuine manual separator drag immediately, not 300 ms later.
# The v3.9 gesture qualification remains intact, so programmatic/window-layout
# resizes still cannot become the saved manual position.
# ---------------------------------------------------------------------------
$manualBlock = @'
        if (event && event->type() == QEvent::Resize && !sceneDockGuardActive_ &&
            !restoringDockTargets_ && !suppressManualDockCapture_ &&
            IsManualBottomRowResizeGesture() &&
            proportionalMode_ && currentUiPercent_ < 99.999) {
            if (auto *dock = qobject_cast<QDockWidget *>(watched)) {
                if (dock->property(PROP_DOCK_STABLE_H).isValid()) {
                    // This Resize is already proven to be a real left-mouse drag
                    // on QMainWindow's horizontal bottom-row separator. Make the
                    // user's newest position authoritative NOW. Waiting for a
                    // quiet timer lets an immediate Scene click cancel the save.
                    ++manualDockCaptureGeneration_;
                    ++manualResizeSerial_;
                    CaptureStableDockTargets();

                    if (QDockWidget *sceneDock = ScenesDock()) {
                        const int manualHeight = sceneDock->height();
                        const int floorHeight = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
                        if (manualHeight >= floorHeight && manualHeight > 0) {
                            savedManualSceneDockHeight_ = manualHeight;
                            lastImmediateManualSceneDockHeight_ = manualHeight;
                            if (settings_) {
                                settings_->setValue(QStringLiteral("ui/manualSceneDockHeight"),
                                                    savedManualSceneDockHeight_);
                                // Sync immediately so even a scene click followed
                                // by an immediate OBS close cannot lose the drag.
                                settings_->sync();
                            }
                            DebugWrite(QStringLiteral(
                                "MANUAL SCENE DOCK HEIGHT SAVED IMMEDIATELY height=%1 serial=%2")
                                           .arg(savedManualSceneDockHeight_)
                                           .arg(manualResizeSerial_));
                        }
                    }
                    DebugWrite(QStringLiteral("MANUAL DOCK SIZE CAPTURED IMMEDIATELY"));
                }
            }
        }

'@
Replace-Block '        if (event && event->type() == QEvent::Resize && !sceneDockGuardActive_ &&' '        return QObject::eventFilter(watched, event);' $manualBlock 'manual drag persistence block'

# Count real user Scene/preview changes. The complete test uses these counters to
# prove that the manual-drag race was exercised by an actual scene selection.
Replace-Required @'
        self->DebugFrontendEvent(event);

        if (event == OBS_FRONTEND_EVENT_PREVIEW_SCENE_CHANGED) {
'@ @'
        self->DebugFrontendEvent(event);

        if (event == OBS_FRONTEND_EVENT_SCENE_CHANGED)
            ++self->completeSceneChangeCounter_;
        else if (event == OBS_FRONTEND_EVENT_PREVIEW_SCENE_CHANGED)
            ++self->completePreviewSceneChangeCounter_;

        if (event == OBS_FRONTEND_EVENT_PREVIEW_SCENE_CHANGED) {
'@ 'count actual scene selection events'

# Keep the restart/manual test at the user's CURRENT row count. Row-count changes
# are exercised separately by the new control preflight, so the real drag-to-floor
# step tests the actual everyday minimum (for the current user this is normally 7).
Replace-Required @'
        const int probeRows = sceneVisibleRows_ < 1000 ? sceneVisibleRows_ + 1 : qMax(1, sceneVisibleRows_ - 1);
'@ @'
        const int probeRows = qBound(1, sceneVisibleRows_, 1000);
'@ 'real restart test uses current row count'

# Make the standalone real-restart test robust even if the user normally has
# proportional/safe-tiny disabled. It snapshots those originals first, then the
# actual Apply button runs with the known test-safe settings and restoration puts
# the user's originals back at the end.
Replace-Required @'
    void BeginRestartEndToEndTest(QDoubleSpinBox *uiSpin, QDoubleSpinBox *textSpin,
                                  QCheckBox *sceneRowLock, QSpinBox *sceneRowsSpin,
                                  QCheckBox *autoApply, QPushButton *apply,
                                  QDialog *settingsDialog, QLabel *status)
'@ @'
    void BeginRestartEndToEndTest(QDoubleSpinBox *uiSpin, QDoubleSpinBox *textSpin,
                                  QCheckBox *proportional, QCheckBox *safeTiny,
                                  QCheckBox *sceneRowLock, QSpinBox *sceneRowsSpin,
                                  QCheckBox *autoApply, QPushButton *apply,
                                  QDialog *settingsDialog, QLabel *status)
'@ 'restart test signature includes option controls'

Replace-Required @'
        if (!settings_ || !uiSpin || !textSpin || !sceneRowLock || !sceneRowsSpin ||
            !autoApply || !apply || !settingsDialog)
'@ @'
        if (!settings_ || !uiSpin || !textSpin || !proportional || !safeTiny ||
            !sceneRowLock || !sceneRowsSpin || !autoApply || !apply || !settingsDialog)
'@ 'restart test validation includes option controls'

Replace-Required @'
        // Exercise the ACTUAL dialog controls and ACTUAL Apply button rather
        // than calling SaveSettings directly from the test engine.
        uiSpin->setValue(probeUi);
'@ @'
        // Exercise the ACTUAL dialog controls and ACTUAL Apply button rather
        // than calling SaveSettings directly from the test engine. The manual
        // persistence path is meaningful only in proportional mode, so the test
        // temporarily enables proportional + safe-tiny after their original
        // values were already snapshotted above.
        proportional->setChecked(true);
        safeTiny->setChecked(true);
        uiSpin->setValue(probeUi);
'@ 'restart test enables test-safe option modes'

# ---------------------------------------------------------------------------
# Replace the old single-drag/750ms panel with a race-focused guided test.
# ---------------------------------------------------------------------------
$manualPanel = @'
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
        const int initialSerial = manualResizeSerial_;
        auto stage = std::make_shared<int>(0);
        auto stageSerial = std::make_shared<int>(initialSerial);
        auto sceneEventStart = std::make_shared<int>(
            completeSceneChangeCounter_ + completePreviewSceneChangeCounter_);
        auto expectedManual = std::make_shared<int>(-1);

        auto *panel = new QDialog(mainWindow);
        panel->setAttribute(Qt::WA_DeleteOnClose);
        panel->setWindowTitle(QStringLiteral("OBS UI Scale v3.15 DEBUG - Complete Manual/Scene Test"));
        panel->setWindowModality(Qt::NonModal);
        panel->setWindowFlag(Qt::Tool, true);
        panel->setWindowFlag(Qt::WindowStaysOnTopHint, true);
        panel->resize(610, 285);

        auto *layout = new QVBoxLayout(panel);
        auto *instructions = new QLabel(
            QStringLiteral(
                "Manual step 1/3 - REAL drag to the minimum\n\n"
                "Drag the horizontal separator at the TOP of the Scenes / bottom-dock row ALL THE WAY DOWN until it stops at the configured scene-row minimum, then release the mouse and click Continue.\n\n"
                "If it is already at the minimum, first drag it a little upward, then drag it all the way back down.\n"
                "Starting height: %1 px   Current configured minimum: %2 px")
                .arg(preDragHeight)
                .arg(sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1), panel);
        instructions->setWordWrap(true);
        layout->addWidget(instructions);

        auto *status = new QLabel(QStringLiteral("Waiting for your real separator drag..."), panel);
        status->setWordWrap(true);
        layout->addWidget(status);

        auto *buttons = new QDialogButtonBox(panel);
        auto *continueButton = buttons->addButton(QStringLiteral("Continue"), QDialogButtonBox::AcceptRole);
        layout->addWidget(buttons);

        QObject::connect(continueButton, &QPushButton::clicked, panel,
                         [this, panel, instructions, status, continueButton, stage, stageSerial,
                          sceneEventStart, expectedManual, initialSerial]() {
            QDockWidget *sceneDock = ScenesDock();
            if (!sceneDock || !settings_) {
                status->setText(QStringLiteral("Scenes dock disappeared. Reopen the test and try again."));
                return;
            }

            const int live = sceneDock->height();
            const int floor = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;

            if (*stage == 0) {
                const bool realDragSeen = manualResizeSerial_ > initialSerial;
                const bool atFloor = qAbs(live - floor) <= 3;
                const bool immediateSaved = lastImmediateManualSceneDockHeight_ > 0 &&
                                            qAbs(lastImmediateManualSceneDockHeight_ - live) <= 3 &&
                                            qAbs(savedManualSceneDockHeight_ - live) <= 3;
                if (!realDragSeen || !atFloor || !immediateSaved) {
                    status->setText(QStringLiteral(
                        "Not ready yet. Drag the separator with the mouse all the way down and release it. "
                        "Live=%1 px, minimum=%2 px, saved=%3 px, drag serial=%4.")
                        .arg(live).arg(floor).arg(savedManualSceneDockHeight_).arg(manualResizeSerial_));
                    return;
                }

                RestartTestRecord(true, QStringLiteral("Real manual drag to scene-row minimum"),
                                  QStringLiteral("Real separator drag reached %1 px and was saved immediately at %2 px.")
                                      .arg(live).arg(savedManualSceneDockHeight_));

                *stage = 1;
                *stageSerial = manualResizeSerial_;
                *sceneEventStart = completeSceneChangeCounter_ + completePreviewSceneChangeCounter_;
                status->setText(QStringLiteral("Waiting for the drag + immediate Scene click sequence..."));
                instructions->setText(QStringLiteral(
                    "Manual step 2/3 - NEW BUG RACE TEST\n\n"
                    "1. Drag the same separator UP so the bottom row is clearly taller.\n"
                    "2. RELEASE the mouse.\n"
                    "3. IMMEDIATELY click a DIFFERENT Scene in the Scenes list — do not wait.\n"
                    "4. Then click Continue here.\n\n"
                    "This specifically tests that a Scene click cannot cancel or replace the manual position you just chose."));
                return;
            }

            if (*stage == 1) {
                const int eventsNow = completeSceneChangeCounter_ + completePreviewSceneChangeCounter_;
                const bool secondRealDrag = manualResizeSerial_ > *stageSerial;
                const int expected = lastImmediateManualSceneDockHeight_;
                const bool movedUp = expected > floor + 3;
                const bool sceneClicked = eventsNow > *sceneEventStart;
                const bool saveKept = expected > 0 && qAbs(savedManualSceneDockHeight_ - expected) <= 3;
                const bool liveKept = expected > 0 && qAbs(live - expected) <= 3;

                if (!secondRealDrag || !movedUp || !sceneClicked || !saveKept || !liveKept) {
                    status->setText(QStringLiteral(
                        "Sequence not passed yet. Do the UP drag, release, then immediately click a different Scene. "
                        "Live=%1 px, latest drag=%2 px, saved=%3 px, scene events=%4, drag serial=%5.")
                        .arg(live).arg(expected).arg(savedManualSceneDockHeight_)
                        .arg(eventsNow - *sceneEventStart).arg(manualResizeSerial_));
                    return;
                }

                *expectedManual = expected;
                RestartTestRecord(true, QStringLiteral("Immediate manual-height persistence"),
                                  QStringLiteral("Upward real drag saved %1 px immediately before any quiet timer.")
                                      .arg(expected));
                RestartTestRecord(true, QStringLiteral("Immediate Scene click observed"),
                                  QStringLiteral("A real Scene/preview selection event occurred immediately after the drag."));
                RestartTestRecord(true, QStringLiteral("Scene click keeps newest manual position"),
                                  QStringLiteral("After the immediate Scene click, live/saved manual remained %1/%2 px.")
                                      .arg(live).arg(savedManualSceneDockHeight_));

                *stage = 2;
                *sceneEventStart = eventsNow;
                status->setText(QStringLiteral("Click at least TWO more different Scenes, then click Continue."));
                instructions->setText(QStringLiteral(
                    "Manual step 3/3 - repeated Scene-change stability\n\n"
                    "Click at least TWO more different Scenes in the Scenes list, one after another. "
                    "If Studio Mode is enabled, preview-scene clicks count too.\n\n"
                    "Do not touch the separator during this step. Then click Continue. The dock must still be at %1 px.")
                    .arg(*expectedManual));
                return;
            }

            const int eventsNow = completeSceneChangeCounter_ + completePreviewSceneChangeCounter_;
            const int extraEvents = eventsNow - *sceneEventStart;
            const bool enoughSceneClicks = extraEvents >= 2;
            const bool stable = *expectedManual > 0 &&
                                qAbs(sceneDock->height() - *expectedManual) <= 3 &&
                                qAbs(savedManualSceneDockHeight_ - *expectedManual) <= 3;
            if (!enoughSceneClicks || !stable) {
                status->setText(QStringLiteral(
                    "Need at least two additional Scene clicks with no dock movement. "
                    "Clicks seen=%1, live=%2 px, expected=%3 px, saved=%4 px.")
                    .arg(extraEvents).arg(sceneDock->height()).arg(*expectedManual)
                    .arg(savedManualSceneDockHeight_));
                return;
            }

            RestartTestRecord(true, QStringLiteral("Repeated Scene selection stability"),
                              QStringLiteral("%1 additional real Scene/preview changes kept live/saved height at %2 px.")
                                  .arg(extraEvents).arg(*expectedManual));

            if (obs_frontend_streaming_active() || obs_frontend_recording_active()) {
                status->setText(QStringLiteral(
                    "Manual/Scene tests passed, but OBS is streaming or recording. Stop it first, then click Continue so the restart phase can safely close OBS."));
                return;
            }

            settings_->setValue(QStringLiteral("debug/restartTestExpectedManualHeight"), *expectedManual);
            settings_->setValue(QStringLiteral("debug/restartTestPhase"), 2);
            settings_->setValue(QStringLiteral("debug/restartTestActive"), true);
            settings_->sync();

            if (!LaunchObsRestartHelper()) {
                RestartTestRecord(false, QStringLiteral("Automatic OBS relaunch"),
                                  QStringLiteral("Could not start the delayed OBS relaunch helper."));
                status->setText(QStringLiteral("Could not start the automatic OBS relaunch. OBS was NOT closed."));
                return;
            }

            RestartTestRecord(true, QStringLiteral("Automatic OBS relaunch"),
                              QStringLiteral("Delayed relaunch helper started; closing OBS for the real restart."));
            panel->close();
            QTimer::singleShot(350, qApp, []() { qApp->quit(); });
        });

        panel->show();
        panel->raise();
        panel->activateWindow();
    }

'@
Replace-Block '    void ShowManualRestartTestPanel()' '    void BeginRestartEndToEndTest(' $manualPanel 'real manual/scene race test panel'

# ---------------------------------------------------------------------------
# Comprehensive preflight: exercise every normal plugin control/button through
# the same Qt signal path the user invokes. After it restores the original state,
# it hands off to the real manual + restart test above.
# ---------------------------------------------------------------------------
$completeCode = @'
    struct CompleteCheckResult {
        bool passed = false;
        QString name;
        QString detail;
    };

    struct CompleteOriginalState {
        double ui = 100.0;
        double text = 100.0;
        bool proportional = true;
        bool safeTiny = true;
        bool autoApply = true;
        bool rowLock = true;
        int rows = 1;
        bool debugLogging = false;
    };

    void QueueCompleteCheck(bool passed, const QString &name, const QString &detail)
    {
        CompleteCheckResult result;
        result.passed = passed;
        result.name = name;
        result.detail = detail;
        completePreflightResults_.push_back(result);
        DebugWrite(QStringLiteral("COMPLETE PREFLIGHT %1 %2 - %3")
                       .arg(passed ? QStringLiteral("PASS") : QStringLiteral("FAIL"), name, detail));
    }

    void FlushCompleteChecksIntoRestartResult()
    {
        if (!settings_)
            return;
        settings_->setValue(QStringLiteral("debug/completeUserActionTestActive"), true);
        settings_->sync();
        for (const CompleteCheckResult &result : completePreflightResults_)
            RestartTestRecord(result.passed, result.name, result.detail);
        completePreflightResults_.clear();
    }

    static void ClickCheckBoxTo(QCheckBox *box, bool checked)
    {
        if (box && box->isChecked() != checked)
            box->click();
    }

    void BeginCompleteUserActionTest(QDoubleSpinBox *uiSpin, QDoubleSpinBox *textSpin,
                                     QPushButton *matchButton,
                                     QCheckBox *proportional, QCheckBox *safeTiny,
                                     QCheckBox *autoApply, QCheckBox *sceneRowLock,
                                     QSpinBox *sceneRowsSpin, QCheckBox *debugLogging,
                                     QPushButton *apply, QPushButton *restore,
                                     QDialog *settingsDialog, QLabel *status)
    {
        if (!settings_ || !uiSpin || !textSpin || !matchButton || !proportional || !safeTiny ||
            !autoApply || !sceneRowLock || !sceneRowsSpin || !debugLogging || !apply || !restore ||
            !settingsDialog)
            return;

        if (settings_->value(QStringLiteral("debug/restartTestActive"), false).toBool()) {
            QMessageBox::information(settingsDialog, QStringLiteral("OBS UI Scale Complete Test"),
                                     QStringLiteral("A restart/complete test is already active. Finish it first."));
            return;
        }
        if (obs_frontend_streaming_active() || obs_frontend_recording_active()) {
            QMessageBox::warning(settingsDialog, QStringLiteral("OBS UI Scale Complete Test"),
                                 QStringLiteral("Stop streaming/recording first. The final phase intentionally closes and reopens OBS."));
            return;
        }

        auto original = std::make_shared<CompleteOriginalState>();
        original->ui = uiPercent_;
        original->text = textPercent_;
        original->proportional = proportional->isChecked();
        original->safeTiny = safeTiny->isChecked();
        original->autoApply = autoApply->isChecked();
        original->rowLock = sceneRowLock->isChecked();
        original->rows = sceneRowsSpin->value();
        original->debugLogging = debugLogging->isChecked();
        completePreflightResults_.clear();

        if (status)
            status->setText(QStringLiteral("Complete test preflight: exercising every normal control/button..."));

        // Match Text to UI button - actual button click.
        double matchProbe = qBound(60.0, original->ui < 90.0 ? original->ui + 4.25 : original->ui - 4.25, 95.0);
        uiSpin->setValue(matchProbe);
        textSpin->setValue(qBound(55.0, matchProbe - 7.0, 98.0));
        matchButton->click();
        QueueCompleteCheck(qAbs(textSpin->value() - uiSpin->value()) < 0.02,
                           QStringLiteral("Match text to UI button"),
                           QStringLiteral("Actual button made Text=%1 match UI=%2.")
                               .arg(PercentText(textSpin->value())).arg(PercentText(uiSpin->value())));

        // Debug logging checkbox - actual click both directions, ending exactly
        // where the user started.
        debugLogging->click();
        QueueCompleteCheck(debugLoggingEnabled_ == debugLogging->isChecked() &&
                           debugLogging->isChecked() != original->debugLogging,
                           QStringLiteral("Debug logging toggle"),
                           QStringLiteral("Actual checkbox changed logging state to %1.")
                               .arg(debugLoggingEnabled_ ? QStringLiteral("ON") : QStringLiteral("OFF")));
        debugLogging->click();
        QueueCompleteCheck(debugLoggingEnabled_ == original->debugLogging,
                           QStringLiteral("Debug logging restore toggle"),
                           QStringLiteral("Actual checkbox returned logging to the original %1 state.")
                               .arg(original->debugLogging ? QStringLiteral("ON") : QStringLiteral("OFF")));

        // Change every option and the scale values, then click the ACTUAL Apply.
        const double applyProbeUi = qBound(62.0, original->ui < 88.0 ? original->ui + 6.50 : original->ui - 6.50, 94.0);
        const double applyProbeText = qBound(61.0, original->text < 87.0 ? original->text + 5.25 : original->text - 5.25, 93.0);
        uiSpin->setValue(applyProbeUi);
        textSpin->setValue(applyProbeText);
        ClickCheckBoxTo(proportional, !original->proportional);
        ClickCheckBoxTo(safeTiny, !original->safeTiny);
        ClickCheckBoxTo(autoApply, !original->autoApply);
        ClickCheckBoxTo(sceneRowLock, false);
        apply->click();

        QTimer::singleShot(4300, this,
            [this, original, uiSpin, textSpin, proportional, safeTiny, autoApply, sceneRowLock,
             sceneRowsSpin, debugLogging, apply, restore, settingsDialog, status,
             matchButton, applyProbeUi, applyProbeText]() {

            QueueCompleteCheck(qAbs(uiPercent_ - applyProbeUi) < 0.02 &&
                               qAbs(textPercent_ - applyProbeText) < 0.02 &&
                               qAbs(currentUiPercent_ - EffectiveUiPercent(applyProbeUi)) < 0.02 &&
                               qAbs(currentTextPercent_ - EffectiveTextPercent(applyProbeText)) < 0.02,
                               QStringLiteral("UI/Text controls + Apply button"),
                               QStringLiteral("Actual Apply saved UI/Text=%1/%2 and applied effective=%3/%4.")
                                   .arg(PercentText(uiPercent_)).arg(PercentText(textPercent_))
                                   .arg(PercentText(currentUiPercent_)).arg(PercentText(currentTextPercent_)));
            QueueCompleteCheck(proportionalMode_ == !original->proportional,
                               QStringLiteral("Proportional-mode checkbox + Apply"),
                               QStringLiteral("Applied state=%1.").arg(proportionalMode_ ? QStringLiteral("ON") : QStringLiteral("OFF")));
            QueueCompleteCheck(safeTinyMode_ == !original->safeTiny,
                               QStringLiteral("Safe-tiny checkbox + Apply"),
                               QStringLiteral("Applied state=%1.").arg(safeTinyMode_ ? QStringLiteral("ON") : QStringLiteral("OFF")));
            QueueCompleteCheck(autoApply_ == !original->autoApply,
                               QStringLiteral("Auto Apply checkbox + Apply"),
                               QStringLiteral("Saved state=%1.").arg(autoApply_ ? QStringLiteral("ON") : QStringLiteral("OFF")));
            QueueCompleteCheck(!sceneRowLockEnabled_ && lockedSceneDockHeight_ == 0,
                               QStringLiteral("Scene-row lock OFF + Apply"),
                               QStringLiteral("Row lock disabled and active pixel floor released."));

            // ACTUAL Restore 100% button.
            restore->click();
            QTimer::singleShot(4300, this,
                [this, original, uiSpin, textSpin, proportional, safeTiny, autoApply, sceneRowLock,
                 sceneRowsSpin, debugLogging, apply, settingsDialog, status, matchButton]() {

                QueueCompleteCheck(qAbs(uiSpin->value() - 100.0) < 0.02 &&
                                   qAbs(textSpin->value() - 100.0) < 0.02 &&
                                   qAbs(currentUiPercent_ - 100.0) < 0.02 &&
                                   qAbs(currentTextPercent_ - 100.0) < 0.02,
                                   QStringLiteral("Restore 100% / 100% button"),
                                   QStringLiteral("Actual Restore button returned controls/effective scale to 100/100."));

                // Test the row-count control itself at a different value with
                // the actual Apply button, then put every control back exactly.
                const int rowProbe = original->rows < 1000 ? original->rows + 1 : qMax(1, original->rows - 1);
                ClickCheckBoxTo(proportional, true);
                ClickCheckBoxTo(safeTiny, true);
                ClickCheckBoxTo(sceneRowLock, true);
                sceneRowsSpin->setValue(rowProbe);
                uiSpin->setValue(qBound(60.0, original->ui, 95.0));
                textSpin->setValue(qBound(60.0, original->text, 95.0));
                apply->click();

                QTimer::singleShot(4300, this,
                    [this, original, uiSpin, textSpin, proportional, safeTiny, autoApply,
                     sceneRowLock, sceneRowsSpin, debugLogging, apply, settingsDialog, status,
                     matchButton, rowProbe]() {

                    QueueCompleteCheck(sceneRowLockEnabled_ && sceneVisibleRows_ == rowProbe &&
                                       lockedSceneDockHeight_ > 0,
                                       QStringLiteral("Minimum scene-row count control + Apply"),
                                       QStringLiteral("Actual control requested %1 rows; active=%2 floor=%3 px.")
                                           .arg(rowProbe).arg(sceneVisibleRows_).arg(lockedSceneDockHeight_));

                    // Restore every original control using the same real controls
                    // and one final actual Apply before handing off to restart.
                    uiSpin->setValue(original->ui);
                    textSpin->setValue(original->text);
                    ClickCheckBoxTo(proportional, original->proportional);
                    ClickCheckBoxTo(safeTiny, original->safeTiny);
                    ClickCheckBoxTo(autoApply, original->autoApply);
                    ClickCheckBoxTo(sceneRowLock, original->rowLock);
                    sceneRowsSpin->setValue(original->rows);
                    ClickCheckBoxTo(debugLogging, original->debugLogging);
                    apply->click();

                    QTimer::singleShot(4300, this,
                        [this, original, uiSpin, textSpin, proportional, safeTiny, autoApply,
                         sceneRowLock, sceneRowsSpin, debugLogging, apply, settingsDialog, status,
                         matchButton]() {

                        QueueCompleteCheck(qAbs(uiPercent_ - original->ui) < 0.02 &&
                                           qAbs(textPercent_ - original->text) < 0.02 &&
                                           proportionalMode_ == original->proportional &&
                                           safeTinyMode_ == original->safeTiny &&
                                           autoApply_ == original->autoApply &&
                                           sceneRowLockEnabled_ == original->rowLock &&
                                           sceneVisibleRows_ == original->rows &&
                                           debugLoggingEnabled_ == original->debugLogging,
                                           QStringLiteral("Preflight original-state restoration"),
                                           QStringLiteral("All normal controls were returned to their exact pre-test values before restart testing."));

                        // The existing real-restart engine now takes over. It
                        // snapshots these restored originals, uses actual controls
                        // + Apply, then opens the strengthened real manual/Scene
                        // panel and finally performs the process restart.
                        BeginRestartEndToEndTest(uiSpin, textSpin, proportional, safeTiny,
                                                 sceneRowLock, sceneRowsSpin, autoApply, apply,
                                                 settingsDialog, status);
                        FlushCompleteChecksIntoRestartResult();
                    });
                });
            });
        });
    }

'@
$insertMarker = '    void ShowDialog()'
$insertPos = $s.IndexOf($insertMarker)
if ($insertPos -lt 0) { throw 'v3.15 could not locate ShowDialog for complete test insertion' }
$s = $s.Substring(0, $insertPos) + $completeCode.Replace("`r`n", "`n") + $s.Substring($insertPos)

# Add the Complete User-Action Test button while retaining both older diagnostic
# tests for focused troubleshooting.
Replace-Required @'
        auto *restartTest = buttons->addButton(QStringLiteral("Run Real Restart Test"), QDialogButtonBox::ActionRole);
        restartTest->setToolTip(QStringLiteral("Exercises the real controls and Apply button, asks for one genuine mouse separator drag, then closes/reopens OBS automatically and verifies persistence before restoring your original settings."));
        auto *close = buttons->addButton(QDialogButtonBox::Close);
'@ @'
        auto *restartTest = buttons->addButton(QStringLiteral("Run Real Restart Test"), QDialogButtonBox::ActionRole);
        restartTest->setToolTip(QStringLiteral("Exercises the real controls and Apply button, real manual/Scene interactions, then closes/reopens OBS automatically and verifies persistence before restoring your original settings."));
        auto *completeTest = buttons->addButton(QStringLiteral("Run Complete User-Action Test"), QDialogButtonBox::ActionRole);
        completeTest->setToolTip(QStringLiteral("Tests every normal OBS UI Scale control/button, real manual drag-to-minimum, immediate and repeated real Scene clicks, real OBS restart, startup restore, and Apply after restart."));
        auto *close = buttons->addButton(QDialogButtonBox::Close);
'@ 'add complete user-action test button'

# Update the standalone restart button for the expanded signature and connect the
# new complete test with every real dialog control/button it exercises.
Replace-Required @'
        QObject::connect(restartTest, &QPushButton::clicked, &dialog,
                         [this, uiSpin, textSpin, sceneRowLock, sceneRowsSpin, autoApply, apply, &dialog, status]() {
                             BeginRestartEndToEndTest(uiSpin, textSpin, sceneRowLock, sceneRowsSpin,
                                                      autoApply, apply, &dialog, status);
                         });
        QObject::connect(close, &QPushButton::clicked, &dialog, &QDialog::accept);
'@ @'
        QObject::connect(restartTest, &QPushButton::clicked, &dialog,
                         [this, uiSpin, textSpin, proportional, safeTiny, sceneRowLock, sceneRowsSpin,
                          autoApply, apply, &dialog, status]() {
                             BeginRestartEndToEndTest(uiSpin, textSpin, proportional, safeTiny,
                                                      sceneRowLock, sceneRowsSpin, autoApply, apply,
                                                      &dialog, status);
                         });
        QObject::connect(completeTest, &QPushButton::clicked, &dialog,
                         [this, uiSpin, textSpin, matchButton, proportional, safeTiny, autoApply,
                          sceneRowLock, sceneRowsSpin, debugLogging, apply, restore, &dialog, status]() {
                             BeginCompleteUserActionTest(uiSpin, textSpin, matchButton,
                                                         proportional, safeTiny, autoApply,
                                                         sceneRowLock, sceneRowsSpin, debugLogging,
                                                         apply, restore, &dialog, status);
                         });
        QObject::connect(close, &QPushButton::clicked, &dialog, &QDialog::accept);
'@ 'connect complete test and expanded restart test'

# Preserve the complete-test label across the actual process restart and use a
# more accurate final result title/headline.
Replace-Required @'
            "debug/restartTestExpectedManualHeight"
'@ @'
            "debug/restartTestExpectedManualHeight", "debug/completeUserActionTestActive"
'@ 'clear complete test marker with restart keys'

Replace-Required @'
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
'@ @'
            const bool completeMode = settings_->value(QStringLiteral("debug/completeUserActionTestActive"), false).toBool();
            const QString headline = fail == 0
                ? (completeMode ? QStringLiteral("COMPLETE USER-ACTION TEST PASSED")
                                : QStringLiteral("REAL RESTART TEST PASSED"))
                : (completeMode ? QStringLiteral("COMPLETE USER-ACTION TEST FOUND ISSUES")
                                : QStringLiteral("REAL RESTART TEST FOUND ISSUES"));
            const QString summary = QStringLiteral(
                "%1\n\nPassed: %2   Failed: %3\n\n%4\n\nYour original OBS UI Scale settings and dock position were restored.")
                .arg(headline).arg(pass).arg(fail).arg(details);

            DebugWrite(QStringLiteral("========== %1 COMPLETE pass=%2 fail=%3 ==========")
                           .arg(completeMode ? QStringLiteral("COMPLETE USER-ACTION TEST")
                                             : QStringLiteral("REAL RESTART TEST"))
                           .arg(pass).arg(fail));
            ClearRestartTestKeys();
            QMessageBox::information(static_cast<QMainWindow *>(obs_frontend_get_main_window()),
                                     completeMode ? QStringLiteral("OBS UI Scale Complete User-Action Test")
                                                  : QStringLiteral("OBS UI Scale Real Restart Test"), summary);
'@ 'complete test final result branding'

# New state used only for the real-drag/scene action test and pending preflight
# results. Counters do not affect normal plugin behavior.
Replace-Required @'
    int pendingCalibrationSceneDockHeight_ = -1;
'@ @'
    int pendingCalibrationSceneDockHeight_ = -1;
    int manualResizeSerial_ = 0;
    int lastImmediateManualSceneDockHeight_ = -1;
    int completeSceneChangeCounter_ = 0;
    int completePreviewSceneChangeCounter_ = 0;
    QList<CompleteCheckResult> completePreflightResults_;
'@ 'complete user-action test members'

# Self-identifying DEBUG UI/log text. v3.14 removed DEBUG branding; v3.15 is a
# validation build until this new race fix and complete test pass on the machine.
$s = $s.Replace('OBS UI Scale v3.14 LOG', 'OBS UI Scale v3.15 DEBUG LOG')
$s = $s.Replace('OBS UI Scale v3.14', 'OBS UI Scale v3.15 DEBUG')
$s = $s.Replace('v3.14', 'v3.15 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.14.0', '3.15.0')
$iss = $iss.Replace('OBS-UI-Scale-Setup-3.15.0', 'OBS-UI-Scale-Debug-Setup-3.15.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.15 DEBUG immediate manual persistence + complete user-action test.'
