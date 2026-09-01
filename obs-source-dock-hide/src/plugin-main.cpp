#include <obs-module.h>
#include <obs-frontend-api.h>
#include <util/bmem.h>

#include <QAbstractButton>
#include <QAbstractItemModel>
#include <QAction>
#include <QApplication>
#include <QBoxLayout>
#include <QByteArray>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
#include <QDockWidget>
#include <QFileInfo>
#include <QItemSelectionModel>
#include <QLabel>
#include <QListView>
#include <QListWidget>
#include <QMainWindow>
#include <QMenu>
#include <QPointer>
#include <QPushButton>
#include <QSet>
#include <QSettings>
#include <QStringList>
#include <QTimer>
#include <QToolButton>
#include <QVBoxLayout>

#include <algorithm>
#include <memory>

OBS_DECLARE_MODULE()
OBS_MODULE_AUTHOR("Source Dock Hide community plugin")

static constexpr const char *PLUGIN_NAME = "Source Dock Hide";
static constexpr const char *PLUGIN_VERSION = "0.4.0";

const char *obs_module_description(void)
{
    return "Adds Mixer-style hiding for rows in OBS's Sources dock while leaving the underlying sources active.";
}

class SourceDockHideController final : public QObject {
public:
    SourceDockHideController()
    {
        char *configPath = obs_module_config_path("source-dock-hide.ini");
        if (configPath) {
            const QString path = QString::fromUtf8(configPath);
            QFileInfo info(path);
            QDir().mkpath(info.absolutePath());
            settings_ = std::make_unique<QSettings>(path, QSettings::IniFormat);
            bfree(configPath);
        }

        obs_frontend_add_event_callback(&SourceDockHideController::FrontendEvent, this);

        toolsAction_ = static_cast<QAction *>(obs_frontend_add_tools_menu_qaction("Manage Hidden Sources..."));
        if (toolsAction_)
            QObject::connect(toolsAction_, &QAction::triggered, this, [this]() { ShowManager(); });

        QTimer::singleShot(0, this, [this]() {
            FindSourceTree();
            ScheduleApply();
        });

        blog(LOG_INFO, "[%s] loaded v%s", PLUGIN_NAME, PLUGIN_VERSION);
    }

    ~SourceDockHideController() override
    {
        obs_frontend_remove_event_callback(&SourceDockHideController::FrontendEvent, this);
        if (settings_)
            settings_->sync();
        blog(LOG_INFO, "[%s] unloaded", PLUGIN_NAME);
    }

private:
    static void FrontendEvent(enum obs_frontend_event event, void *privateData)
    {
        auto *self = static_cast<SourceDockHideController *>(privateData);
        if (!self)
            return;

        switch (event) {
        case OBS_FRONTEND_EVENT_FINISHED_LOADING:
            QTimer::singleShot(0, self, [self]() {
                self->FindSourceTree();
                self->ScheduleApply();
            });
            break;
        case OBS_FRONTEND_EVENT_SCENE_CHANGED:
        case OBS_FRONTEND_EVENT_SCENE_LIST_CHANGED:
        case OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED:
            // Match the Mixer-style experience: changing scenes returns to the normal
            // view where hidden rows are hidden again.
            self->showHiddenRows_ = false;
            QTimer::singleShot(0, self, [self]() {
                self->FindSourceTree();
                self->ScheduleApply();
            });
            break;
        default:
            break;
        }
    }

    void FindSourceTree()
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        QListView *found = nullptr;
        const auto views = mainWindow->findChildren<QListView *>();

        for (auto *view : views) {
            if (view && view->inherits("SourceTree")) {
                found = view;
                break;
            }
        }

        if (!found) {
            for (auto *view : views) {
                if (view && view->objectName().compare("sources", Qt::CaseInsensitive) == 0) {
                    found = view;
                    break;
                }
            }
        }

        if (!found)
            return;

