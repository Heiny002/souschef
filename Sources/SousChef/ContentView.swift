import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            RecipeLibraryView()
                .tabItem { Label("Library", systemImage: "book.closed") }
                .toolbarBackground(Color.scBackground, for: .tabBar)
            DiscoverView()
                .tabItem { Label("Discover", systemImage: "magnifyingglass") }
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

/// App-wide preferences. Currently just measurement units — the recipe screen still offers a
/// per-recipe unit override for one-off conversions; this is the standing default.
struct SettingsView: View {
    @AppStorage(UnitPreference.storageKey) private var preferredUnits = UnitPreference.original.rawValue

    private var preference: UnitPreference {
        UnitPreference(rawValue: preferredUnits) ?? .original
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        sectionHeader("Measurements", icon: "ruler")
                        Text("Recipes imported from abroad often use grams and millilitres. "
                             + "Choose how amounts are shown — only amounts in the other system "
                             + "are converted, so a recipe already in your units stays as written.")
                            .font(.scCaption)
                            .foregroundStyle(Color.scTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(spacing: 0) {
                            ForEach(UnitPreference.allCases) { option in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        preferredUnits = option.rawValue
                                    }
                                } label: {
                                    HStack(alignment: .top, spacing: Spacing.md) {
                                        Image(systemName: option.icon)
                                            .font(.system(size: 16))
                                            .foregroundStyle(Color.scAccent)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(option.label)
                                                .font(.scBody)
                                                .foregroundStyle(Color.scTextPrimary)
                                            Text(option.detail)
                                                .font(.scCaption)
                                                .foregroundStyle(Color.scTextSecondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .multilineTextAlignment(.leading)
                                        }
                                        Spacer(minLength: 0)
                                        if preference == option {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(Color.scAccent)
                                        }
                                    }
                                    .padding(Spacing.md)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .accessibilityAddTraits(preference == option ? [.isSelected] : [])
                                if option != UnitPreference.allCases.last {
                                    Divider().overlay(Color.scBorder).padding(.leading, Spacing.md)
                                }
                            }
                        }
                        .background(Color.scSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(Spacing.md)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.scBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.scLabel)
            .foregroundStyle(Color.scAccent)
    }
}

#Preview {
    ContentView()
}
