import SwiftUI
import SwiftData

/// SC-043: Cook Mode — voice-first, full-screen step-by-step cooking interface.
/// Large serif text (24–28pt min), minimal chrome, swipe to advance, keep-awake.
struct CookModeView: View {
    let recipe: Recipe
    @Environment(\.dismiss) private var dismiss

    @State private var currentStepIndex = 0
    @State private var timerSeconds: Int = 0
    @State private var timerRunning = false
    @State private var showIngredients = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var sortedSteps: [CookingStep] {
        recipe.steps.sorted { $0.order < $1.order }
    }

    private var currentStep: CookingStep? {
        guard !sortedSteps.isEmpty, currentStepIndex < sortedSteps.count else { return nil }
        return sortedSteps[currentStepIndex]
    }

    private var isFirstStep: Bool { currentStepIndex == 0 }
    private var isLastStep: Bool { currentStepIndex == sortedSteps.count - 1 }

    var body: some View {
        ZStack {
            Color.scBackground.ignoresSafeArea()

            if sortedSteps.isEmpty {
                emptyState
            } else {
                cookInterface
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onReceive(timer) { _ in tickTimer() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(isPresented: $showIngredients) {
            ingredientsSheet
        }
    }

    // MARK: - Main Interface

    private var cookInterface: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Top bar — minimal chrome
                topBar
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, geo.safeAreaInsets.top + Spacing.sm)

                Spacer()

                // Step counter
                stepCounter
                    .padding(.horizontal, Spacing.md)

                Spacer(minLength: Spacing.lg)

                // Main step text — the star
                if let step = currentStep {
                    stepText(step: step)
                        .padding(.horizontal, Spacing.lg)
                        .gesture(swipeGesture)
                }

                Spacer(minLength: Spacing.xl)

                // Timer section (if step has duration)
                if let step = currentStep, let duration = step.duration, duration > 0 {
                    timerSection(duration: duration)
                        .padding(.horizontal, Spacing.md)
                }

                // Navigation buttons
                navigationButtons
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, geo.safeAreaInsets.bottom + Spacing.md)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(Color.scTextSecondary)
                    .font(.system(size: 18, weight: .medium))
            }
            Spacer()
            Text(recipe.title)
                .font(.scLabel)
                .foregroundStyle(Color.scTextSecondary)
                .lineLimit(1)
            Spacer()
            Button { showIngredients = true } label: {
                Image(systemName: "list.bullet")
                    .foregroundStyle(Color.scTextSecondary)
                    .font(.system(size: 18, weight: .medium))
            }
        }
    }

    private var stepCounter: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(0..<sortedSteps.count, id: \.self) { idx in
                RoundedRectangle(cornerRadius: 2)
                    .fill(idx == currentStepIndex ? Color.scAccent : Color.scBorder)
                    .frame(height: 3)
                    .animation(.easeInOut(duration: 0.2), value: currentStepIndex)
            }
        }
    }

    private func stepText(step: CookingStep) -> some View {
        Text(step.instruction)
            .font(.custom("Lora-Regular", size: 26, relativeTo: .title))
            .foregroundStyle(Color.scTextPrimary)
            .lineSpacing(6)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.8)
            .id(step.order)  // Forces re-render on step change
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .animation(.easeInOut(duration: 0.25), value: currentStepIndex)
    }

    private var navigationButtons: some View {
        HStack(spacing: Spacing.md) {
            // Previous
            Button {
                guard !isFirstStep else { return }
                withAnimation { currentStepIndex -= 1 }
                resetTimer()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 56, height: 56)
                    .background(Color.scSurface)
                    .clipShape(Circle())
                    .foregroundStyle(isFirstStep ? Color.scTextSecondary.opacity(0.3) : Color.scTextPrimary)
            }
            .disabled(isFirstStep)

            Spacer()

            // Next / Done
            Button {
                if isLastStep {
                    dismiss()
                } else {
                    withAnimation { currentStepIndex += 1 }
                    resetTimer()
                }
            } label: {
                HStack(spacing: Spacing.sm) {
                    Text(isLastStep ? "Done!" : "Next")
                        .font(.scLabel)
                    if !isLastStep {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .medium))
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .frame(height: 56)
                .background(isLastStep ? Color.green : Color.scAccent)
                .foregroundStyle(Color.scBackground)
                .clipShape(Capsule())
            }
        }
        .padding(.top, Spacing.md)
    }

    // MARK: - Timer

    private func timerSection(duration: Int) -> some View {
        VStack(spacing: Spacing.sm) {
            let displayTime = timerRunning || timerSeconds > 0 ? timerSeconds : duration
            Text(formatTime(displayTime))
                .font(.custom("Lora-Bold", size: 48, relativeTo: .largeTitle))
                .foregroundStyle(timerRunning ? Color.scAccent : Color.scTextSecondary)
                .monospacedDigit()

            HStack(spacing: Spacing.md) {
                Button {
                    if timerRunning {
                        timerRunning = false
                    } else {
                        if timerSeconds == 0 { timerSeconds = duration }
                        timerRunning = true
                    }
                } label: {
                    Label(timerRunning ? "Pause" : (timerSeconds > 0 ? "Resume" : "Start Timer"),
                          systemImage: timerRunning ? "pause.fill" : "play.fill")
                        .font(.scCaption)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.xs)
                        .background(Color.scSurface)
                        .foregroundStyle(Color.scTextPrimary)
                        .clipShape(Capsule())
                }
                if timerSeconds > 0 {
                    Button {
                        resetTimer()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.scCaption)
                            .padding(Spacing.sm)
                            .background(Color.scSurface)
                            .foregroundStyle(Color.scTextSecondary)
                            .clipShape(Circle())
                    }
                }
            }
        }
        .padding(Spacing.md)
        .background(Color.scSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func tickTimer() {
        guard timerRunning, timerSeconds > 0 else {
            if timerRunning && timerSeconds == 0 {
                timerRunning = false
                // Timer done — could trigger haptic/sound here
            }
            return
        }
        timerSeconds -= 1
    }

    private func resetTimer() {
        timerRunning = false
        timerSeconds = 0
    }

    private func formatTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Swipe Gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)
                guard abs(horizontal) > vertical else { return }
                if horizontal < 0, !isLastStep {
                    withAnimation { currentStepIndex += 1 }
                    resetTimer()
                } else if horizontal > 0, !isFirstStep {
                    withAnimation { currentStepIndex -= 1 }
                    resetTimer()
                }
            }
    }

    // MARK: - Ingredients Sheet

    private var ingredientsSheet: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        ForEach(recipe.ingredients.sorted(by: { $0.order < $1.order })) { ingredient in
                            HStack(alignment: .top, spacing: Spacing.sm) {
                                Circle()
                                    .fill(Color.scAccent)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 7)
                                Text(ingredient.rawText)
                                    .font(.scBody)
                                    .foregroundStyle(Color.scTextPrimary)
                            }
                        }
                    }
                    .padding(Spacing.md)
                }
            }
            .navigationTitle("Ingredients")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.scBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showIngredients = false }
                        .foregroundStyle(Color.scAccent)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(Color.scTextSecondary)
            Text("No steps found")
                .font(.scHeadline)
                .foregroundStyle(Color.scTextPrimary)
            Button("Go Back") { dismiss() }
                .foregroundStyle(Color.scAccent)
        }
    }
}

