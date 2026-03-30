import SwiftUI
import SwiftData

/// SC-052: DinerProfile management — create/edit/delete household member dietary profiles.
struct DinerProfilesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DinerProfile.dateCreated) private var profiles: [DinerProfile]
    @State private var showAddSheet = false
    @State private var editingProfile: DinerProfile?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Diners")
            .toolbarBackground(Color.scBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddSheet = true } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(Color.scAccent)
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                ProfileEditSheet(profile: nil) { name, diets, restrictions, allergies in
                    let p = DinerProfile(name: name)
                    p.diets = diets
                    p.customRestrictions = restrictions
                    p.allergies = allergies
                    modelContext.insert(p)
                }
            }
            .sheet(item: $editingProfile) { profile in
                ProfileEditSheet(profile: profile) { name, diets, restrictions, allergies in
                    profile.name = name
                    profile.diets = diets
                    profile.customRestrictions = restrictions
                    profile.allergies = allergies
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if profiles.isEmpty {
            emptyState
        } else {
            profileList
        }
    }

    private var profileList: some View {
        List {
            ForEach(profiles) { profile in
                ProfileRow(profile: profile)
                    .listRowBackground(Color.scSurface)
                    .listRowSeparatorTint(Color.scBorder)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            modelContext.delete(profile)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editingProfile = profile
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(Color.scAccent)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "person.2")
                .font(.system(size: 56))
                .foregroundStyle(Color.scTextSecondary)
            Text("No diners yet")
                .font(.scHeadline)
                .foregroundStyle(Color.scTextPrimary)
            Text("Add household members to check recipe compatibility")
                .font(.scBody)
                .foregroundStyle(Color.scTextSecondary)
                .multilineTextAlignment(.center)
            Button { showAddSheet = true } label: {
                Label("Add Diner", systemImage: "person.badge.plus")
                    .font(.scLabel)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .background(Color.scAccent)
                    .foregroundStyle(Color.scBackground)
                    .clipShape(Capsule())
            }
        }
        .padding(Spacing.xl)
    }
}

// MARK: - Profile Row

private struct ProfileRow: View {
    let profile: DinerProfile

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(profile.name)
                .font(.scTitle)
                .foregroundStyle(Color.scTextPrimary)
            if !profile.diets.isEmpty {
                Text(profile.diets.joined(separator: " · "))
                    .font(.scCaption)
                    .foregroundStyle(Color.scAccent)
            }
            if !profile.allergies.isEmpty {
                Text("Allergies: " + profile.allergies.joined(separator: ", "))
                    .font(.scCaption)
                    .foregroundStyle(Color.scTextSecondary)
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - Profile Edit Sheet

struct ProfileEditSheet: View {
    let profile: DinerProfile?
    let onSave: (String, [String], [String], [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selectedDiets: Set<String>
    @State private var restrictionText: String
    @State private var allergyText: String

    private let allDiets = DietLibrary.shared.diets

    init(profile: DinerProfile?, onSave: @escaping (String, [String], [String], [String]) -> Void) {
        self.profile = profile
        self.onSave = onSave
        _name = State(initialValue: profile?.name ?? "")
        _selectedDiets = State(initialValue: Set(profile?.diets ?? []))
        _restrictionText = State(initialValue: profile?.customRestrictions.joined(separator: ", ") ?? "")
        _allergyText = State(initialValue: profile?.allergies.joined(separator: ", ") ?? "")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                Form {
                    Section("Name") {
                        TextField("e.g. Partner, Child 1", text: $name)
                            .foregroundStyle(Color.scTextPrimary)
                    }
                    .listRowBackground(Color.scSurface)

                    Section("Diets") {
                        ForEach(allDiets) { diet in
                            Toggle(diet.name, isOn: Binding(
                                get: { selectedDiets.contains(diet.id) },
                                set: { on in
                                    if on { selectedDiets.insert(diet.id) }
                                    else { selectedDiets.remove(diet.id) }
                                }
                            ))
                            .tint(Color.scAccent)
                            .foregroundStyle(Color.scTextPrimary)
                        }
                    }
                    .listRowBackground(Color.scSurface)

                    Section("Custom Restrictions") {
                        TextField("e.g. cilantro, mushrooms (comma separated)", text: $restrictionText)
                            .foregroundStyle(Color.scTextPrimary)
                    }
                    .listRowBackground(Color.scSurface)

                    Section("Allergies") {
                        TextField("e.g. peanuts, shellfish (comma separated)", text: $allergyText)
                            .foregroundStyle(Color.scTextPrimary)
                    }
                    .listRowBackground(Color.scSurface)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(profile == nil ? "New Diner" : "Edit Diner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.scBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.scTextSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let restrictions = restrictionText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        let allergies = allergyText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        onSave(name, Array(selectedDiets), restrictions, allergies)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .foregroundStyle(Color.scAccent)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Diner Profiles") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Recipe.self, DinerProfile.self, configurations: config)
    let ctx = container.mainContext
    let p1 = DinerProfile(name: "Partner")
    p1.diets = ["vegan", "gluten-free"]
    let p2 = DinerProfile(name: "Kid")
    p2.allergies = ["peanuts"]
    ctx.insert(p1); ctx.insert(p2)
    return DinerProfilesView().modelContainer(container).preferredColorScheme(.dark)
}
