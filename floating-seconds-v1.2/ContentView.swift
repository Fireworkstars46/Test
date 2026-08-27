import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var pipManager: PiPClockManager

    var body: some View {
        NavigationView {
            Form {
                Section {
                    PiPSourceView(manager: pipManager)
                        .aspectRatio(settings.shape.aspectRatio, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(settings.backgroundColor.swiftUIColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    HStack(spacing: 12) {
                        Button {
                            pipManager.startPiP()
                        } label: {
                            Label("Start Floating Clock", systemImage: "pip.enter")
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
                    Text("Floating clock")
                } footer: {
                    Text("The Text, Window and Border controls can all go very small. iOS still enforces its own minimum PiP window size and snap positions, so Window size is a request rather than a guarantee.")
                }

                Section("Time shown") {
                    Toggle("Hours", isOn: $settings.showHours)
                    Toggle("Minutes", isOn: $settings.showMinutes)
                    Toggle("Seconds", isOn: $settings.showSeconds)
                    Toggle("AM / PM", isOn: $settings.showAMPM)
                        .disabled(settings.use24Hour || !settings.showHours)
                    Toggle("24-hour time", isOn: $settings.use24Hour)
                    Toggle("Date (M/D)", isOn: $settings.showDate)
                }

                Section("Size") {
                    Picker("Window shape", selection: $settings.shape) {
                        ForEach(ClockShape.allCases) { shape in
                            Text(shape.title).tag(shape)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Text size")
                            Spacer()
                            Text("\(Int(settings.textScale * 100))%")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.textScale, in: 0.01...1.00, step: 0.01)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Window size")
                            Spacer()
                            Text("\(Int(settings.windowScale * 100))%")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.windowScale, in: 0.10...1.00, step: 0.05)
                        Text("10% is the smallest request. iOS may keep the outer PiP window larger.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Border")
                            Spacer()
                            Text("\(Int(settings.borderWidth)) px")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.borderWidth, in: 0...30, step: 1)
                    }

                    Picker("Weight", selection: $settings.fontWeight) {
                        ForEach(ClockFontWeight.allCases) { weight in
                            Text(weight.title).tag(weight)
                        }
                    }
                }

                Section("Appearance") {
                    Picker("Text color", selection: $settings.textColor) {
                        ForEach(ClockColor.allCases) { color in
                            HStack {
                                Circle().fill(color.swiftUIColor).frame(width: 12, height: 12)
                                Text(color.title)
                            }
                            .tag(color)
                        }
                    }

                    Picker("Background", selection: $settings.backgroundColor) {
                        ForEach(ClockColor.allCases) { color in
                            HStack {
                                Circle().fill(color.swiftUIColor).frame(width: 12, height: 12)
                                Text(color.title)
                            }
                            .tag(color)
                        }
                    }

                    Picker("Border color", selection: $settings.borderColor) {
                        ForEach(ClockColor.allCases) { color in
                            HStack {
                                Circle().fill(color.swiftUIColor).frame(width: 12, height: 12)
                                Text(color.title)
                            }
                            .tag(color)
                        }
                    }
                    .disabled(settings.borderWidth <= 0)
                }

                Section("How to use") {
                    Text("1. For the smallest clock, try Seconds only + Pixel-thin 40:1.")
                    Text("2. Set Text size as low as 1% and Border to 0 if wanted.")
                    Text("3. Set Window size to 10% and tap Start Floating Clock.")
                    Text("4. Press Home, then drag/pinch the PiP window as far as iOS allows.")
                }
            }
            .navigationTitle("Floating Seconds")
        }
        .navigationViewStyle(.stack)
    }
}