// MARK: - Preview

#Preview("Cook Mode") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Recipe.self, DinerProfile.self, configurations: config)
    let ctx = container.mainContext

    let recipe = Recipe(title: "Chocolate Chip Cookies", extractionConfidence: 0.9, extractionMethod: "schema-org")
    let step1 = CookingStep(order: 1, instruction: "Preheat your oven to 375°F and line two baking sheets with parchment paper.", rawText: "")
    step1.duration = 10 * 60
    let step6 = CookingStep(order: 6, instruction: "Bake for 9–11 minutes until the edges are set and golden but the centers still look slightly underdone.", rawText: "")
    step6.duration = 11 * 60
    recipe.steps = [
        step1,
        CookingStep(order: 2, instruction: "In a large bowl, cream together the softened butter with both sugars until light and fluffy, about 3–4 minutes.", rawText: ""),
        CookingStep(order: 3, instruction: "Beat in the eggs one at a time, then add the vanilla extract. Mix until just combined.", rawText: ""),
        CookingStep(order: 4, instruction: "Slowly mix in the flour mixture until just incorporated. Do not over-mix or the cookies will be tough.", rawText: ""),
        CookingStep(order: 5, instruction: "Fold in the chocolate chips. Drop rounded tablespoons of dough onto the prepared baking sheets, spacing 2 inches apart.", rawText: ""),
        step6,
        CookingStep(order: 7, instruction: "Cool on the baking sheet for 5 minutes before transferring to a wire rack. Enjoy warm!", rawText: ""),
    ]
    recipe.ingredients = [
        Ingredient(item: "butter", rawText: "1 cup (2 sticks) unsalted butter, softened"),
        Ingredient(item: "sugar", rawText: "3/4 cup granulated sugar"),
        Ingredient(item: "brown sugar", rawText: "3/4 cup packed brown sugar"),
        Ingredient(item: "eggs", rawText: "2 large eggs"),
        Ingredient(item: "vanilla", rawText: "2 tsp vanilla extract"),
        Ingredient(item: "flour", rawText: "2 1/4 cups all-purpose flour"),
        Ingredient(item: "chocolate chips", rawText: "2 cups chocolate chips"),
    ]
    ctx.insert(recipe)

    return NavigationStack {
        CookModeView(recipe: recipe)
    }
    .modelContainer(container)
    .preferredColorScheme(.dark)
}
