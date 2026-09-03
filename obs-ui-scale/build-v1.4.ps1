$ErrorActionPreference = 'Stop'

# Keep v1.3 behavior, but add a targeted layout-diagnostics copier so we can see
# exactly which OBS widgets/docks change size after a scene/source click instead
# of guessing at another geometry patch.
& ./build-v1.3.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.4 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.3.0";' 'static constexpr const char *PLUGIN_VERSION = "1.4.0";' 'plugin version'

# Extra Qt types used only for the diagnostics snapshot.
if (-not $s.Contains('#include <QAbstractItemView>')) {
    Replace-Required '#include <QAbstractButton>' "#include <QAbstractButton>`n#include <QAbstractItemView>" 'QAbstractItemView include'
}
if (-not $s.Contains('#include <QClipboard>')) {
    Replace-Required '#include <QCheckBox>' "#include <QCheckBox>`n#include <QClipboard>" 'QClipboard include'
}
if (-not $s.Contains('#include <QTabBar>')) {
    Replace-Required '#include <QShortcut>' "#include <QShortcut>`n#include <QTabBar>`n#include <QToolBar>" 'QTabBar/QToolBar includes'
}

$showMarker = '    void ShowDialog()'
$showPos = $s.IndexOf($showMarker)
if ($showPos -lt 0) { throw 'v1.4 could not locate ShowDialog' }

$helper = @'
    QString BuildLayoutDiagnostics() const
    {
        QString out;
        QTextStream stream(&out);
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());

        stream << "OBS UI Scale diagnostics v1.4\n";
        stream << "requested UI=" << uiPercent_ << "% text=" << textPercent_ << "%\n";
        stream << "effective UI=" << currentUiPercent_ << "% text=" << currentTextPercent_ << "%\n";
        stream << "safeTiny=" << (safeTinyMode_ ? 1 : 0)
               << " proportional=" << (proportionalMode_ ? 1 : 0) << "\n";

        if (!mainWindow) {
            stream << "mainWindow=null\n";
            return out;
        }

        auto sizeText = [](const QSize &v) {
            return QStringLiteral("%1x%2").arg(v.width()).arg(v.height());
        };
        auto rectText = [](const QRect &r) {
            return QStringLiteral("%1,%2 %3x%4").arg(r.x()).arg(r.y()).arg(r.width()).arg(r.height());
        };

        stream << "MAIN geom=" << rectText(mainWindow->geometry())
               << " min=" << sizeText(mainWindow->minimumSize())
               << " hint=" << sizeText(mainWindow->sizeHint())
               << " minHint=" << sizeText(mainWindow->minimumSizeHint()) << "\n\n";

        stream << "=== DOCKS ===\n";
        const auto docks = mainWindow->findChildren<QDockWidget *>(QString(), Qt::FindDirectChildrenOnly);
        for (QDockWidget *dock : docks) {
            if (!dock)
                continue;
            QWidget *inner = dock->widget();
            stream << "DOCK class=" << dock->metaObject()->className()
                   << " name=" << dock->objectName()
                   << " title=" << dock->windowTitle()
                   << " area=" << static_cast<int>(mainWindow->dockWidgetArea(dock))
                   << " visible=" << (dock->isVisible() ? 1 : 0)
                   << " geom=" << rectText(dock->geometry())
                   << " min=" << sizeText(dock->minimumSize())
                   << " max=" << sizeText(dock->maximumSize())
                   << " hint=" << sizeText(dock->sizeHint())
                   << " minHint=" << sizeText(dock->minimumSizeHint());
            if (inner) {
                stream << " innerClass=" << inner->metaObject()->className()
                       << " innerName=" << inner->objectName()
                       << " innerGeom=" << rectText(inner->geometry())
                       << " innerMin=" << sizeText(inner->minimumSize())
                       << " innerHint=" << sizeText(inner->sizeHint())
                       << " innerMinHint=" << sizeText(inner->minimumSizeHint());
            }
            stream << "\n";
        }

        stream << "\n=== ITEM VIEWS / TOOLBARS / COUNTER ===\n";
        const auto widgets = mainWindow->findChildren<QWidget *>(QString(), Qt::FindChildrenRecursively);
        for (QWidget *widget : widgets) {
            if (!widget)
                continue;

            const bool itemView = qobject_cast<QAbstractItemView *>(widget) != nullptr;
            const bool toolbar = qobject_cast<QToolBar *>(widget) != nullptr;
            const bool tabbar = qobject_cast<QTabBar *>(widget) != nullptr;
            const bool counter = widget->objectName() == QStringLiteral("sourceDockHiddenCountButton");
            const QString lowerName = widget->objectName().toLower();
            const bool namedInteresting = lowerName.contains(QStringLiteral("scene")) ||
                                          lowerName.contains(QStringLiteral("source")) ||
                                          lowerName.contains(QStringLiteral("mixer"));

            if (!itemView && !toolbar && !tabbar && !counter && !namedInteresting)
                continue;

            QWidget *parent = widget->parentWidget();
            stream << "W class=" << widget->metaObject()->className()
                   << " name=" << widget->objectName()
                   << " parentClass=" << (parent ? parent->metaObject()->className() : "null")
                   << " parentName=" << (parent ? parent->objectName() : QString())
                   << " visible=" << (widget->isVisible() ? 1 : 0)
                   << " geom=" << rectText(widget->geometry())
                   << " min=" << sizeText(widget->minimumSize())
                   << " max=" << sizeText(widget->maximumSize())
                   << " hint=" << sizeText(widget->sizeHint())
                   << " minHint=" << sizeText(widget->minimumSizeHint());

            if (auto *view = qobject_cast<QAbstractItemView *>(widget)) {
                const int rows = view->model() ? view->model()->rowCount() : -1;
                stream << " rows=" << rows;
                if (rows > 0) {
                    stream << " rowHints=";
                    const int limit = qMin(rows, 6);
                    for (int i = 0; i < limit; ++i) {
                        if (i)
                            stream << ',';
                        stream << view->sizeHintForRow(i);
                    }
                }
                stream << " icon=" << sizeText(view->iconSize());
            }

            if (auto *button = qobject_cast<QAbstractButton *>(widget))
                stream << " text=[" << button->text() << "]";

            stream << "\n";
        }

        return out;
    }

