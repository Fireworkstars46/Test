$ErrorActionPreference = 'Stop'

# Start from v1.3: it still uses OBS's native QToolButton styling. v1.5 keeps
# that look but moves the visible label into a child QLabel so Qt cannot elide
# it, and broadens the context-menu detection so any normal OBS source type can
# be hidden from the Sources dock (not only sources that have Hide in Mixer).
& ./build-v1.3.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.5 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.3.0";' 'static constexpr const char *PLUGIN_VERSION = "1.5.0";' 'plugin version'

# QLabel carries the full visible text while the parent remains a real
# QToolButton, preserving the native OBS toolbar hover/checked appearance.
Replace-Required '#include <QLayout>' "#include <QLayout>`n#include <QLabel>" 'QLabel include'

$controllerMarker = 'class SourceDockHideController final : public QObject {'
$controllerPos = $s.IndexOf($controllerMarker)
if ($controllerPos -lt 0) { throw 'v1.5 could not locate controller class' }

$buttonClass = @'
class FullTextToolButton final : public QToolButton {
public:
    explicit FullTextToolButton(QWidget *parent = nullptr) : QToolButton(parent)
    {
        label_ = new QLabel(this);
        label_->setAlignment(Qt::AlignCenter);
        label_->setAttribute(Qt::WA_TransparentForMouseEvents, true);
        label_->setStyleSheet(QStringLiteral("background: transparent; border: none; padding: 0px; margin: 0px;"));
        label_->show();
    }

    void setDisplayText(const QString &text)
    {
        displayText_ = text;
        // Keep QToolButton's own label empty so its style cannot replace our
        // text with an ellipsis. The real QToolButton still paints the OBS
        // toolbar background, hover and checked states.
        QToolButton::setText(QString());
        label_->setText(text);
        label_->setFont(font());
        updateLabelGeometry();
        updateGeometry();
        update();
    }

    const QString &displayText() const { return displayText_; }

    QSize sizeHint() const override
    {
        const QSize native = QToolButton::sizeHint();
        const QSize labelSize = label_ ? label_->sizeHint() : QSize();
        return QSize(qMax(native.width(), labelSize.width() + 12),
                     qMax(native.height(), labelSize.height() + 6));
    }

protected:
    void resizeEvent(QResizeEvent *event) override
    {
        QToolButton::resizeEvent(event);
        updateLabelGeometry();
    }

    void changeEvent(QEvent *event) override
    {
        QToolButton::changeEvent(event);
        if (label_ && event && (event->type() == QEvent::FontChange ||
                                event->type() == QEvent::StyleChange ||
                                event->type() == QEvent::PaletteChange)) {
            label_->setFont(font());
            updateLabelGeometry();
            updateGeometry();
        }
    }

private:
    void updateLabelGeometry()
    {
        if (!label_)
            return;
        label_->setGeometry(rect().adjusted(4, 0, -4, 0));
        label_->raise();
    }

    QLabel *label_ = nullptr;
    QString displayText_;
};

'@
$s = $s.Substring(0, $controllerPos) + $buttonClass + $s.Substring($controllerPos)

Replace-Required @'
            hiddenCountButton_ = new QToolButton(sourcesToolbar);
            hiddenCountButton_->setObjectName("sourceDockHiddenCountButton");
            hiddenCountButton_->setText("0 hidden");
            hiddenCountButton_->setToolButtonStyle(Qt::ToolButtonTextOnly);
            hiddenCountButton_->setAutoRaise(true);
'@ @'
            hiddenCountButton_ = new FullTextToolButton(sourcesToolbar);
            hiddenCountButton_->setObjectName("sourceDockHiddenCountButton");
            hiddenCountButton_->setDisplayText(QStringLiteral("0 hidden"));
            hiddenCountButton_->setToolButtonStyle(Qt::ToolButtonTextOnly);
            hiddenCountButton_->setAutoRaise(true);
'@ 'native styled full-text counter creation'

Replace-Required @'
        hiddenCountButton_->setText(QStringLiteral("%1 hidden").arg(hiddenCount));

        // QToolBar can compress custom widgets when selection-specific source
        // controls appear. Keep a real minimum width based on the current font/text
        // so "0 hidden" / "1 hidden" never collapses to an ellipsis.
        const int textWidth = hiddenCountButton_->fontMetrics().horizontalAdvance(hiddenCountButton_->text());
'@ @'
        const QString counterText = QStringLiteral("%1 hidden").arg(hiddenCount);
        hiddenCountButton_->setDisplayText(counterText);

        // Keep enough layout width for the full child label. The actual visible
        // text is not painted by QToolButton, so Qt has nothing it can elide.
        const int textWidth = hiddenCountButton_->fontMetrics().horizontalAdvance(counterText);
'@ 'counter text through non-eliding child label'

