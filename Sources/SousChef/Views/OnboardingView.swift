import SwiftUI
import SwiftData

/// SC-060: First-run onboarding — welcome → import URL → extract → save → cook.
/// Goal: user completes their first cook within 3 minutes of fresh install.
struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var hasCompletedOnboarding: Bool

    @State private var page = 0
    @State private var showImport = false

    var body: some View {
        ZStack {
            Color.scBackground.ignoresSafeArea()

            TabView(selection: $page) {
                welcomePage.tag(0)
                importPage.tag(1)
                cookPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: page)

            VStack {
                Spacer()
                HStack {
                    // Page dots
                    pageIndicator
                    Spacer()
                    // Skip
                    Button("Skip") {
                        hasCompletedOnboarding = true
                    }
                    .font(.scCaption)
                    .foregroundStyle(Color.scTextSecondary)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.xl)
            }
        }
        .sheet(isPresented: $showImport, onDismiss: {
            hasCompletedOnboarding = true
        }) {
            ImportView()
        }
    }

    // MARK: - Pages

    private var welcomePage: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()
            Image(systemName: "fork.knife")
                .font(.system(size: 72))
                .foregroundStyle(Color.scAccent)

            VStack(spacing: Spacing.sm) {
                Text("SousChef")
                    .font(.custom("Lora-Bold", size: 36, relativeTo: .largeTitle))
                    .foregroundStyle(Color.scTextPrimary)
                Text("Your cooking companion.\nPaste any recipe link to get started.")
                    .font(.scBody)
                    .foregroundStyle(Color.scTextSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button {
                withAnimation { page = 1 }
            } label: {
                HStack(spacing: Spacing.sm) {
                    Text("Get Started")
                    Image(systemName: "arrow.right")
                }
                .font(.scLabel)
                .padding(.horizontal, Spacing.xl)
                .frame(height: 52)
                .background(Color.scAccent)
                .foregroundStyle(Color.scBackground)
                .clipShape(Capsule())
            }
            Spacer(minLength: Spacing.xxl)
        }
        .padding(.horizontal, Spacing.xl)
    }

    private var importPage: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()
            Image(systemName: "link.badge.plus")
                .font(.system(size: 72))
                .foregroundStyle(Color.scAccent)

            VStack(spacing: Spacing.sm) {
                Text("Paste a Recipe")
                    .font(.custom("Lora-Bold", size: 30, relativeTo: .title))
                    .foregroundStyle(Color.scTextPrimary)
                Text("Copy any recipe URL — AllRecipes, NYT Cooking, a food blog, or a TikTok video. SousChef extracts everything automatically.")
                    .font(.scBody)
                    .foregroundStyle(Color.scTextSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button {
                showImport = true
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "doc.on.clipboard")
                    Text("Import Recipe")
                }
                .font(.scLabel)
                .padding(.horizontal, Spacing.xl)
                .frame(height: 52)
                .background(Color.scAccent)
                .foregroundStyle(Color.scBackground)
                .clipShape(Capsule())
            }
            Button {
                withAnimation { page = 2 }
            } label: {
                Text("Skip for now")
                    .font(.scCaption)
                    .foregroundStyle(Color.scTextSecondary)
            }
            Spacer(minLength: Spacing.xxl)
        }
        .padding(.horizontal, Spacing.xl)
    }

    private var cookPage: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()
            Image(systemName: "flame.fill")
                .font(.system(size: 72))
                .foregroundStyle(Color.scAccent)

            VStack(spacing: Spacing.sm) {
                Text("Start Cooking")
                    .font(.custom("Lora-Bold", size: 30, relativeTo: .title))
                    .foregroundStyle(Color.scTextPrimary)
                Text("Cook Mode shows one step at a time in large text. Swipe to advance. The screen stays on the whole time.")
                    .font(.scBody)
                    .foregroundStyle(Color.scTextSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button {
                hasCompletedOnboarding = true
            } label: {
                HStack(spacing: Spacing.sm) {
                    Text("Go to Library")
                    Image(systemName: "book.closed")
                }
                .font(.scLabel)
                .padding(.horizontal, Spacing.xl)
                .frame(height: 52)
                .background(Color.scAccent)
                .foregroundStyle(Color.scBackground)
                .clipShape(Capsule())
            }
            Spacer(minLength: Spacing.xxl)
        }
        .padding(.horizontal, Spacing.xl)
    }

    // MARK: - Page indicator

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { idx in
                Capsule()
                    .fill(idx == page ? Color.scAccent : Color.scBorder)
                    .frame(width: idx == page ? 20 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: page)
            }
        }
    }
}

// MARK: - Preview

#Preview("Onboarding") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Recipe.self, DinerProfile.self, configurations: config)
    return OnboardingView(hasCompletedOnboarding: .constant(false))
        .modelContainer(container)
        .preferredColorScheme(.dark)
}
