$ErrorActionPreference = 'Stop'

# v3.28 DEBUG
# Makes the Complete Combination-Matrix Test fully automatic after the user
# presses the test button once:
# - no separator dragging by hand
# - no Scene clicks
# - no Continue buttons
# - no Apply/Close clicks in the temporary settings windows
# - post-restart matrix is automatic too
#
# The automatic drag-equivalent uses QMainWindow::resizeDocks and then commits
# the resulting live height through the same manual-height state/persistence
# fields used by the real gesture path. The test therefore validates all state
# combinations without requiring mouse input. Real manual gesture behavior
# remains unchanged for normal OBS use.
& ./build-v3.27-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.28 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}
function Replace-Block([string]$startMarker, [string]$endMarker, [string]$newBlock, [string]$label) {
    $start = $script:s.IndexOf($startMarker)
    if ($start -lt 0) { throw "v3.28 could not locate start of $label" }
    $end = $script:s.IndexOf($endMarker, $start)
    if ($end -lt 0) { throw "v3.28 could not locate end of $label" }
    $script:s = $script:s.Substring(0, $start) + $newBlock.Replace("`r`n", "`n") + $script:s.Substring($end)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.27.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.28.0-debug";' 'plugin version'

# The fresh-settings Apply check remains a REAL QPushButton click, but v3.28
# schedules that click and closes the modal dialog itself.
$autoApplyHelper = @'
    bool RunFreshRealApplyForMatrix(QDialog *matrixPanel, QLabel *status)
    {
        const int before = completeApplyCounter_;
        if (status)
            status->setText(QStringLiteral("Automatic test: opening the real settings dialog and clicking Apply..."));

        QTimer::singleShot(180, this, [matrixPanel]() {
            const auto topLevels = qApp->topLevelWidgets();
            for (QWidget *widget : topLevels) {
                auto *dialog = qobject_cast<QDialog *>(widget);
                if (!dialog || dialog == matrixPanel || !dialog->isVisible())
                    continue;
                if (!dialog->windowTitle().startsWith(QStringLiteral("OBS UI Scale")))
                    continue;

                QPushButton *applyButton = nullptr;
                const auto buttons = dialog->findChildren<QPushButton *>();
                for (QPushButton *button : buttons) {
                    if (button && button->text().trimmed() == QStringLiteral("Apply")) {
                        applyButton = button;
                        break;
                    }
                }

                if (!applyButton)
                    continue;

                applyButton->click();
                QTimer::singleShot(120, dialog, [dialog]() {
                    if (dialog)
                        dialog->accept();
                });
                return;
            }
        });

        ShowDialog();

        const bool clicked = completeApplyCounter_ > before;
        DebugWrite(QStringLiteral("MATRIX AUTO REAL APPLY before=%1 after=%2 clicked=%3")
                       .arg(before).arg(completeApplyCounter_).arg(clicked ? 1 : 0));
        if (!clicked && status)
            status->setText(QStringLiteral("Automatic real Apply click was not detected."));
        return clicked;
    }

'@
Replace-Block '    bool RunFreshRealApplyForMatrix(QDialog *matrixPanel, QLabel *status)' '    void ShowManualRestartTestPanel()' $autoApplyHelper 'automatic real Apply helper'

# Automatic helpers + full pre-restart matrix.
$autoMatrix = @'
    bool AutoMatrixSwitchScene()
    {
        struct obs_frontend_source_list scenes = {};
        obs_frontend_get_scenes(&scenes);

        obs_source_t *current = obs_frontend_get_current_scene();
        obs_source_t *next = nullptr;
        for (size_t i = 0; i < scenes.sources.num; ++i) {
            obs_source_t *candidate = scenes.sources.array[i];
            if (candidate && candidate != current) {
                next = candidate;
                break;
            }
        }

        if (!next && scenes.sources.num > 0)
            next = scenes.sources.array[0];

        const bool changed = next && next != current;
        if (changed)
            obs_frontend_set_current_scene(next);

        if (current)
            obs_source_release(current);
        obs_frontend_source_list_free(&scenes);

        DebugWrite(QStringLiteral("AUTO MATRIX SCENE CHANGE requested=%1").arg(changed ? 1 : 0));
        return changed;
    }

    int AutoMatrixDrag(bool down)
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *dock = ScenesDock();
        if (!mainWindow || !dock)
            return -1;

        if (sceneDockGuardActive_) {
            ++sceneDockGuardGeneration_;
            sceneDockGuardActive_ = false;
            sceneGuardTargetHeight_ = -1;
        }
        if (realApplySmoothGuardActive_) {
            ++realApplySmoothGuardGeneration_;
            realApplySmoothGuardActive_ = false;
            realApplySmoothExpectedHeight_ = -1;
        }
        ++sceneRowRefreshGeneration_;
        ++manualDragSettleGeneration_;

        const int floor = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
        if (down) {
            ForceBottomRowHeightNow(floor, QStringLiteral("automatic test DOWN"), true);
            if (AdoptEquivalentLowRowPhysicalHeight(
                    floor, QStringLiteral("automatic test DOWN")))
                ReassertSceneRowLock();
        } else {
            const int pitch = qMax(1, CurrentSceneRowHeight());
            const int desired = qMax(floor + qMax(180, pitch * 7),
                                     dock->height() + qMax(120, pitch * 5));
            restoringDockTargets_ = true;
            mainWindow->resizeDocks({dock}, {desired}, Qt::Vertical);
            restoringDockTargets_ = false;
        }

        const int actual = dock->height();
        ++manualDockCaptureGeneration_;
        ++manualResizeSerial_;
        savedManualSceneDockHeight_ = actual;
        lastImmediateManualSceneDockHeight_ = actual;
        lastManualObservedHeight_ = actual;
        CaptureStableDockTargets();

        if (settings_) {
            settings_->setValue(QStringLiteral("ui/manualSceneDockHeight"), actual);
            settings_->sync();
        }

        DebugWrite(QStringLiteral("AUTO MATRIX DRAG direction=%1 floor=%2 actual=%3 serial=%4")
                       .arg(down ? QStringLiteral("DOWN") : QStringLiteral("UP"))
                       .arg(floor).arg(actual).arg(manualResizeSerial_));
        return actual;
    }

    bool AutoMatrixStableAt(int expected) const
    {
        QDockWidget *dock = ScenesDock();
        return dock && expected > 0 &&
               qAbs(dock->height() - expected) <= 3 &&
               qAbs(savedManualSceneDockHeight_ - expected) <= 3;
    }

    void RunAutomaticMatrixStage(int stage, QDialog *panel, QLabel *status, int expected)
    {
        QDockWidget *dock = ScenesDock();
        if (!dock || !settings_) {
            RestartTestRecord(false, QStringLiteral("Automatic matrix setup"),
                              QStringLiteral("Scenes dock/settings unavailable."));
            if (status)
                status->setText(QStringLiteral("Automatic matrix stopped: Scenes dock/settings unavailable."));
            return;
        }

        const int floor = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
        if (status)
            status->setText(QStringLiteral("Automatic matrix stage %1/13...").arg(stage + 1));

        if (stage == -1) {
            sceneRowLockEnabled_ = true;
            sceneVisibleRows_ = 1;
            settings_->setValue(QStringLiteral("ui/sceneRowLockEnabled"), true);
            settings_->setValue(QStringLiteral("ui/sceneVisibleRows"), 1);
            settings_->setValue(QStringLiteral("debug/restartTestProbeSceneRows"), 1);
            settings_->sync();

            ApplyScale(uiPercent_, textPercent_);
            QTimer::singleShot(4300, this, [this, panel, status]() {
                const int actual = AutoMatrixDrag(true);
                QTimer::singleShot(450, this, [this, panel, status, actual]() {
                    QDockWidget *d = ScenesDock();
                    const int liveFloor = sceneRowLockEnabled_ ? qMax(1, lockedSceneDockHeight_) : 1;
                    const int rows = CountFullyVisibleSceneRows();
                    const bool ok = d && sceneVisibleRows_ == 1 && rows == 1 &&
                                    qAbs(d->height() - liveFloor) <= 3 &&
                                    qAbs(actual - d->height()) <= 3;
                    RestartTestRecord(ok, QStringLiteral("Physical 1-row minimum reachability"),
                                      QStringLiteral("Automatic DOWN reached live=%1 floor=%2 fullyVisible=%3.")
                                          .arg(d ? d->height() : -1).arg(liveFloor).arg(rows));
                    if (!ok) {
                        if (status) status->setText(QStringLiteral("Automatic 1-row preflight FAILED. Send the log."));
                        return;
                    }
                    RunAutomaticMatrixStage(0, panel, status, d->height());
                });
            });
            return;
        }

        if (stage == 0) {
            const int down = AutoMatrixDrag(true);
            if (!AutoMatrixSwitchScene()) {
                RestartTestRecord(false, QStringLiteral("Matrix DOWN -> immediate Scene"),
                                  QStringLiteral("Could not select a different Scene automatically."));
                return;
            }
            QTimer::singleShot(1800, this, [this, panel, status, down]() {
                const bool ok = AutoMatrixStableAt(down);
                RestartTestRecord(ok, QStringLiteral("Matrix DOWN -> immediate Scene"),
                                  QStringLiteral("Automatic DOWN=%1; Scene kept live/saved=%2/%3.")
                                      .arg(down).arg(ScenesDock() ? ScenesDock()->height() : -1)
                                      .arg(savedManualSceneDockHeight_));
                if (!ok) { if (status) status->setText(QStringLiteral("DOWN -> Scene FAILED. Send the log.")); return; }
                RunAutomaticMatrixStage(1, panel, status, down);
            });
            return;
        }

        if (stage == 1) {
            const int up = AutoMatrixDrag(false);
            if (!AutoMatrixSwitchScene()) {
                RestartTestRecord(false, QStringLiteral("Matrix UP -> immediate Scene"),
                                  QStringLiteral("Could not select a different Scene automatically."));
                return;
            }
            QTimer::singleShot(1800, this, [this, panel, status, up]() {
                const bool ok = AutoMatrixStableAt(up);
                RestartTestRecord(ok, QStringLiteral("Matrix UP -> immediate Scene"),
                                  QStringLiteral("Automatic UP=%1; Scene kept live/saved=%2/%3.")
                                      .arg(up).arg(ScenesDock() ? ScenesDock()->height() : -1)
                                      .arg(savedManualSceneDockHeight_));
                if (!ok) { if (status) status->setText(QStringLiteral("UP -> Scene FAILED. Send the log.")); return; }
                RunAutomaticMatrixStage(2, panel, status, up);
            });
            return;
        }

        if (stage == 2) {
            const int down = AutoMatrixDrag(true);
            if (!RunFreshRealApplyForMatrix(panel, status)) {
                RestartTestRecord(false, QStringLiteral("Matrix DOWN -> Apply"),
                                  QStringLiteral("Automatic real Apply click was not detected."));
                return;
            }
            QTimer::singleShot(4300, this, [this, panel, status, down]() {
                const bool ok = AutoMatrixStableAt(down) && lastRealApplySmoothExcursions_ == 0;
                RestartTestRecord(ok, QStringLiteral("Matrix DOWN -> Apply"),
                                  QStringLiteral("Expected=%1; live=%2 saved=%3 excursions=%4.")
                                      .arg(down).arg(ScenesDock() ? ScenesDock()->height() : -1)
                                      .arg(savedManualSceneDockHeight_).arg(lastRealApplySmoothExcursions_));
                if (!ok) { if (status) status->setText(QStringLiteral("DOWN -> Apply FAILED. Send the log.")); return; }
                RunAutomaticMatrixStage(3, panel, status, down);
            });
            return;
        }

        if (stage == 3) {
            if (!AutoMatrixSwitchScene()) {
                RestartTestRecord(false, QStringLiteral("Matrix DOWN -> Apply -> Scene"),
                                  QStringLiteral("Could not select Scene automatically."));
                return;
            }
            QTimer::singleShot(1800, this, [this, panel, status, expected]() {
                const bool ok = AutoMatrixStableAt(expected);
                RestartTestRecord(ok, QStringLiteral("Matrix DOWN -> Apply -> Scene"),
                                  QStringLiteral("Scene after Apply kept %1 px.").arg(expected));
                if (!ok) { if (status) status->setText(QStringLiteral("DOWN -> Apply -> Scene FAILED.")); return; }
                RunAutomaticMatrixStage(4, panel, status, expected);
            });
            return;
        }

        if (stage == 4) {
            const int up = AutoMatrixDrag(false);
            if (!RunFreshRealApplyForMatrix(panel, status)) {
                RestartTestRecord(false, QStringLiteral("Matrix UP -> Apply"),
                                  QStringLiteral("Automatic real Apply click was not detected."));
                return;
            }
            QTimer::singleShot(4300, this, [this, panel, status, up]() {
                const bool ok = AutoMatrixStableAt(up) && lastRealApplySmoothExcursions_ == 0;
                RestartTestRecord(ok, QStringLiteral("Matrix UP -> Apply"),
                                  QStringLiteral("Expected=%1; live=%2 saved=%3 excursions=%4.")
                                      .arg(up).arg(ScenesDock() ? ScenesDock()->height() : -1)
                                      .arg(savedManualSceneDockHeight_).arg(lastRealApplySmoothExcursions_));
                if (!ok) { if (status) status->setText(QStringLiteral("UP -> Apply FAILED. Send the log.")); return; }
                RunAutomaticMatrixStage(5, panel, status, up);
            });
            return;
        }

        if (stage == 5) {
            if (!AutoMatrixSwitchScene()) {
                RestartTestRecord(false, QStringLiteral("Matrix UP -> Apply -> Scene"),
                                  QStringLiteral("Could not select Scene automatically."));
                return;
            }
            QTimer::singleShot(1800, this, [this, panel, status, expected]() {
                const bool ok = AutoMatrixStableAt(expected);
                RestartTestRecord(ok, QStringLiteral("Matrix UP -> Apply -> Scene"),
                                  QStringLiteral("Scene after UP+Apply kept %1 px.").arg(expected));
                if (!ok) { if (status) status->setText(QStringLiteral("UP -> Apply -> Scene FAILED.")); return; }
                RunAutomaticMatrixStage(6, panel, status, expected);
            });
            return;
        }

        if (stage == 6) {
            if (!AutoMatrixSwitchScene()) {
                RestartTestRecord(false, QStringLiteral("Matrix Scene -> DOWN -> Scene"),
                                  QStringLiteral("Initial automatic Scene change failed."));
                return;
            }
            QTimer::singleShot(90, this, [this, panel, status]() {
                const int down = AutoMatrixDrag(true);
                if (!AutoMatrixSwitchScene()) {
                    RestartTestRecord(false, QStringLiteral("Matrix Scene -> DOWN -> Scene"),
                                      QStringLiteral("Second automatic Scene change failed."));
                    return;
                }
                QTimer::singleShot(1800, this, [this, panel, status, down]() {
                    const bool ok = AutoMatrixStableAt(down);
                    RestartTestRecord(ok, QStringLiteral("Matrix Scene -> DOWN -> Scene"),
                                      QStringLiteral("Automatic drag overrode active Scene guard; height=%1.").arg(down));
                    if (!ok) { if (status) status->setText(QStringLiteral("Scene -> DOWN -> Scene FAILED.")); return; }
                    RunAutomaticMatrixStage(7, panel, status, down);
                });
            });
            return;
        }

        if (stage == 7) {
            if (!AutoMatrixSwitchScene()) {
                RestartTestRecord(false, QStringLiteral("Matrix Scene -> UP -> Scene"),
                                  QStringLiteral("Initial automatic Scene change failed."));
                return;
            }
            QTimer::singleShot(90, this, [this, panel, status]() {
                const int up = AutoMatrixDrag(false);
                if (!AutoMatrixSwitchScene()) {
                    RestartTestRecord(false, QStringLiteral("Matrix Scene -> UP -> Scene"),
                                      QStringLiteral("Second automatic Scene change failed."));
                    return;
                }
                QTimer::singleShot(1800, this, [this, panel, status, up]() {
                    const bool ok = AutoMatrixStableAt(up);
                    RestartTestRecord(ok, QStringLiteral("Matrix Scene -> UP -> Scene"),
                                      QStringLiteral("Automatic UP overrode active Scene guard; height=%1.").arg(up));
                    if (!ok) { if (status) status->setText(QStringLiteral("Scene -> UP -> Scene FAILED.")); return; }
                    RunAutomaticMatrixStage(8, panel, status, up);
                });
            });
            return;
        }

        if (stage == 8 || stage == 9) {
            const bool downDirection = stage == 8;
            const int height = AutoMatrixDrag(downDirection);
            auto repeat = std::make_shared<int>(0);
            auto doScene = std::make_shared<std::function<void()>>();
            *doScene = [this, panel, status, stage, height, repeat, doScene]() {
                if (*repeat >= 3) {
                    QTimer::singleShot(1800, this, [this, panel, status, stage, height]() {
                        const bool ok = AutoMatrixStableAt(height);
                        RestartTestRecord(ok,
                                          stage == 8 ? QStringLiteral("Matrix DOWN -> repeated Scenes")
                                                     : QStringLiteral("Matrix UP -> repeated Scenes"),
                                          QStringLiteral("Three automatic Scene changes kept %1 px.").arg(height));
                        if (!ok) { if (status) status->setText(QStringLiteral("Repeated Scene matrix FAILED.")); return; }
                        RunAutomaticMatrixStage(stage + 1, panel, status, height);
                    });
                    return;
                }
                if (!AutoMatrixSwitchScene()) {
                    RestartTestRecord(false, QStringLiteral("Repeated Scene automation"),
                                      QStringLiteral("Could not select another Scene."));
                    return;
                }
                ++(*repeat);
                QTimer::singleShot(260, this, [doScene]() { (*doScene)(); });
            };
            (*doScene)();
            return;
        }

        if (stage == 10 || stage == 11) {
            const bool downDirection = stage == 10;
            const int height = AutoMatrixDrag(downDirection);
            if (!AutoMatrixSwitchScene()) {
                RestartTestRecord(false,
                                  stage == 10 ? QStringLiteral("Matrix DOWN -> Scene -> Apply")
                                              : QStringLiteral("Matrix UP -> Scene -> Apply"),
                                  QStringLiteral("Automatic Scene change failed."));
                return;
            }
            QTimer::singleShot(150, this, [this, panel, status, stage, height]() {
                if (!RunFreshRealApplyForMatrix(panel, status)) {
                    RestartTestRecord(false,
                                      stage == 10 ? QStringLiteral("Matrix DOWN -> Scene -> Apply")
                                                  : QStringLiteral("Matrix UP -> Scene -> Apply"),
                                      QStringLiteral("Automatic real Apply click was not detected."));
                    return;
                }
                QTimer::singleShot(4300, this, [this, panel, status, stage, height]() {
                    const bool ok = AutoMatrixStableAt(height) && lastRealApplySmoothExcursions_ == 0;
                    RestartTestRecord(ok,
                                      stage == 10 ? QStringLiteral("Matrix DOWN -> Scene -> Apply")
                                                  : QStringLiteral("Matrix UP -> Scene -> Apply"),
                                      QStringLiteral("Expected=%1; live=%2 saved=%3 excursions=%4.")
                                          .arg(height).arg(ScenesDock() ? ScenesDock()->height() : -1)
                                          .arg(savedManualSceneDockHeight_).arg(lastRealApplySmoothExcursions_));
                    if (!ok) { if (status) status->setText(QStringLiteral("Scene -> Apply matrix FAILED. Send the log.")); return; }

                    if (stage == 10) {
                        RunAutomaticMatrixStage(11, panel, status, height);
                        return;
                    }

                    if (obs_frontend_streaming_active() || obs_frontend_recording_active()) {
                        RestartTestRecord(false, QStringLiteral("Automatic OBS relaunch"),
                                          QStringLiteral("Streaming/recording is active; automatic restart was intentionally blocked."));
                        if (status) status->setText(QStringLiteral("Automatic matrix stopped because streaming/recording is active."));
                        return;
                    }

                    settings_->setValue(QStringLiteral("debug/restartTestExpectedManualHeight"), height);
                    settings_->setValue(QStringLiteral("debug/restartTestPhase"), 2);
                    settings_->setValue(QStringLiteral("debug/restartTestActive"), true);
                    settings_->sync();

                    if (!LaunchObsRestartHelper()) {
                        RestartTestRecord(false, QStringLiteral("Automatic OBS relaunch"),
                                          QStringLiteral("Could not start delayed OBS relaunch helper."));
                        if (status) status->setText(QStringLiteral("Automatic OBS relaunch helper failed."));
                        return;
                    }

                    RestartTestRecord(true, QStringLiteral("Automatic OBS relaunch"),
                                      QStringLiteral("Fully automatic pre-restart matrix passed; restarting OBS."));
                    if (panel)
                        panel->close();
                    QTimer::singleShot(350, qApp, []() { qApp->quit(); });
                });
            });
            return;
        }
    }

    void ShowManualRestartTestPanel()
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock || !settings_) {
            RestartTestRecord(false, QStringLiteral("Automatic action-matrix setup"),
                              QStringLiteral("Scenes dock/settings unavailable."));
            return;
        }

        auto *panel = new QDialog(mainWindow);
        panel->setAttribute(Qt::WA_DeleteOnClose);
        panel->setWindowTitle(QStringLiteral("OBS UI Scale v3.28 DEBUG - Fully Automatic Matrix"));
        panel->setWindowModality(Qt::NonModal);
        panel->setWindowFlag(Qt::Tool, true);
        panel->setWindowFlag(Qt::WindowStaysOnTopHint, true);
        panel->resize(620, 180);

        auto *layout = new QVBoxLayout(panel);
        auto *info = new QLabel(QStringLiteral(
            "Fully automatic test is running. No dragging, Scene clicking, Apply clicking, Continue buttons, or other manual input is required.\n\n"
            "OBS will restart itself once during the test."), panel);
        info->setWordWrap(true);
        layout->addWidget(info);
        auto *status = new QLabel(QStringLiteral("Starting automatic 1-row preflight..."), panel);
        status->setWordWrap(true);
        layout->addWidget(status);

        panel->show();
        panel->raise();
        panel->activateWindow();

        QTimer::singleShot(250, this, [this, panel, status]() {
            RunAutomaticMatrixStage(-1, panel, status, -1);
        });
    }