'@
$s = $s.Substring(0, $showPos) + $helper + $s.Substring($showPos)

# QTextStream is used by BuildLayoutDiagnostics.
if (-not $s.Contains('#include <QTextStream>')) {
    Replace-Required '#include <QTabBar>' "#include <QTabBar>`n#include <QTextStream>" 'QTextStream include'
}

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.3"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.4"));' 'dialog title'

# Add a copy button above the normal Apply/Restore/Close row. It changes no UI
# geometry; it only snapshots the current state to the clipboard.
Replace-Required @'
        auto *buttons = new QDialogButtonBox(&dialog);
'@ @'
        auto *copyDiagnostics = new QPushButton(QStringLiteral("Copy layout diagnostics"), &dialog);
        layout->addWidget(copyDiagnostics);

        auto *buttons = new QDialogButtonBox(&dialog);
'@ 'diagnostics button creation'

Replace-Required @'
        QObject::connect(apply, &QPushButton::clicked, &dialog,
'@ @'
        QObject::connect(copyDiagnostics, &QPushButton::clicked, &dialog,
                         [this, status]() {
                             QApplication::clipboard()->setText(BuildLayoutDiagnostics());
                             status->setText(QStringLiteral("Layout diagnostics copied to clipboard — paste them into ChatGPT."));
                         });

        QObject::connect(apply, &QPushButton::clicked, &dialog,
'@ 'diagnostics button handler'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.3.0', '1.4.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v1.4 layout diagnostics build.'
