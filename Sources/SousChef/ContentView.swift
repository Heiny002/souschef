import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            RecipeLibraryView()
                .tabItem { Label("Library", systemImage: "book.closed") }
                .toolbarBackground(Color.scBackground, for: .tabBar)
            DinerProfilesView()
                .tabItem { Label("Diners", systemImage: "person.2") }
                .toolbarBackground(Color.scBackground, for: .tabBar)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .toolbarBackground(Color.scBackground, for: .tabBar)
        }
        .tint(Color.scAccent)
    }
}

#Preview {
    ContentView()
}