        if (sourceTree_ != found) {
            sourceTree_ = found;
            observedModel_.clear();
        }

        AttachModelSignals();
        EnsureHiddenCountButton();
        UpdateHiddenCountButton();
    }

    void AttachModelSignals()
    {
        if (!sourceTree_ || !sourceTree_->model())
            return;

        QAbstractItemModel *model = sourceTree_->model();
        if (observedModel_ == model)
            return;

        observedModel_ = model;
        QObject::connect(model, &QAbstractItemModel::rowsInserted, this, [this]() { ScheduleApply(); });
        QObject::connect(model, &QAbstractItemModel::rowsRemoved, this, [this]() { ScheduleApply(); });
        QObject::connect(model, &QAbstractItemModel::modelReset, this, [this]() { ScheduleApply(); });
        QObject::connect(model, &QAbstractItemModel::layoutChanged, this, [this]() { ScheduleApply(); });
        QObject::connect(model, &QAbstractItemModel::dataChanged, this, [this]() { ScheduleApply(); });
    }

    QBoxLayout *FindSourcesButtonLayout(QDockWidget *sourcesDock) const
    {
        if (!sourcesDock)
            return nullptr;

        QBoxLayout *bestLayout = nullptr;
        int bestY = -1;
        int bestButtonCount = 0;

        const auto buttons = sourcesDock->findChildren<QAbstractButton *>();
        for (QAbstractButton *button : buttons) {
            if (!button || button == hiddenCountButton_)
                continue;

            QWidget *parent = button->parentWidget();
            if (!parent)
                continue;

            auto *layout = qobject_cast<QBoxLayout *>(parent->layout());
            if (!layout)
                continue;

            int buttonCount = 0;
            for (int i = 0; i < layout->count(); ++i) {
                if (auto *w = layout->itemAt(i)->widget()) {
                    if (qobject_cast<QAbstractButton *>(w))
                        ++buttonCount;
                }
            }

            if (buttonCount < 2)
                continue;

            const int y = button->mapTo(sourcesDock, QPoint(0, 0)).y();
            if (y > bestY || (y == bestY && buttonCount > bestButtonCount)) {
                bestY = y;
                bestButtonCount = buttonCount;
                bestLayout = layout;
            }
        }

        return bestLayout;
    }

    void EnsureHiddenCountButton()
    {
        if (!sourceTree_)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        QDockWidget *sourcesDock = mainWindow->findChild<QDockWidget *>("sourcesDock");
        if (!sourcesDock) {
            QWidget *w = sourceTree_->parentWidget();
            while (w && !sourcesDock) {
                sourcesDock = qobject_cast<QDockWidget *>(w);
                w = w->parentWidget();
            }
        }
        if (!sourcesDock)
            return;

        QBoxLayout *buttonLayout = FindSourcesButtonLayout(sourcesDock);
        if (!buttonLayout)
            return;

        if (!hiddenCountButton_) {
            hiddenCountButton_ = new QToolButton(sourcesDock);
            hiddenCountButton_->setObjectName("sourceDockHiddenCountButton");
            hiddenCountButton_->setText("0 hidden");
            hiddenCountButton_->setToolButtonStyle(Qt::ToolButtonTextOnly);
            hiddenCountButton_->setAutoRaise(true);
            hiddenCountButton_->setCheckable(true);
            hiddenCountButton_->setMinimumHeight(28);
            hiddenCountButton_->setMinimumWidth(72);
            hiddenCountButton_->setToolTip("0 hidden sources");
            hiddenCountButton_->setAccessibleName("Show or hide sources hidden from the Sources list");
            hiddenCountButton_->setContextMenuPolicy(Qt::CustomContextMenu);

            QObject::connect(hiddenCountButton_, &QToolButton::clicked, this, [this]() {
                const int hiddenCount = HiddenCountInCurrentModel();
                if (hiddenCount <= 0) {
                    showHiddenRows_ = false;
                    UpdateHiddenCountButton();
                    return;
                }

                showHiddenRows_ = !showHiddenRows_;
                ScheduleApply();
            });

            QObject::connect(hiddenCountButton_, &QWidget::customContextMenuRequested, this,
                             [this](const QPoint &) { ShowHiddenButtonMenu(); });
        }

        if (hiddenCountButton_->parentWidget() != buttonLayout->parentWidget())
            hiddenCountButton_->setParent(buttonLayout->parentWidget());

        // Keep the control in the requested empty area: after OBS's normal
        // Sources buttons and before the toolbar stretch.
        bool alreadyInLayout = false;
        int lastButtonIndex = -1;
        for (int i = 0; i < buttonLayout->count(); ++i) {
            QWidget *w = buttonLayout->itemAt(i)->widget();
            if (w == hiddenCountButton_) {
                alreadyInLayout = true;
                continue;
            }
            if (qobject_cast<QAbstractButton *>(w))
                lastButtonIndex = i;
        }

        if (!alreadyInLayout)
            buttonLayout->insertWidget(lastButtonIndex + 1, hiddenCountButton_);

        hiddenCountButton_->show();
    }

    QString ItemName(const QModelIndex &index) const
    {
        if (!index.isValid())
            return {};

        QString name = index.data(Qt::AccessibleTextRole).toString();
        if (name.isEmpty())
            name = index.data(Qt::DisplayRole).toString();
        return name.trimmed();
    }

    QString CurrentSceneStorageKey() const
    {
        QString collection;
        if (char *collectionName = obs_frontend_get_current_scene_collection()) {
            collection = QString::fromUtf8(collectionName);
            bfree(collectionName);
        }

        obs_source_t *scene = obs_frontend_get_current_scene();
        if (!scene)
            return {};

        QString identity;
        const char *uuid = obs_source_get_uuid(scene);
        if (uuid && *uuid)
            identity = QString::fromUtf8(uuid);
        else
            identity = QString::fromUtf8(obs_source_get_name(scene));
        obs_source_release(scene);

        const QByteArray raw = (collection + QLatin1Char('|') + identity).toUtf8();
        return QString::fromLatin1(raw.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals));
    }

    QString SettingsKey() const
    {
        const QString sceneKey = CurrentSceneStorageKey();
        return sceneKey.isEmpty() ? QString() : QStringLiteral("hidden/%1").arg(sceneKey);
    }

    QStringList HiddenNames() const
    {
        if (!settings_)
            return {};
        const QString key = SettingsKey();
        if (key.isEmpty())
            return {};

        QStringList names = settings_->value(key).toStringList();
        names.removeAll(QString());
        names.removeDuplicates();
        names.sort(Qt::CaseInsensitive);
        return names;
    }

    void SaveHiddenNames(QStringList names)
    {
        if (!settings_)
            return;
        const QString key = SettingsKey();
        if (key.isEmpty())
            return;

        names.removeAll(QString());
        names.removeDuplicates();
        names.sort(Qt::CaseInsensitive);
        settings_->setValue(key, names);
        settings_->sync();
    }

    QSet<QString> CurrentModelNames() const
    {
        QSet<QString> names;
        if (!sourceTree_ || !sourceTree_->model())
            return names;

        QAbstractItemModel *model = sourceTree_->model();
        const int rows = model->rowCount();
        for (int row = 0; row < rows; ++row) {
            const QString name = ItemName(model->index(row, 0));
            if (!name.isEmpty())
                names.insert(name);
        }
        return names;
    }

    int HiddenCountInCurrentModel() const
    {
        const QSet<QString> modelNames = CurrentModelNames();
        int count = 0;
        for (const QString &name : HiddenNames()) {
            if (modelNames.contains(name))
                ++count;
        }
        return count;
    }

    void ScheduleApply()
    {
        if (applyQueued_)
            return;
        applyQueued_ = true;
        QTimer::singleShot(0, this, [this]() {
            applyQueued_ = false;
            ApplyHiddenRows();
        });
    }

    void ApplyHiddenRows()
    {
        FindSourceTree();
        if (!sourceTree_ || !sourceTree_->model())
            return;

        const QStringList storedHidden = HiddenNames();
        QSet<QString> hidden;
        for (const QString &name : storedHidden)
            hidden.insert(name);

        QABstractItemModel *model = sourceTree_->model();
        const int rows = model->rowCount();
        QSet<QString> existingNames;

        for (int row = 0; row < rows; ++row) {
            const QModelIndex index = model->index(row, 0);
            const QString name = ItemName(index);
            if (!name.isEmpty())
                existingNames.insert(name);

            const bool isMarkedHidden = !name.isEmpty() && hidden.contains(name);
            sourceTree_->setRowHidden(row, isMarkedHidden && !showHiddenRows_);
        }

        // Remove stale names if a hidden source was actually deleted from the scene.
        QStringList cleanedHidden;
        for (const QString &name : storedHidden) {
            if (existingNames.contains(name))
                cleanedHidden.push_back(name);
        }
        if (cleanedHidden != storedHidden)
            SaveHiddenNames(cleanedHidden);

        if (cleanedHidden.isEmpty())
            showHiddenRows_ = false;

        UpdateHiddenCountButton();
    }

    void UpdateHiddenCountButton()
    {
        if (!hiddenCountButton_)
            return;

        const int hiddenCount = HiddenCountInCurrentModel();
        if (hiddenCount <= 0)
            showHiddenRows_ = false;

        hiddenCountButton_->setText(QStringLiteral("%1 hidden").arg(hiddenCount));

        // QToolButton::click toggles its checked state itself; always make the
        // visual state match our actual show/hide state.
        hiddenCountButton_->setChecked(showHiddenRows_ && hiddenCount > 0);

        if (hiddenCount <= 0) {
            hiddenCountButton_->setToolTip(
                "0 hidden sources\nRight-click to hide the currently selected source(s)");
        } else if (showHiddenRows_) {
            hiddenCountButton_->setToolTip(
                QString("%1 hidden source(s) are currently shown\nClick to hide them again\nRight-click for options")
                    .arg(hiddenCount));
        } else {
            hiddenCountButton_->setToolTip(
                QString("%1 hidden source(s)\nClick to show them temporarily\nRight-click for options")
                    .arg(hiddenCount));
        }
    }

    QStringList SelectedNames() const
    {
        QStringList names;
        if (!sourceTree_ || !sourceTree_->selectionModel())
            return names;

        const QModelIndexList selected = sourceTree_->selectionModel()->selectedRows();
        for (const QModelIndex &index : selected) {
            const QString name = ItemName(index);
            if (!name.isEmpty())
                names.push_back(name);
        }
        names.removeDuplicates();
        return names;
    }

    void HideSelectedRows()
    {
        const QStringList selectedNames = SelectedNames();
        if (selectedNames.isEmpty())
            return;

        QSet<QString> hidden;
        for (const QString &name : HiddenNames())
            hidden.insert(name);
        for (const QString &name : selectedNames)
            hidden.insert(name);

        SaveHiddenNames(hidden.values());
        showHiddenRows_ = false;
        ScheduleApply();
    }

    void UnhideSelectedRows()
    {
        const QStringList selectedNames = SelectedNames();
        if (selectedNames.isEmpty())
            return;

        QStringList hidden = HiddenNames();
        for (const QString &name : selectedNames)
            hidden.removeAll(name);

        SaveHiddenNames(hidden);
        ScheduleApply();
    }

    void ShowHiddenButtonMenu()
    {
        if (!hiddenCountButton_)
            return;

        const QStringList selected = SelectedNames();
        const QSet<QString> hiddenSet = [&]() {
            QSet<QString> set;
            for (const QString &name : HiddenNames())
                set.insert(name);
            return set;
        }();

        bool canHideSelection = false;
        bool canUnhideSelection = false;
        for (const QString &name : selected) {
            if (hiddenSet.contains(name))
                canUnhideSelection = true;
            else
                canHideSelection = true;
        }

        QMenu menu;
        QAction *hide = menu.addAction("Hide Selected Source(s) from Sources Dock");
        hide->setEnabled(canHideSelection);
        QObject::connect(hide, &QAction::triggered, this, [this]() { HideSelectedRows(); });

        QAction *unhide = menu.addAction("Unhide Selected Source(s)");
        unhide->setEnabled(canUnhideSelection);
        QObject::connect(unhide, &QAction::triggered, this, [this]() { UnhideSelectedRows(); });

        menu.addSeparator();
        QAction *manage = menu.addAction("Manage Hidden Sources...");
        QObject::connect(manage, &QAction::triggered, this, [this]() { ShowManager(); });

        menu.exec(hiddenCountButton_->mapToGlobal(QPoint(0, hiddenCountButton_->height())));
    }

    void ShowManager()
    {
        FindSourceTree();

        auto *mainWindow = static_cast<QWidget *>(obs_frontend_get_main_window());
        QDialog dialog(mainWindow);
        dialog.setWindowTitle("Hidden Sources");
        dialog.resize(440, 330);

        auto *layout = new QVBoxLayout(&dialog);
        auto *label = new QLabel(
            "These entries are hidden only from the Sources list. Their video, audio, filters, monitoring, cloning, and scene visibility are unchanged.",
            &dialog);
        label->setWordWrap(true);
        layout->addWidget(label);

        auto *list = new QListWidget(&dialog);
        list->setSelectionMode(QAbstractItemView::ExtendedSelection);
        layout->addWidget(list, 1);

        auto refill = [list](const QStringList &names) {
            list->clear();
            for (const QString &name : names)
                list->addItem(name);
        };
        refill(HiddenNames());

        auto *unhideSelected = new QPushButton("Unhide Selected", &dialog);
        auto *unhideAll = new QPushButton("Unhide All", &dialog);
        auto *close = new QPushButton("Close", &dialog);

        auto *buttons = new QDialogButtonBox(&dialog);
        buttons->addButton(unhideSelected, QDialogButtonBox::ActionRole);
        buttons->addButton(unhideAll, QDialogButtonBox::ActionRole);
        buttons->addButton(close, QDialogButtonBox::RejectRole);
        layout->addWidget(buttons);

        QObject::connect(close, &QPushButton::clicked, &dialog, &QDialog::reject);

        QObject::connect(unhideSelected, &QPushButton::clicked, &dialog, [&, this]() {
            QStringList names = HiddenNames();
            const auto selectedItems = list->selectedItems();
            for (QListWidgetItem *item : selectedItems)
                names.removeAll(item->text());
            SaveHiddenNames(names);
            refill(HiddenNames());
            ScheduleApply();
        });

        QObject::connect(unhideAll, &QPushButton::clicked, &dialog, [&, this]() {
            SaveHiddenNames({});
            showHiddenRows_ = false;
            refill({});
            ScheduleApply();
        });

        dialog.exec();
        ScheduleApply();
    }

private:
    QPointer<QListView> sourceTree_;
    QPointer<QAbstractItemModel> observedModel_;
    QPointer<QToolButton> hiddenCountButton_;
    QPointer<QAction> toolsAction_;
    std::unique_ptr<QSettings> settings_;
    bool applyQueued_ = false;
    bool showHiddenRows_ = false;
};

static SourceDockHideController *g_controller = nullptr;

bool obs_module_load(void)
{
    if (!qApp) {
        blog(LOG_ERROR, "[%s] Qt application is not available", PLUGIN_NAME);
        return false;
    }

    g_controller = new SourceDockHideController();
    return true;
}

void obs_module_unload(void)
{
    delete g_controller;
    g_controller = nullptr;
}
