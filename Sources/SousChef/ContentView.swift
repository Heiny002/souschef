import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                Text("SousChef")
                    .font(.scDisplay)
                    .foregroundStyle(Color.scTextPrimary)
            }
            .navigationTitle("")
        }
    }
}

#Preview {
    ContentView()
}
