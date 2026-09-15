import SwiftUI

struct ContentView: View {
    @Environment(AppEnvironment.self) var env

    private var preferredScheme: ColorScheme? {
        switch env.appearanceMode {
        case "light", "warm": return .light
        case "dark":          return .dark
        default:              return .dark
        }
    }

    var body: some View {
        MainWindowView()
            .environment(env)
            .preferredColorScheme(preferredScheme)
            // Warm mode: Night Shift-style amber cast over the light base.
            // allowsHitTesting(false) so the tint layer never swallows clicks.
            .overlay(
                Color(red: 1.0, green: 0.72, blue: 0.30)
                    .opacity(env.appearanceMode == "warm" ? 0.14 : 0)
                    .allowsHitTesting(false)
            )
    }
}
