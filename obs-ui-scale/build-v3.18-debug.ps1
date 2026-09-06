$ErrorActionPreference = 'Stop'

# v3.18 DEBUG starts from v3.16.1 (the 29/29 build) and fixes the newly exposed
# reverse-direction race: DOWN -> Scene could still restore an older/taller row.
# It also replaces the one-direction manual test with a state/action matrix that
# exercises the meaningful orderings of manual drag, Scene changes, Apply,
# repeated Scene changes, and a real process restart in both directions.
& ./build-v3.16.1-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.18 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

function Replace-Block([string]$startMarker, [string]$endMarker, [string]$newBlock, [string]$label) {
    $start = $script:s.IndexOf($startMarker)
    if ($start -lt 0) { throw "v3.18 could not locate start of $label" }
    $end = $script:s.IndexOf($endMarker, $start)
    if ($end -lt 0) { throw "v3.18 could not locate end of $label" }
    $script:s = $script:s.Substring(0, $start) + $newBlock.Replace("`r`n", "`n") + $script:s.Substring($end)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.16.1-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.18.0-debug";' 'plugin version'

# Extra state: each Scene-change guard gets one immutable pre-Scene height target.
# If a real drag occurs while a previous Scene guard is still settling, the drag
# cancels that guard and becomes authoritative immediately.
Replace-Required @'
    int manualResizeSerial_ = 0;
    int lastImmediateManualSceneDockHeight_ = -1;
'@ @'
    int manualResizeSerial_ = 0;
    int sceneGuardTargetHeight_ = -1;
    int lastSceneGuardManualSerial_ = 0;
    QPushButton *restartTestApplyButton_ = nullptr;
    int lastImmediateManualSceneDockHeight_ = -1;
'@ 'scene guard target and matrix Apply pointer members'

# A real separator drag must be allowed to supersede a still-running Scene guard.
# The old !sceneDockGuardActive_ condition meant Scene -> drag could be ignored for
# up to the full guard settle window.
Replace-Required @'
        if (event && event->type() == QEvent::Resize && !sceneDockGuardActive_ &&
            !restoringDockTargets_ && !suppressManualDockCapture_ &&
'@ @'
        if (event && event->type() == QEvent::Resize &&
            !restoringDockTargets_ && !suppressManualDockCapture_ &&
'@ 'real drag can override active scene guard'

Replace-Required @'
                if (dock->property(PROP_DOCK_STABLE_H).isValid()) {
                    // This Resize is already proven to be a real left-mouse drag
'@ @'
                if (dock->property(PROP_DOCK_STABLE_H).isValid()) {
                    // A genuine drag always wins over an older Scene repair.
                    if (sceneDockGuardActive_) {
                        ++sceneDockGuardGeneration_;
                        sceneDockGuardActive_ = false;
                        sceneGuardTargetHeight_ = -1;
                        DebugWrite(QStringLiteral("MANUAL DRAG CANCELLED ACTIVE SCENE GUARD"));
                    }
                    // This Resize is already proven to be a real left-mouse drag
'@ 'manual drag cancels active scene guard'

# Scene changes preserve exactly the live row height that existed before OBS had
# a chance to relayout it. On the first Scene event of a guard window, snapshot
# that visible height. If a genuine drag occurred since the previous Scene guard,
# this pre-Scene live height also finalizes the manual save, catching the final
# downward/floor resize even if Qt delivered that last Resize after mouse release.
$sceneGuard = @'
    void RestoreAuthoritativeSceneDockTarget()
    {
        if (restoringDockTargets_ || !proportionalMode_ || currentUiPercent_ >= 99.999)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock || !sceneDock->isVisible() || sceneDock->isFloating())
            return;
        if (mainWindow->dockWidgetArea(sceneDock) != Qt::BottomDockWidgetArea)
            return;

        const int floorHeight = (sceneRowLockEnabled_ && lockedSceneDockHeight_ > 0)
                                    ? qMax(1, lockedSceneDockHeight_) : 1;

        int targetHeight = -1;
        if (sceneDockGuardActive_ && sceneGuardTargetHeight_ > 0)
            targetHeight = qMax(floorHeight, sceneGuardTargetHeight_);
        else if (savedManualSceneDockHeight_ > 0)
            targetHeight = qMax(floorHeight, savedManualSceneDockHeight_);
        else {
            RestoreStableDockTargets();
            return;
        }

        QStackedWidget *mixer = StackedMixerArea();
        QDockWidget *mixerDock = AudioMixerDock();
        if (mixerDock)
            mixerDock->setMinimumHeight(0);

        if (mixer && lockedMixerHeight_ > 0) {
            const int extraRowHeight = qMax(0, targetHeight - floorHeight);
            const int expectedMixerHeight = qMax(1, lockedMixerHeight_ + extraRowHeight);
            mixer->setMinimumHeight(lockedMixerHeight_);
            mixer->setMaximumHeight(expectedMixerHeight);
            if (mixer->height() > expectedMixerHeight)
                mixer->resize(mixer->width(), expectedMixerHeight);
            mixer->updateGeometry();
            if (mixer->parentWidget() && mixer->parentWidget()->layout()) {
                mixer->parentWidget()->layout()->invalidate();
                mixer->parentWidget()->layout()->activate();
            }
        }

        ReassertSceneRowLock();
        restoringDockTargets_ = true;
        mainWindow->resizeDocks({sceneDock}, {targetHeight}, Qt::Vertical);
        restoringDockTargets_ = false;
        ReassertSceneRowLock();

        if (qAbs(sceneDock->height() - targetHeight) > 1) {
            restoringDockTargets_ = true;
            mainWindow->resizeDocks({sceneDock}, {targetHeight}, Qt::Vertical);
            restoringDockTargets_ = false;
            ReassertSceneRowLock();
        }

        if (qAbs(sceneDock->height() - targetHeight) <= 2)
            CaptureStableDockTargets();

        DebugWrite(QStringLiteral(
            "SCENE IMMUTABLE TARGET RESTORE target=%1 live=%2 savedManual=%3 floor=%4 guardTarget=%5")
                       .arg(targetHeight)
                       .arg(sceneDock->height())
                       .arg(savedManualSceneDockHeight_)
                       .arg(floorHeight)
                       .arg(sceneGuardTargetHeight_));
    }

    void ArmSceneDockGuard()
    {
        if (!proportionalMode_ || currentUiPercent_ >= 99.999)
            return;

        // Capture the pre-Scene visible position once. Cascaded normal/preview
        // Scene events inside the same settle window may extend the guard, but
        // they cannot replace this original target with an OBS-relayout height.
        if (!sceneDockGuardActive_) {
            QDockWidget *sceneDock = ScenesDock();
            const int floorHeight = (sceneRowLockEnabled_ && lockedSceneDockHeight_ > 0)
                                        ? qMax(1, lockedSceneDockHeight_) : 1;
            if (sceneDock && sceneDock->height() > 0)
                sceneGuardTargetHeight_ = qMax(floorHeight, sceneDock->height());
            else
                sceneGuardTargetHeight_ = savedManualSceneDockHeight_ > 0
                                            ? qMax(floorHeight, savedManualSceneDockHeight_) : -1;

            // A real drag happened since the previous Scene guard. Finalize the
            // exact visible pre-Scene position as the manual save. This is the
            // key DOWN -> Scene fix and is direction-independent.
            if (sceneGuardTargetHeight_ > 0 && manualResizeSerial_ > lastSceneGuardManualSerial_) {
                savedManualSceneDockHeight_ = sceneGuardTargetHeight_;
                lastImmediateManualSceneDockHeight_ = sceneGuardTargetHeight_;
                if (settings_) {
                    settings_->setValue(QStringLiteral("ui/manualSceneDockHeight"),
                                        savedManualSceneDockHeight_);
                    settings_->sync();
                }
                DebugWrite(QStringLiteral(
                    "SCENE PRE-EVENT FINALIZED MANUAL HEIGHT height=%1 dragSerial=%2")
                               .arg(savedManualSceneDockHeight_).arg(manualResizeSerial_));
            }
            lastSceneGuardManualSerial_ = manualResizeSerial_;
        }

        ++manualDockCaptureGeneration_;
        sceneDockGuardActive_ = true;
        const int generation = ++sceneDockGuardGeneration_;

        RestoreMixerMinimumTarget();
        ReassertSceneRowLock();
        RestoreAuthoritativeSceneDockTarget();

        const int delays[] = {20, 60, 120, 220, 350, 550, 800, 1100, 1350};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, generation]() {
                if (generation != sceneDockGuardGeneration_ || !sceneDockGuardActive_)
                    return;
                RestoreMixerMinimumTarget();
                ReassertSceneRowLock();
                RestoreAuthoritativeSceneDockTarget();
            });
        }

        QTimer::singleShot(1500, this, [this, generation]() {
            if (generation == sceneDockGuardGeneration_) {
                RestoreMixerMinimumTarget();
                ReassertSceneRowLock();
                RestoreAuthoritativeSceneDockTarget();
                sceneDockGuardActive_ = false;
                sceneGuardTargetHeight_ = -1;
            }
        });
    }

'@
Replace-Block '    void RestoreAuthoritativeSceneDockTarget()' '    bool IsManualBottomRowResizeGesture() const' $sceneGuard 'direction-independent scene guard'

# Keep a pointer to the ACTUAL Apply button used by the real restart/matrix test.
Replace-Required @'
        if (!settings_ || !uiSpin || !textSpin || !proportional || !safeTiny ||
            !sceneRowLock || !sceneRowsSpin || !autoApply || !apply || !settingsDialog)
            return;

        if (settings_->value(QStringLiteral("debug/restartTestActive"), false).toBool()) {
'@ @'
        if (!settings_ || !uiSpin || !textSpin || !proportional || !safeTiny ||
            !sceneRowLock || !sceneRowsSpin || !autoApply || !apply || !settingsDialog)
            return;

        restartTestApplyButton_ = apply;

        if (settings_->value(QStringLiteral("debug/restartTestActive"), false).toBool()) {
'@ 'remember actual Apply button for matrix'

# Replace the 3-step one-direction manual test with a combination matrix. The
# existing Complete User-Action preflight still covers every normal control and
# Restore/Match/checkbox action before this matrix begins.
$manualMatrix = @'
    void ShowManualRestartTestPanel()
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock || !settings_ || !restartTestApplyButton_) {
            RestartTestRecord(false, QStringLiteral("Manual action-matrix setup"),
                              QStringLiteral("Scenes dock/settings/Apply button were unavailable."));
            return;
        }

        const int floorAtStart = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
        auto stage = std::make_shared<int>(0);
        auto dragBase = std::make_shared<int>(manualResizeSerial_);
        auto sceneBase = std::make_shared<int>(completeSceneChangeCounter_ + completePreviewSceneChangeCounter_);
        auto expected = std::make_shared<int>(sceneDock->height());

        auto *panel = new QDialog(mainWindow);
        panel->setAttribute(Qt::WA_DeleteOnClose);
        panel->setWindowTitle(QStringLiteral("OBS UI Scale v3.18 DEBUG - Full Drag / Scene / Apply Matrix"));
        panel->setWindowModality(Qt::NonModal);
        panel->setWindowFlag(Qt::Tool, true);
        panel->setWindowFlag(Qt::WindowStaysOnTopHint, true);
        panel->resize(690, 340);

        auto *layout = new QVBoxLayout(panel);
        auto *instructions = new QLabel(panel);
        instructions->setWordWrap(true);
        layout->addWidget(instructions);
        auto *status = new QLabel(QStringLiteral("Waiting for matrix step 1..."), panel);
        status->setWordWrap(true);
        layout->addWidget(status);
        auto *buttons = new QDialogButtonBox(panel);
        auto *continueButton = buttons->addButton(QStringLiteral("Continue"), QDialogButtonBox::AcceptRole);
        layout->addWidget(buttons);

        instructions->setText(QStringLiteral(
            "Matrix 1/12 - DOWN -> IMMEDIATE SCENE\n\n"
            "Drag the bottom-row separator DOWN to the configured minimum, RELEASE it, then IMMEDIATELY click a different Scene. Then click Continue.\n\n"
            "If already at minimum, drag up first and then down. Minimum=%1 px.").arg(floorAtStart));

        QObject::connect(continueButton, &QPushButton::clicked, panel,
                         [this, panel, instructions, status, continueButton, stage,
                          dragBase, sceneBase, expected]() {
            QDockWidget *dock = ScenesDock();
            if (!dock || !settings_) {
                status->setText(QStringLiteral("Scenes dock disappeared. Restart the test."));
                return;
            }

            const int floor = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
            const int live = dock->height();
            const int eventsNow = completeSceneChangeCounter_ + completePreviewSceneChangeCounter_;
            const int latest = lastImmediateManualSceneDockHeight_;
            const bool stableLatest = latest > 0 && qAbs(live - latest) <= 3 &&
                                      qAbs(savedManualSceneDockHeight_ - latest) <= 3;

            if (*stage == 0) {
                if (manualResizeSerial_ <= *dragBase || qAbs(latest - floor) > 3 ||
                    eventsNow <= *sceneBase || !stableLatest) {
                    status->setText(QStringLiteral("DOWN -> Scene not passed yet. Live=%1 latest=%2 saved=%3 floor=%4 sceneEvents=%5 dragSerial=%6.")
                                    .arg(live).arg(latest).arg(savedManualSceneDockHeight_).arg(floor)
                                    .arg(eventsNow - *sceneBase).arg(manualResizeSerial_));
                    return;
                }
                *expected = latest;
                RestartTestRecord(true, QStringLiteral("Matrix DOWN -> immediate Scene"),
                                  QStringLiteral("Downward drag reached %1 px and Scene click kept live/saved at %2/%3 px.")
                                      .arg(latest).arg(live).arg(savedManualSceneDockHeight_));
                *stage = 1; *dragBase = manualResizeSerial_; *sceneBase = eventsNow;
                instructions->setText(QStringLiteral(
                    "Matrix 2/12 - UP -> IMMEDIATE SCENE\n\n"
                    "Drag the separator UP so the row is clearly taller, RELEASE it, immediately click a different Scene, then Continue."));
                status->setText(QStringLiteral("Waiting for UP -> Scene..."));
                return;
            }

            if (*stage == 1) {
                if (manualResizeSerial_ <= *dragBase || latest <= floor + 3 ||
                    eventsNow <= *sceneBase || !stableLatest) {
                    status->setText(QStringLiteral("UP -> Scene not passed yet. Live=%1 latest=%2 saved=%3 sceneEvents=%4.")
                                    .arg(live).arg(latest).arg(savedManualSceneDockHeight_).arg(eventsNow - *sceneBase));
                    return;
                }
                *expected = latest;
                RestartTestRecord(true, QStringLiteral("Matrix UP -> immediate Scene"),
                                  QStringLiteral("Upward drag saved %1 px and immediate Scene kept that exact position.").arg(latest));
                *stage = 2; *dragBase = manualResizeSerial_; *sceneBase = eventsNow;
                instructions->setText(QStringLiteral(
                    "Matrix 3/12 - DOWN -> APPLY\n\n"
                    "Drag DOWN to the minimum and release. Do NOT click a Scene yet. Click Continue; the test will click the real Apply button and verify the height."));
                status->setText(QStringLiteral("Waiting for DOWN drag before Apply..."));
                return;
            }

            if (*stage == 2) {
                if (manualResizeSerial_ <= *dragBase || qAbs(latest - floor) > 3 || !stableLatest) {
                    status->setText(QStringLiteral("Need a real DOWN drag to minimum first. Live=%1 latest=%2 floor=%3.")
                                    .arg(live).arg(latest).arg(floor));
                    return;
                }
                *expected = latest;
                continueButton->setEnabled(false);
                status->setText(QStringLiteral("Clicking the ACTUAL Apply button and waiting for full settle..."));
                restartTestApplyButton_->click();
                QTimer::singleShot(4300, this, [this, instructions, status, continueButton, stage, sceneBase, expected]() {
                    QDockWidget *d = ScenesDock();
                    const int actual = d ? d->height() : -1;
                    const bool ok = d && qAbs(actual - *expected) <= 3 && qAbs(savedManualSceneDockHeight_ - *expected) <= 3;
                    RestartTestRecord(ok, QStringLiteral("Matrix DOWN -> Apply"),
                                      QStringLiteral("Expected=%1 px; after real Apply live=%2 saved=%3.")
                                          .arg(*expected).arg(actual).arg(savedManualSceneDockHeight_));
                    if (!ok) { status->setText(QStringLiteral("DOWN -> Apply failed. Stop and send the log.")); return; }
                    *stage = 3;
                    *sceneBase = completeSceneChangeCounter_ + completePreviewSceneChangeCounter_;
                    instructions->setText(QStringLiteral(
                        "Matrix 4/12 - DOWN -> APPLY -> SCENE\n\n"
                        "Now click a different Scene, then Continue. Do not drag the separator."));
                    status->setText(QStringLiteral("Apply passed. Waiting for the Scene click..."));
                    continueButton->setEnabled(true);
                });
                return;
            }

            if (*stage == 3) {
                if (eventsNow <= *sceneBase || qAbs(live - *expected) > 3 || qAbs(savedManualSceneDockHeight_ - *expected) > 3) {
                    status->setText(QStringLiteral("Need one Scene click with the DOWN+Apply height unchanged. Live=%1 expected=%2.")
                                    .arg(live).arg(*expected));
                    return;
                }
                RestartTestRecord(true, QStringLiteral("Matrix DOWN -> Apply -> Scene"),
                                  QStringLiteral("Scene change after Apply kept %1 px.").arg(*expected));
                *stage = 4; *dragBase = manualResizeSerial_; *sceneBase = eventsNow;
                instructions->setText(QStringLiteral(
                    "Matrix 5/12 - UP -> APPLY\n\n"
                    "Drag UP, release, then click Continue. The test will click the real Apply button."));
                status->setText(QStringLiteral("Waiting for UP drag before Apply..."));
                return;
            }

            if (*stage == 4) {
                if (manualResizeSerial_ <= *dragBase || latest <= floor + 3 || !stableLatest) {
                    status->setText(QStringLiteral("Need a real UP drag first. Live=%1 latest=%2.").arg(live).arg(latest));
                    return;
                }
                *expected = latest;
                continueButton->setEnabled(false);
                status->setText(QStringLiteral("Clicking the ACTUAL Apply button and waiting..."));
                restartTestApplyButton_->click();
                QTimer::singleShot(4300, this, [this, instructions, status, continueButton, stage, sceneBase, expected]() {
                    QDockWidget *d = ScenesDock();
                    const int actual = d ? d->height() : -1;
                    const bool ok = d && qAbs(actual - *expected) <= 3 && qAbs(savedManualSceneDockHeight_ - *expected) <= 3;
                    RestartTestRecord(ok, QStringLiteral("Matrix UP -> Apply"),
                                      QStringLiteral("Expected=%1 px; after real Apply live=%2 saved=%3.")
                                          .arg(*expected).arg(actual).arg(savedManualSceneDockHeight_));
                    if (!ok) { status->setText(QStringLiteral("UP -> Apply failed. Stop and send the log.")); return; }
                    *stage = 5;
                    *sceneBase = completeSceneChangeCounter_ + completePreviewSceneChangeCounter_;
                    instructions->setText(QStringLiteral(
                        "Matrix 6/12 - UP -> APPLY -> SCENE\n\n"
                        "Click a different Scene, then Continue. Do not drag."));
                    status->setText(QStringLiteral("Apply passed. Waiting for Scene click..."));
                    continueButton->setEnabled(true);
                });
                return;
            }

            if (*stage == 5) {
                if (eventsNow <= *sceneBase || qAbs(live - *expected) > 3 || qAbs(savedManualSceneDockHeight_ - *expected) > 3) {
                    status->setText(QStringLiteral("Need one Scene click with the UP+Apply height unchanged."));
                    return;
                }
                RestartTestRecord(true, QStringLiteral("Matrix UP -> Apply -> Scene"),
                                  QStringLiteral("Scene change after Apply kept %1 px.").arg(*expected));
                *stage = 6; *dragBase = manualResizeSerial_; *sceneBase = eventsNow;
                instructions->setText(QStringLiteral(
                    "Matrix 7/12 - SCENE -> DOWN -> SCENE\n\n"
                    "1. Click a different Scene. 2. While that Scene guard may still be settling, drag DOWN to minimum and release. 3. Immediately click another Scene. 4. Continue."));
                status->setText(QStringLiteral("Waiting for Scene -> DOWN -> Scene..."));
                return;
            }

            if (*stage == 6) {
                if (eventsNow - *sceneBase < 2 || manualResizeSerial_ <= *dragBase ||
                    qAbs(latest - floor) > 3 || !stableLatest) {
                    status->setText(QStringLiteral("Scene -> DOWN -> Scene not passed. Events=%1 live=%2 latest=%3 saved=%4.")
                                    .arg(eventsNow - *sceneBase).arg(live).arg(latest).arg(savedManualSceneDockHeight_));
                    return;
                }
                *expected = latest;
                RestartTestRecord(true, QStringLiteral("Matrix Scene -> DOWN -> Scene"),
                                  QStringLiteral("A real drag overrode the active Scene guard and the next Scene kept %1 px.").arg(latest));
                *stage = 7; *dragBase = manualResizeSerial_; *sceneBase = eventsNow;
                instructions->setText(QStringLiteral(
                    "Matrix 8/12 - SCENE -> UP -> SCENE\n\n"
                    "1. Click a different Scene. 2. Immediately drag UP and release. 3. Immediately click another Scene. 4. Continue."));
                status->setText(QStringLiteral("Waiting for Scene -> UP -> Scene..."));
                return;
            }

            if (*stage == 7) {
                if (eventsNow - *sceneBase < 2 || manualResizeSerial_ <= *dragBase ||
                    latest <= floor + 3 || !stableLatest) {
                    status->setText(QStringLiteral("Scene -> UP -> Scene not passed. Events=%1 live=%2 latest=%3.")
                                    .arg(eventsNow - *sceneBase).arg(live).arg(latest));
                    return;
                }
                *expected = latest;
                RestartTestRecord(true, QStringLiteral("Matrix Scene -> UP -> Scene"),
                                  QStringLiteral("Upward drag overrode the active Scene guard and next Scene kept %1 px.").arg(latest));
                *stage = 8; *dragBase = manualResizeSerial_; *sceneBase = eventsNow;
                instructions->setText(QStringLiteral(
                    "Matrix 9/12 - DOWN -> REPEATED SCENES\n\n"
                    "Drag DOWN to minimum, release, then click at least THREE different Scenes. Then Continue."));
                status->setText(QStringLiteral("Waiting for DOWN + repeated Scenes..."));
                return;
            }

            if (*stage == 8) {
                if (manualResizeSerial_ <= *dragBase || qAbs(latest - floor) > 3 ||
                    eventsNow - *sceneBase < 3 || !stableLatest) {
                    status->setText(QStringLiteral("Need DOWN plus 3 Scene events. Events=%1 live=%2 latest=%3.")
                                    .arg(eventsNow - *sceneBase).arg(live).arg(latest));
                    return;
                }
                *expected = latest;
                RestartTestRecord(true, QStringLiteral("Matrix DOWN -> repeated Scenes"),
                                  QStringLiteral("Three or more Scene changes kept minimum manual height %1 px.").arg(latest));
                *stage = 9; *dragBase = manualResizeSerial_; *sceneBase = eventsNow;
                instructions->setText(QStringLiteral(
                    "Matrix 10/12 - UP -> REPEATED SCENES\n\n"
                    "Drag UP, release, then click at least THREE different Scenes. Then Continue."));
                status->setText(QStringLiteral("Waiting for UP + repeated Scenes..."));
                return;
            }

            if (*stage == 9) {
                if (manualResizeSerial_ <= *dragBase || latest <= floor + 3 ||
                    eventsNow - *sceneBase < 3 || !stableLatest) {
                    status->setText(QStringLiteral("Need UP plus 3 Scene events. Events=%1 live=%2 latest=%3.")
                                    .arg(eventsNow - *sceneBase).arg(live).arg(latest));
                    return;
                }
                *expected = latest;
                RestartTestRecord(true, QStringLiteral("Matrix UP -> repeated Scenes"),
                                  QStringLiteral("Three or more Scene changes kept taller manual height %1 px.").arg(latest));
                *stage = 10; *dragBase = manualResizeSerial_; *sceneBase = eventsNow;
                instructions->setText(QStringLiteral(
                    "Matrix 11/12 - DOWN -> SCENE -> APPLY\n\n"
                    "Drag DOWN to minimum, release, immediately click a different Scene, then Continue. The test will click the real Apply button afterward."));
                status->setText(QStringLiteral("Waiting for DOWN -> Scene before Apply..."));
                return;
            }

            if (*stage == 10) {
                if (manualResizeSerial_ <= *dragBase || qAbs(latest - floor) > 3 ||
                    eventsNow <= *sceneBase || !stableLatest) {
                    status->setText(QStringLiteral("DOWN -> Scene not ready for Apply. Live=%1 latest=%2 events=%3.")
                                    .arg(live).arg(latest).arg(eventsNow - *sceneBase));
                    return;
                }
                *expected = latest;
                continueButton->setEnabled(false);
                status->setText(QStringLiteral("Scene stayed down. Clicking real Apply and waiting..."));
                restartTestApplyButton_->click();
                QTimer::singleShot(4300, this, [this, instructions, status, continueButton, stage, dragBase, sceneBase, expected]() {
                    QDockWidget *d = ScenesDock();
                    const int actual = d ? d->height() : -1;
                    const bool ok = d && qAbs(actual - *expected) <= 3 && qAbs(savedManualSceneDockHeight_ - *expected) <= 3;
                    RestartTestRecord(ok, QStringLiteral("Matrix DOWN -> Scene -> Apply"),
                                      QStringLiteral("After Scene then real Apply, live=%1 saved=%2 expected=%3.")
                                          .arg(actual).arg(savedManualSceneDockHeight_).arg(*expected));
                    if (!ok) { status->setText(QStringLiteral("DOWN -> Scene -> Apply failed. Send the log.")); return; }
                    *stage = 11;
                    *dragBase = manualResizeSerial_;
                    *sceneBase = completeSceneChangeCounter_ + completePreviewSceneChangeCounter_;
                    instructions->setText(QStringLiteral(
                        "Matrix 12/12 - UP -> SCENE -> APPLY\n\n"
                        "Drag UP, release, immediately click a different Scene, then Continue. The test will click real Apply and, if it stays exact, perform the real OBS restart."));
                    status->setText(QStringLiteral("Waiting for final UP -> Scene -> Apply..."));
                    continueButton->setEnabled(true);
                });
                return;
            }

            if (*stage == 11) {
                if (manualResizeSerial_ <= *dragBase || latest <= floor + 3 ||
                    eventsNow <= *sceneBase || !stableLatest) {
                    status->setText(QStringLiteral("UP -> Scene not ready for final Apply. Live=%1 latest=%2 events=%3.")
                                    .arg(live).arg(latest).arg(eventsNow - *sceneBase));
                    return;
                }
                *expected = latest;
                continueButton->setEnabled(false);
                status->setText(QStringLiteral("Clicking final real Apply and waiting before restart..."));
                restartTestApplyButton_->click();
                QTimer::singleShot(4300, this, [this, panel, status, expected]() {
                    QDockWidget *d = ScenesDock();
                    const int actual = d ? d->height() : -1;
                    const bool ok = d && qAbs(actual - *expected) <= 3 && qAbs(savedManualSceneDockHeight_ - *expected) <= 3;
                    RestartTestRecord(ok, QStringLiteral("Matrix UP -> Scene -> Apply"),
                                      QStringLiteral("After Scene then real Apply, live=%1 saved=%2 expected=%3.")
                                          .arg(actual).arg(savedManualSceneDockHeight_).arg(*expected));
                    if (!ok) { status->setText(QStringLiteral("UP -> Scene -> Apply failed. Send the log.")); return; }
                    if (obs_frontend_streaming_active() || obs_frontend_recording_active()) {
                        status->setText(QStringLiteral("Matrix passed, but stop streaming/recording before the restart."));
                        return;
                    }
                    settings_->setValue(QStringLiteral("debug/restartTestExpectedManualHeight"), *expected);
                    settings_->setValue(QStringLiteral("debug/restartTestPhase"), 2);
                    settings_->setValue(QStringLiteral("debug/restartTestActive"), true);
                    settings_->sync();
                    if (!LaunchObsRestartHelper()) {
                        RestartTestRecord(false, QStringLiteral("Automatic OBS relaunch"),
                                          QStringLiteral("Could not start delayed OBS relaunch helper."));
                        status->setText(QStringLiteral("Could not start automatic relaunch. OBS was not closed."));
                        return;
                    }
                    RestartTestRecord(true, QStringLiteral("Automatic OBS relaunch"),
                                      QStringLiteral("Full pre-restart action matrix passed; closing OBS for real restart."));
                    panel->close();
                    QTimer::singleShot(350, qApp, []() { qApp->quit(); });
                });
                return;
            }
        });

        panel->show();
        panel->raise();
        panel->activateWindow();
    }

'@
Replace-Block '    void ShowManualRestartTestPanel()' '    void BeginRestartEndToEndTest(' $manualMatrix 'pre-restart drag/scene/apply matrix'

# After the real process restart, do not stop at passive persistence checks.
# Exercise Scene stability again, then real DOWN -> Scene and UP -> Scene after
# restart before the existing post-restart Apply/restoration path runs.
$postRestartCode = @'
    void FinishPostRestartApplyAndRestore(int expectedManual)
    {
        QDockWidget *sceneDock = ScenesDock();
        if (!sceneDock) {
            RestartTestRecord(false, QStringLiteral("Post-restart Apply"),
                              QStringLiteral("Scenes dock unavailable after restart."));
            RestoreAfterRestartTest();
            return;
        }

        settings_->setValue(QStringLiteral("debug/restartTestExpectedManualHeight"), expectedManual);
        settings_->sync();
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

    void ShowPostRestartCombinationPanel(int startupExpected)
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock) {
            RestartTestRecord(false, QStringLiteral("Post-restart matrix setup"),
                              QStringLiteral("Scenes dock unavailable."));
            FinishPostRestartApplyAndRestore(startupExpected);
            return;
        }

        auto stage = std::make_shared<int>(0);
        auto dragBase = std::make_shared<int>(manualResizeSerial_);
        auto sceneBase = std::make_shared<int>(completeSceneChangeCounter_ + completePreviewSceneChangeCounter_);
        auto expected = std::make_shared<int>(startupExpected);

        auto *panel = new QDialog(mainWindow);
        panel->setAttribute(Qt::WA_DeleteOnClose);
        panel->setWindowTitle(QStringLiteral("OBS UI Scale v3.18 DEBUG - Post-Restart Matrix"));
        panel->setWindowModality(Qt::NonModal);
        panel->setWindowFlag(Qt::Tool, true);
        panel->setWindowFlag(Qt::WindowStaysOnTopHint, true);
        panel->resize(650, 285);
        auto *layout = new QVBoxLayout(panel);
        auto *instructions = new QLabel(QStringLiteral(
            "Post-restart 1/3 - RESTART -> REPEATED SCENES\n\n"
            "Click at least TWO different Scenes without touching the separator, then Continue. The restarted manual height must not move."), panel);
        instructions->setWordWrap(true);
        layout->addWidget(instructions);
        auto *status = new QLabel(QStringLiteral("Waiting for two Scene changes after restart..."), panel);
        status->setWordWrap(true);
        layout->addWidget(status);
        auto *buttons = new QDialogButtonBox(panel);
        auto *continueButton = buttons->addButton(QStringLiteral("Continue"), QDialogButtonBox::AcceptRole);
        layout->addWidget(buttons);

        QObject::connect(continueButton, &QPushButton::clicked, panel,
                         [this, panel, instructions, status, stage, dragBase, sceneBase, expected]() {
            QDockWidget *dock = ScenesDock();
            if (!dock) return;
            const int floor = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
            const int eventsNow = completeSceneChangeCounter_ + completePreviewSceneChangeCounter_;
            const int latest = lastImmediateManualSceneDockHeight_;
            const int live = dock->height();

            if (*stage == 0) {
                const bool stable = *expected > 0 && qAbs(live - *expected) <= 3 &&
                                    qAbs(savedManualSceneDockHeight_ - *expected) <= 3;
                if (eventsNow - *sceneBase < 2 || !stable) {
                    status->setText(QStringLiteral("Need two Scene changes with restarted height unchanged. Events=%1 live=%2 expected=%3 saved=%4.")
                                    .arg(eventsNow - *sceneBase).arg(live).arg(*expected).arg(savedManualSceneDockHeight_));
                    return;
                }
                RestartTestRecord(true, QStringLiteral("Post-restart repeated Scene stability"),
                                  QStringLiteral("Repeated Scenes kept restarted manual height %1 px.").arg(*expected));
                *stage = 1; *dragBase = manualResizeSerial_; *sceneBase = eventsNow;
                instructions->setText(QStringLiteral(
                    "Post-restart 2/3 - DOWN -> IMMEDIATE SCENE\n\n"
                    "Drag DOWN to the row minimum, release, immediately click a different Scene, then Continue."));
                status->setText(QStringLiteral("Waiting for post-restart DOWN -> Scene..."));
                return;
            }

            if (*stage == 1) {
                const bool stable = latest > 0 && qAbs(latest - floor) <= 3 &&
                                    qAbs(live - latest) <= 3 && qAbs(savedManualSceneDockHeight_ - latest) <= 3;
                if (manualResizeSerial_ <= *dragBase || eventsNow <= *sceneBase || !stable) {
                    status->setText(QStringLiteral("Post-restart DOWN -> Scene not passed. Live=%1 latest=%2 saved=%3 events=%4.")
                                    .arg(live).arg(latest).arg(savedManualSceneDockHeight_).arg(eventsNow - *sceneBase));
                    return;
                }
                *expected = latest;
                RestartTestRecord(true, QStringLiteral("Post-restart DOWN -> immediate Scene"),
                                  QStringLiteral("Downward manual height %1 px survived Scene after real restart.").arg(latest));
                *stage = 2; *dragBase = manualResizeSerial_; *sceneBase = eventsNow;
                instructions->setText(QStringLiteral(
                    "Post-restart 3/3 - UP -> IMMEDIATE SCENE\n\n"
                    "Drag UP, release, immediately click a different Scene, then Continue. The test will then run the post-restart Apply check and restore all original settings."));
                status->setText(QStringLiteral("Waiting for post-restart UP -> Scene..."));
                return;
            }

            const bool stable = latest > floor + 3 && qAbs(live - latest) <= 3 &&
                                qAbs(savedManualSceneDockHeight_ - latest) <= 3;
            if (manualResizeSerial_ <= *dragBase || eventsNow <= *sceneBase || !stable) {
                status->setText(QStringLiteral("Post-restart UP -> Scene not passed. Live=%1 latest=%2 saved=%3 events=%4.")
                                .arg(live).arg(latest).arg(savedManualSceneDockHeight_).arg(eventsNow - *sceneBase));
                return;
            }
            *expected = latest;
            RestartTestRecord(true, QStringLiteral("Post-restart UP -> immediate Scene"),
                              QStringLiteral("Upward manual height %1 px survived Scene after real restart.").arg(latest));
            panel->close();
            FinishPostRestartApplyAndRestore(*expected);
        });

        panel->show();
        panel->raise();
        panel->activateWindow();
    }

