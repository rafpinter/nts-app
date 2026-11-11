import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var store: NoteStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Saving", systemImage: "square.and.arrow.down")
                .font(NordTheme.sectionTitle)
            Toggle("Enable autosave", isOn: $store.autosaveEnabled)
            Text("Save changes after one second without typing. New notes get a timestamped filename; existing notes keep their names. Switching notes or closing the window still saves pending edits when autosave is off.")
                .font(NordTheme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.folder == nil {
                Text("Choose a notes folder in the main window to start autosaving.")
                    .font(NordTheme.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(NordTheme.body)
        .padding(24)
    }
}

struct AppearanceSettingsView: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Appearance", systemImage: "paintpalette")
                .font(NordTheme.sectionTitle)
            Toggle("Translucent backgrounds", isOn: $appearance.translucencyEnabled)
            VStack(spacing: 16) {
                opacitySlider("Toolbar tint", value: $appearance.headerOpacity)
                opacitySlider("Editor", value: $appearance.editorOpacity)
                opacitySlider("Sidebar", value: $appearance.sidebarOpacity)
            }
            .disabled(!appearance.translucencyEnabled)
            Text("Lower values reveal more background material. Toolbar tint adjusts the unified bar; window controls stay on a solid title bar.")
                .font(NordTheme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if reduceTransparency {
                Text("Reduce Transparency is enabled in macOS, so backgrounds stay solid.")
                    .font(NordTheme.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Restore Defaults", action: appearance.restoreDefaults)
            }
        }
        .font(NordTheme.body)
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func opacitySlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1) { Text("\(title) opacity") }
        }
    }
}