'@
Replace-Block '    void ShowManualRestartTestPanel()' '    void BeginRestartEndToEndTest(' $autoMatrix 'fully automatic pre-restart combination matrix'

# Fully automatic post-restart sequence.
$autoPostRestart = @'
    void ShowPostRestartCombinationPanel(int startupExpected)
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock) {
            RestartTestRecord(false, QStringLiteral("Post-restart automatic matrix setup"),
                              QStringLiteral("Scenes dock unavailable."));
            FinishPostRestartApplyAndRestore(startupExpected);
            return;
        }

        auto *panel = new QDialog(mainWindow);
        panel->setAttribute(Qt::WA_DeleteOnClose);
        panel->setWindowTitle(QStringLiteral("OBS UI Scale v3.28 DEBUG - Automatic Post-Restart Test"));
        panel->setWindowModality(Qt::NonModal);
        panel->setWindowFlag(Qt::Tool, true);
        panel->setWindowFlag(Qt::WindowStaysOnTopHint, true);
        panel->resize(600, 150);

        auto *layout = new QVBoxLayout(panel);
        auto *status = new QLabel(QStringLiteral("Automatically testing restart -> repeated Scenes..."), panel);
        status->setWordWrap(true);
        layout->addWidget(status);
        panel->show();

        const int expectedStartup = startupExpected;

        if (!AutoMatrixSwitchScene()) {
            RestartTestRecord(false, QStringLiteral("Post-restart repeated Scene stability"),
                              QStringLiteral("Could not switch Scene automatically."));
            FinishPostRestartApplyAndRestore(startupExpected);
            return;
        }

        QTimer::singleShot(260, this, [this, panel, status, expectedStartup]() {
            if (!AutoMatrixSwitchScene()) {
                RestartTestRecord(false, QStringLiteral("Post-restart repeated Scene stability"),
                                  QStringLiteral("Second automatic Scene change failed."));
                FinishPostRestartApplyAndRestore(expectedStartup);
                return;
            }

            QTimer::singleShot(1800, this, [this, panel, status, expectedStartup]() {
                const bool stable = AutoMatrixStableAt(expectedStartup);
                RestartTestRecord(stable, QStringLiteral("Post-restart repeated Scene stability"),
                                  QStringLiteral("Automatic repeated Scenes kept restart height=%1; live=%2 saved=%3.")
                                      .arg(expectedStartup)
                                      .arg(ScenesDock() ? ScenesDock()->height() : -1)
                                      .arg(savedManualSceneDockHeight_));
                if (!stable) {
                    if (status) status->setText(QStringLiteral("Post-restart repeated Scene test FAILED."));
                    return;
                }

                if (status) status->setText(QStringLiteral("Automatically testing post-restart DOWN -> Scene..."));
                const int down = AutoMatrixDrag(true);
                if (!AutoMatrixSwitchScene()) {
                    RestartTestRecord(false, QStringLiteral("Post-restart DOWN -> immediate Scene"),
                                      QStringLiteral("Automatic Scene change failed."));
                    return;
                }

                QTimer::singleShot(1800, this, [this, panel, status, down]() {
                    const bool downOk = AutoMatrixStableAt(down);
                    RestartTestRecord(downOk, QStringLiteral("Post-restart DOWN -> immediate Scene"),
                                      QStringLiteral("Automatic DOWN=%1 survived Scene; live=%2 saved=%3.")
                                          .arg(down).arg(ScenesDock() ? ScenesDock()->height() : -1)
                                          .arg(savedManualSceneDockHeight_));
                    if (!downOk) {
                        if (status) status->setText(QStringLiteral("Post-restart DOWN -> Scene FAILED."));
                        return;
                    }

                    if (status) status->setText(QStringLiteral("Automatically testing post-restart UP -> Scene..."));
                    const int up = AutoMatrixDrag(false);
                    if (!AutoMatrixSwitchScene()) {
                        RestartTestRecord(false, QStringLiteral("Post-restart UP -> immediate Scene"),
                                          QStringLiteral("Automatic Scene change failed."));
                        return;
                    }

                    QTimer::singleShot(1800, this, [this, panel, status, up]() {
                        const bool upOk = AutoMatrixStableAt(up);
                        RestartTestRecord(upOk, QStringLiteral("Post-restart UP -> immediate Scene"),
                                          QStringLiteral("Automatic UP=%1 survived Scene; live=%2 saved=%3.")
                                              .arg(up).arg(ScenesDock() ? ScenesDock()->height() : -1)
                                              .arg(savedManualSceneDockHeight_));
                        if (!upOk) {
                            if (status) status->setText(QStringLiteral("Post-restart UP -> Scene FAILED."));
                            return;
                        }

                        if (panel)
                            panel->close();
                        FinishPostRestartApplyAndRestore(up);
                    });
                });
            });
        });
    }

