import AppKit
import Combine

/// Factory defaults for Settings → Appearance. User overrides live in UserDefaults.
/// The native traffic-light/title bar always keeps a solid Nord background.
/// Opacity values range from 0 (more material shows through) to 1 (solid Nord).
enum AppearanceConfiguration {
    static let translucencyEnabled = true
    static let material: NSVisualEffectView.Material = .underWindowBackground
    static let windowTintOpacity = 0.20
    static let headerTintOpacity = 0.0
    static let editorTintOpacity = 0.60
    static let sidebarTintOpacity = 0.0

}


final class AppearanceSettings: ObservableObject {
    @Published var translucencyEnabled: Bool {
        didSet { defaults.set(translucencyEnabled, forKey: "appearance.translucencyEnabled") }
    }
    @Published var headerOpacity: Double {
        didSet { defaults.set(headerOpacity, forKey: "appearance.headerOpacity") }
    }
    @Published var editorOpacity: Double {
        didSet { defaults.set(editorOpacity, forKey: "appearance.editorOpacity") }
    }
    @Published var sidebarOpacity: Double {
        didSet { defaults.set(sidebarOpacity, forKey: "appearance.sidebarOpacity") }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        translucencyEnabled = defaults.object(forKey: "appearance.translucencyEnabled") as? Bool
            ?? AppearanceConfiguration.translucencyEnabled
        func opacity(_ key: String, fallback: Double) -> Double {
            guard let number = defaults.object(forKey: key) as? NSNumber else { return fallback }
            let value = number.doubleValue
            return value.isFinite ? min(1, max(0, value)) : fallback
        }
        headerOpacity = opacity("appearance.headerOpacity", fallback: AppearanceConfiguration.headerTintOpacity)
        editorOpacity = opacity("appearance.editorOpacity", fallback: AppearanceConfiguration.editorTintOpacity)
        sidebarOpacity = opacity("appearance.sidebarOpacity", fallback: AppearanceConfiguration.sidebarTintOpacity)
    }

    func restoreDefaults() {
        translucencyEnabled = AppearanceConfiguration.translucencyEnabled
        headerOpacity = AppearanceConfiguration.headerTintOpacity
        editorOpacity = AppearanceConfiguration.editorTintOpacity
        sidebarOpacity = AppearanceConfiguration.sidebarTintOpacity
    }

    func opacity(_ value: Double) -> Double { translucencyEnabled ? value : 1 }
}