'@
$continueMarker = '    void ContinueRestartTestAfterStartup()'
$continuePos = $s.IndexOf($continueMarker)
if ($continuePos -lt 0) { throw 'v3.18 could not locate ContinueRestartTestAfterStartup' }
$s = $s.Substring(0, $continuePos) + $postRestartCode.Replace("`r`n", "`n") + $s.Substring($continuePos)

$oldPostRestartTail = @'
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
'@
Replace-Required $oldPostRestartTail @'
        if (!sceneDock) {
            RestartTestRecord(false, QStringLiteral("Post-restart matrix"),
                              QStringLiteral("Scenes dock unavailable after restart."));
            RestoreAfterRestartTest();
            return;
        }

        ShowPostRestartCombinationPanel(expectedManual);
'@ 'continue real restart into post-restart combination matrix'

# Update Complete-test descriptions so this build is explicit about the matrix.
$s = $s.Replace('Run Complete User-Action Test', 'Run Complete Combination-Matrix Test')
$s = $s.Replace('Complete User-Action Test', 'Complete Combination-Matrix Test')
$s = $s.Replace('COMPLETE USER-ACTION TEST', 'COMPLETE COMBINATION-MATRIX TEST')
$s = $s.Replace('OBS UI Scale v3.16.1 DEBUG LOG', 'OBS UI Scale v3.18 DEBUG LOG')
$s = $s.Replace('OBS UI Scale v3.16.1 DEBUG', 'OBS UI Scale v3.18 DEBUG')
$s = $s.Replace('OBS UI Scale v3.16.1', 'OBS UI Scale v3.18 DEBUG')
$s = $s.Replace('v3.16.1 DEBUG', 'v3.18 DEBUG')
$s = $s.Replace('v3.16.1', 'v3.18')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.16.1', '3.18.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.18.0', 'OBS-UI-Scale-Debug-Setup-3.18.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.18 DEBUG direction-independent Scene preservation + full combination matrix.'