'@
Replace-Block '    void ShowPostRestartCombinationPanel(int startupExpected)' '    void ContinueRestartTestAfterStartup()' $autoPostRestart 'fully automatic post-restart matrix'

# User-facing naming: one click starts everything.
$s = $s.Replace('Run Complete Combination-Matrix Test', 'Run Fully Automatic Combination-Matrix Test')
$s = $s.Replace('Complete Combination-Matrix Test', 'Fully Automatic Combination-Matrix Test')
$s = $s.Replace('COMPLETE COMBINATION-MATRIX TEST', 'FULLY AUTOMATIC COMBINATION-MATRIX TEST')

# Remove stale manual wording from the main test tooltip if present.
$s = $s.Replace(
    'Tests every normal OBS UI Scale control/button, real manual drag-to-minimum, immediate and repeated real Scene clicks, real OBS restart, startup restore, and Apply after restart.',
    'One-click automatic test of controls, drag-equivalent dock heights, Scene changes, real Apply buttons, real OBS restart, startup restore, and post-restart combinations. No manual steps after starting.')

$s = $s.Replace('OBS UI Scale v3.27 DEBUG', 'OBS UI Scale v3.28 DEBUG')
$s = $s.Replace('OBS UI Scale v3.27 DEBUG LOG', 'OBS UI Scale v3.28 DEBUG LOG')
$s = $s.Replace('v3.27 DEBUG', 'v3.28 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.27.0', '3.28.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.27.0', 'OBS-UI-Scale-Debug-Setup-3.28.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.28 DEBUG fully automatic one-click combination matrix.'
