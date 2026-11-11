import AppKit
import SwiftUI

enum NordTheme {
    static let background = Color(hex: 0x2E3440)
    static let sidebar = Color(hex: 0x272C36)
    static let surface = Color(hex: 0x3B4252)
    static let border = Color(hex: 0x434C5E)
    static let text = Color(hex: 0xECEFF4)
    static let secondary = Color(hex: 0xD8DEE9)
    static let muted = Color(hex: 0xA5B0C2)
    static let accent = Color(hex: 0x88C0D0)

    enum Space {
        static let small: CGFloat = 8
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let generous: CGFloat = 40
    }

    static let title = Font.system(size: 24, weight: .medium, design: .monospaced)
    static let sectionTitle = Font.system(size: 13, weight: .semibold, design: .monospaced)
    static let body = Font.system(size: 13, design: .monospaced)
    static let editor = Font.system(size: 15, design: .monospaced)
    static let caption = Font.system(size: 11, design: .monospaced)
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

struct EmptyState: View {
    let symbol: String
    var compact = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: compact ? 24 : 34, weight: .light, design: .monospaced))
            .foregroundStyle(NordTheme.accent)
            .padding(NordTheme.Space.large)
            .accessibilityHidden(true)
    }
}


struct NoteWindowBackground: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if appearance.translucencyEnabled && !reduceTransparency {
                WindowMaterial()
                NordTheme.background.opacity(AppearanceConfiguration.windowTintOpacity)
            } else {
                NordTheme.background
            }
        }
        .allowsHitTesting(false)
    }

    private struct WindowMaterial: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.blendingMode = .behindWindow
            view.state = .followsWindowActiveState
            view.material = AppearanceConfiguration.material
            return view
        }

        func updateNSView(_ view: NSVisualEffectView, context: Context) {
            view.material = AppearanceConfiguration.material
        }
    }
}
