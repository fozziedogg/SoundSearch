import SwiftUI

struct ContentView: View {
    @Environment(AppEnvironment.self) var env

    var body: some View {
        MainWindowView()
            .environment(env)
    }
}
