import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            RecipeLibraryView()
                .tabItem { Label("Library", systemImage: "book.closed") }
            DinerProfilesView()
                .tabItem { Label("Diners", systemImage: "person.2") }
        }
        .tint(Color.scAccent)
    }
}

#Preview {
    ContentView()
}
