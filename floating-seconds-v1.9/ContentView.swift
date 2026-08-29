import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var pipManager: PiPClockManager

    var body: some View {
        NavigationView {
            Form {
                Section {
                    GeometryReader { geometry in
                        ZStack {
                            CheckerboardView()
                            PiPSourceView(manager: pipManager)
                                .aspectRatio(settings.shape.aspectRatio, contentMode: .fit)
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    setHorizontal(from: value.location.x, width: geometry.size.width)
                                }
                        )
                    }
                    .frame(height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    HStack {
                        Text("Drag position")
                        Spacer()
                        Text(positionLabel(settings.clockX))
                            .foregroundColor(.secondary)
                    }

                    Text("Tap or drag anywhere across the preview to place the seconds left or right. There are no position preset buttons anymore.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            pipManager.startPiP()
                        } label: {
                            Label("Start Seconds", systemImage: "pip.enter")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pipManager.isPiPActive)

                        if pipManager.isPiPActive {
                            Button(role: .destructive) {
                                pipManager.stopPiP()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Text(pipManager.statusText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Seconds only")
                }

                Section("Size") {
                    Picker("Window shape", selection: Binding(
                        get: { settings.shape },
                        set: { value in
                            settings.shape = value
                            refreshClock()
                        }
                    )) {
                        ForEach(ClockShape.allCases) { shape in
                            Text(shape.title).tag(shape)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Number size")
                            Spacer()
                            Text("\(Int(settings.textScale * 100))%")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: Binding(
                            get: { settings.textScale },
                            set: { value in
                                settings.textScale = value
                                refreshClock()
                            }
                        ), in: 0.25...2.00, step: 0.01)
                    }

                    HStack {
                        Text("Outer PiP size")
                        Spacer()
                        Text("Controlled by iOS")
                            .foregroundColor(.secondary)
                    }

                    Picker("Weight", selection: Binding(
                        get: { settings.fontWeight },
                        set: { value in
                            settings.fontWeight = value
                            refreshClock()
                        }
                    )) {
                        ForEach(ClockFontWeight.allCases) { weight in
                            Text(weight.title).tag(weight)
                        }
                    }
                }

                Section("Number appearance") {
                    Picker("Number color", selection: Binding(
                        get: { settings.textColor },
                        set: { value in
                            settings.textColor = value
                            refreshClock()
                        }
                    )) {
                        ForEach(ClockColor.allCases) { color in
                            HStack {
                                Circle().fill(color.swiftUIColor).frame(width: 12, height: 12)
                                Text(color.title)
                            }
                            .tag(color)
                        }
                    }

                    HStack {
                        Text("Background")
                        Spacer()
                        Text("Transparent")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("App border / padding")
                        Spacer()
                        Text("None")
                            .foregroundColor(.secondary)
                    }
                }

                Section("Outside-app controls") {
                    Text("Long-press the FloatingSeconds Home Screen icon for Start Seconds or Stop Seconds. You can also use the URLs floatingseconds://start and floatingseconds://stop in the Shortcuts app.")

                    Text("Starting from a Home Screen quick action still has to briefly activate this app because iOS will not allow an app to create a new PiP window while completely inactive.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Background / touch limits") {
                    Text("The floating clock keeps running when you leave this app normally. If you swipe FloatingSeconds away from the app switcher, iOS force-quits it and the PiP clock must stop. Apps cannot override a user force-quit.")

                    Text("The PiP strip also receives its own touches, so taps cannot pass through it to another app underneath. Drag the floating PiP strip itself to another allowed iOS position when it covers something you need to tap.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Floating Seconds")
        }
        .navigationViewStyle(.stack)
    }

    private func setHorizontal(from x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let clamped = min(max(x, 0), width)
        let normalized = (Double(clamped / width) * 2.0) - 1.0
        settings.setHorizontal(normalized)
        refreshClock()
    }

    private func refreshClock() {
        pipManager.renderNow()
        DispatchQueue.main.async {
            pipManager.renderNow()
        }
    }

    private func positionLabel(_ value: Double) -> String {
        let percent = Int(abs(value) * 100)
        if percent <= 1 { return "Center" }
        return "\(value < 0 ? "Left" : "Right") \(percent)%"
    }
}

private struct CheckerboardView: View {
    var body: some View {
        GeometryReader { _ in
            let cell: CGFloat = 12
            Canvas { context, size in
                let cols = Int(ceil(size.width / cell))
                let rows = Int(ceil(size.height / cell))
                for row in 0..<rows {
                    for col in 0..<cols {
                        let rect = CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                        let color = ((row + col) % 2 == 0) ? Color.gray.opacity(0.18) : Color.gray.opacity(0.32)
                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }
        }
    }
}