Replace-Required 'QPointer<QToolButton> hiddenCountButton_;' 'QPointer<FullTextToolButton> hiddenCountButton_;' 'counter pointer type'

# Replace the source-menu detector. Older builds required "Hide in Mixer", which
# excluded sources such as display/window/image/scene/group sources. Detect the
# actual Sources-row menu from several stable source actions instead and insert
# our command beside Hide in Mixer when available, otherwise near Filters/
# Properties. The hiding mechanism itself remains model-based and type-agnostic.
$contextStartMarker = '    void MaybeAddSourceContextAction(QMenu *menu)'
$contextEndMarker = '    static void FrontendEvent(enum obs_frontend_event event, void *privateData)'
$contextStart = $s.IndexOf($contextStartMarker)
$contextEnd = $s.IndexOf($contextEndMarker, $contextStart)
if ($contextStart -lt 0 -or $contextEnd -lt 0) { throw 'v1.5 could not locate context-menu function' }

$newContext = @'
    void MaybeAddSourceContextAction(QMenu *menu)
    {
        if (!menu || !sourceTree_)
            return;

        if (menu->property("sourceDockHideInternalMenu").toBool() ||
            menu->property("sourceDockHideHandled").toBool())
            return;

        const QStringList selected = SelectedNames();
        if (selected.isEmpty())
            return;

        const auto actions = menu->actions();
        QAction *hideMixerAction = nullptr;
        QAction *filtersAction = nullptr;
        QAction *propertiesAction = nullptr;
        int sourceMenuSignals = 0;

        for (QAction *existingAction : actions) {
            if (!existingAction)
                continue;
            if (existingAction->objectName() == QStringLiteral("sourceDockHideContextAction"))
                return;

            QString text = existingAction->text();
            text.remove(QLatin1Char('&'));
            text = text.trimmed();

            if (text.compare(QStringLiteral("Hide in Mixer"), Qt::CaseInsensitive) == 0)
                hideMixerAction = existingAction;
            else if (text.compare(QStringLiteral("Filters"), Qt::CaseInsensitive) == 0)
                filtersAction = existingAction;
            else if (text.compare(QStringLiteral("Properties"), Qt::CaseInsensitive) == 0)
                propertiesAction = existingAction;

            if (text.compare(QStringLiteral("Properties"), Qt::CaseInsensitive) == 0 ||
                text.compare(QStringLiteral("Filters"), Qt::CaseInsensitive) == 0 ||
                text.compare(QStringLiteral("Remove"), Qt::CaseInsensitive) == 0 ||
                text.compare(QStringLiteral("Rename"), Qt::CaseInsensitive) == 0 ||
                text.compare(QStringLiteral("Transform"), Qt::CaseInsensitive) == 0 ||
                text.compare(QStringLiteral("Order"), Qt::CaseInsensitive) == 0 ||
                text.compare(QStringLiteral("Copy"), Qt::CaseInsensitive) == 0)
                ++sourceMenuSignals;
        }

        // Requiring two characteristic source-row actions prevents us from
        // modifying unrelated OBS menus while still covering every source type,
        // including ones that do not expose Hide in Mixer.
        if (sourceMenuSignals < 2 || (!propertiesAction && !filtersAction))
            return;

        menu->setProperty("sourceDockHideHandled", true);

        QSet<QString> hidden;
        for (const QString &name : HiddenNames())
            hidden.insert(name);

        bool allSelectedAreHidden = true;
        for (const QString &name : selected) {
            if (!hidden.contains(name)) {
                allSelectedAreHidden = false;
                break;
            }
        }

        auto *sourceHideAction = new QAction(allSelectedAreHidden ? QStringLiteral("Unhide from Sources")
                                                                   : QStringLiteral("Hide in Sources"),
                                             menu);
        sourceHideAction->setObjectName(QStringLiteral("sourceDockHideContextAction"));

        if (allSelectedAreHidden) {
            QObject::connect(sourceHideAction, &QAction::triggered, this,
                             [this]() { UnhideSelectedRows(); });
        } else {
            QObject::connect(sourceHideAction, &QAction::triggered, this,
                             [this]() { HideSelectedRows(); });
        }

        QAction *anchor = hideMixerAction ? hideMixerAction : (filtersAction ? filtersAction : propertiesAction);
        QAction *before = nullptr;
        const int anchorIndex = actions.indexOf(anchor);
        if (anchorIndex >= 0 && anchorIndex + 1 < actions.size())
            before = actions.at(anchorIndex + 1);
        menu->insertAction(before, sourceHideAction);
    }

'@
$s = $s.Substring(0, $contextStart) + $newContext + $s.Substring($contextEnd)

Set-Content $path $s -Encoding utf8

$issPath = 'installer/SourceDockHide.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.3.0', '1.5.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared Source Dock Hide v1.5 OBS-style non-eliding counter + all-source context menu.'
