import SwiftUI

/// Settings — currently just the Anthropic API key that powers the LLM extraction fallback.
/// The key is stored in the Keychain (never in the app bundle) and can be cleared any time.
struct SettingsView: View {
    @State private var keyInput = ""
    @State private var hasKey = APIKeyProvider.hasUserKey
    @State private var savedConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        sectionHeader
                        keyField
                        actionRow
                        statusRow
                        explanation
                    }
                    .padding(Spacing.md)
                }
            }
            .navigationTitle("Settings")
            .toolbarBackground(Color.scBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    // MARK: - Sections

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("Anthropic API Key", systemImage: "key.fill")
                .font(.scLabel)
                .foregroundStyle(Color.scAccent)
            Text("Enables AI-assisted extraction for recipe pages and videos that the built-in parsers can't read on their own.")
                .font(.scCaption)
                .foregroundStyle(Color.scTextSecondary)
        }
    }

    private var keyField: some View {
        SecureField("sk-ant-…", text: $keyInput)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.scBody)
            .foregroundStyle(Color.scTextPrimary)
            .padding(Spacing.sm)
            .background(Color.scSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(Color.scBorder, lineWidth: 1)
            )
    }

    private var actionRow: some View {
        HStack(spacing: Spacing.md) {
            Button {
                APIKeyProvider.setUserKey(keyInput)
                keyInput = ""
                hasKey = APIKeyProvider.hasUserKey
                savedConfirmation = true
            } label: {
                Text("Save Key")
                    .font(.scLabel)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .background(canSave ? Color.scAccent : Color.scBorder)
                    .foregroundStyle(canSave ? Color.scBackground : Color.scTextSecondary)
                    .clipShape(Capsule())
            }
            .disabled(!canSave)

            if hasKey {
                Button(role: .destructive) {
                    APIKeyProvider.clearUserKey()
                    hasKey = false
                    savedConfirmation = false
                } label: {
                    Text("Remove Key")
                        .font(.scLabel)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if savedConfirmation {
            label("Key saved to Keychain.", icon: "checkmark.circle.fill", tint: .green)
        } else if hasKey {
            label("A key is configured.", icon: "checkmark.circle.fill", tint: .green)
        } else {
            label("No key configured — AI fallback is off.", icon: "info.circle", tint: Color.scTextSecondary)
        }

        if !keyInput.isEmpty && !APIKeyProvider.looksValid(keyInput) {
            label("That doesn't look like an Anthropic key (expected sk-ant-…).",
                  icon: "exclamationmark.triangle.fill", tint: .yellow)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Divider().overlay(Color.scBorder)
            Text("Your key is stored only on this device, in the Keychain, and sent directly to Anthropic when extracting. It is never bundled into the app or shared.")
                .font(.scCaption)
                .foregroundStyle(Color.scTextSecondary)
            Link(destination: URL(string: "https://console.anthropic.com/settings/keys")!) {
                Label("Get a key at console.anthropic.com", systemImage: "arrow.up.right.square")
                    .font(.scCaption)
                    .foregroundStyle(Color.scAccent)
            }
        }
    }

    // MARK: - Helpers

    private var canSave: Bool { APIKeyProvider.looksValid(keyInput) }

    private func label(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
                .font(.scCaption)
                .foregroundStyle(Color.scTextSecondary)
        }
    }
}

#Preview {
    SettingsView().preferredColorScheme(.dark)
}
