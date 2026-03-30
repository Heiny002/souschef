import SwiftUI
import SwiftData

/// Cook Mode — voice-first, full-screen step-by-step cooking interface.
/// Features: TTS reads steps aloud, voice commands, micro-step splitting,
/// smart timers with per-side support, pinned timer overlay.
struct CookModeView: View {
    let recipe: Recipe
    @Environment(\.dismiss) private var dismiss

    // Voice + timer
    @StateObject private var voice = CookVoiceController()
    @StateObject private var timerState = CookTimerState()
    @State private var voiceEnabled = false

    // Navigation
    @State private var currentIndex = 0
    @State private var showIngredients = false

    // Micro-steps built from recipe on appear
    private struct MicroStep {
        let instruction: String
        let detectedTimer: DetectedTimer?
    }
    @State private var microSteps: [MicroStep] = []

    private var current: MicroStep? {
        guard !microSteps.isEmpty, microSteps.indices.contains(currentIndex) else { return nil }
        return microSteps[currentIndex]
    }
    private var isFirst: Bool { currentIndex == 0 }
    private var isLast: Bool  { currentIndex == microSteps.count - 1 }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.scBackground.ignoresSafeArea()

            if microSteps.isEmpty {
                emptyState
            } else {
                cookInterface
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            buildMicroSteps()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            voice.deactivate()
            timerState.stop()
        }
        .sheet(isPresented: $showIngredients) {
            ingredientsSheet
        }
        .task {
            voiceEnabled = await voice.requestPermissions()
            if voiceEnabled {
                voice.onCommand = { [self] cmd in handleVoiceCommand(cmd) }
                // Brief delay so the view is settled before TTS starts
                try? await Task.sleep(nanoseconds: 400_000_000)
                speakCurrent()
            }
        }
    }

    // MARK: - Build micro-steps

    private func buildMicroSteps() {
        let sorted = recipe.steps.sorted { $0.order < $1.order }
        microSteps = sorted.flatMap { step -> [MicroStep] in
            let parts = MicroStepSplitter.split(step.instruction)
            return parts.map { instruction in
                MicroStep(
                    instruction: instruction,
                    detectedTimer: TimerDetector.detect(in: instruction)
                )
            }
        }
    }

    // MARK: - Navigation

    private func goNext() {
        guard !isLast else { dismiss(); return }
        advance(by: +1)
    }

    private func goBack() {
        guard !isFirst else { return }
        advance(by: -1)
    }

    private func advance(by delta: Int) {
        timerState.stop()
        voice.stopSpeaking()
        withAnimation(.easeInOut(duration: 0.25)) { currentIndex += delta }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            speakCurrent()
            if let t = current?.detectedTimer {
                timerState.configure(from: t)
            }
        }
    }

    // MARK: - TTS

    private func speakCurrent() {
        guard voiceEnabled, let step = current else { return }
        let prefix = microSteps.count > 1
            ? "Step \(currentIndex + 1). "
            : ""
        voice.speak(prefix + step.instruction)
    }

    // MARK: - Voice commands

    private func handleVoiceCommand(_ cmd: CookVoiceController.VoiceCommand) {
        switch cmd {
        case .next:          goNext()
        case .back:          goBack()
        case .startTimer:    timerState.start()
        case .stopTimer:     timerState.pause()
        case .repeatStep:    speakCurrent()
        case .showIngredients: showIngredients = true
        }
    }

    // MARK: - Swipe gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { v in
                let h = v.translation.width
                guard abs(h) > abs(v.translation.height) else { return }
                if h < 0 { goNext() } else { goBack() }
            }
    }

    // MARK: - Main interface

    private var cookInterface: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, geo.safeAreaInsets.top + Spacing.sm)

                // Pinned timer strip
                if timerState.isConfigured {
                    pinnedTimer
                        .padding(.horizontal, Spacing.md)
                        .padding(.top, Spacing.sm)
                }

                Spacer()

                // Step counter dots
                stepDots
                    .padding(.horizontal, Spacing.md)

                Spacer(minLength: Spacing.lg)

                // Main step text
                if let step = current {
                    stepText(step.instruction)
                        .padding(.horizontal, Spacing.lg)
                        .gesture(swipeGesture)
                }

                Spacer(minLength: Spacing.xl)

                // "Start Timer" prompt if step has a timer but it's not running
                if let t = current?.detectedTimer, !timerState.isConfigured {
                    timerPrompt(t)
                        .padding(.horizontal, Spacing.md)
                }

                // Navigation buttons
                navButtons
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, geo.safeAreaInsets.bottom + Spacing.md)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(Color.scTextSecondary)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close Cook Mode")

            Spacer()

            Text(recipe.title)
                .font(.scLabel)
                .foregroundStyle(Color.scTextSecondary)
                .lineLimit(1)

            Spacer()

            HStack(spacing: Spacing.xs) {
                // Voice indicator
                if voiceEnabled {
                    Image(systemName: voice.isListening ? "mic.fill" : "mic")
                        .foregroundStyle(voice.isListening ? Color.scAccent : Color.scTextSecondary.opacity(0.5))
                        .font(.system(size: 14))
                        .animation(.easeInOut(duration: 0.3), value: voice.isListening)
                }
                Button { showIngredients = true } label: {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(Color.scTextSecondary)
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("View Ingredients")
            }
        }
    }

    // MARK: - Step dots

    private var stepDots: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(0..<microSteps.count, id: \.self) { idx in
                RoundedRectangle(cornerRadius: 2)
                    .fill(idx == currentIndex ? Color.scAccent : Color.scBorder)
                    .frame(height: 3)
                    .animation(.easeInOut(duration: 0.2), value: currentIndex)
            }
        }
        .accessibilityLabel("Step \(currentIndex + 1) of \(microSteps.count)")
    }

    // MARK: - Step text

    private func stepText(_ instruction: String) -> some View {
        Text(instruction)
            .font(.custom("Lora-Regular", size: 26, relativeTo: .title))
            .foregroundStyle(Color.scTextPrimary)
            .lineSpacing(6)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.75)
            .id(currentIndex)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .animation(.easeInOut(duration: 0.25), value: currentIndex)
    }

    // MARK: - Timer prompt (before timer is started)

    private func timerPrompt(_ t: DetectedTimer) -> some View {
        Button {
            timerState.configure(from: t)
            timerState.start()
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "timer")
                    .font(.system(size: 16))
                Text("Start \(t.label) timer\(t.isPerSide ? " · per side" : "")")
                    .font(.scLabel)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .background(Color.scSurface)
            .foregroundStyle(Color.scAccent)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.scAccent.opacity(0.4), lineWidth: 1))
        }
        .padding(.bottom, Spacing.md)
    }

    // MARK: - Pinned timer overlay

    private var pinnedTimer: some View {
        VStack(spacing: Spacing.xs) {
            // Progress bar
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.scBorder)
                    Capsule()
                        .fill(timerState.didComplete ? Color.green : Color.scAccent)
                        .frame(width: g.size.width * timerState.progressFraction)
                        .animation(.linear(duration: 1), value: timerState.secondsRemaining)
                }
            }
            .frame(height: 4)

            HStack {
                // Label + side indicator
                VStack(alignment: .leading, spacing: 2) {
                    Text(timerState.didComplete ? "Done! 🎉" : timerState.label)
                        .font(.scLabel)
                        .foregroundStyle(timerState.didComplete ? Color.green : Color.scTextPrimary)
                    if timerState.totalSides > 1 {
                        Text("Side \(timerState.sideNumber) of \(timerState.totalSides)")
                            .font(.scCaption)
                            .foregroundStyle(Color.scTextSecondary)
                    }
                }

                Spacer()

                // Time remaining
                Text(timerState.didComplete ? "00:00" : timerState.formattedTime)
                    .font(.custom("Lora-Bold", size: 32, relativeTo: .title))
                    .foregroundStyle(timerState.didComplete ? Color.green : Color.scAccent)
                    .monospacedDigit()

                Spacer()

                // Controls
                HStack(spacing: Spacing.sm) {
                    Button {
                        if timerState.isRunning { timerState.pause() }
                        else if timerState.didComplete { timerState.reset() }
                        else { timerState.start() }
                    } label: {
                        Image(systemName: buttonIcon)
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 40, height: 40)
                            .background(Color.scSurface)
                            .foregroundStyle(Color.scTextPrimary)
                            .clipShape(Circle())
                    }
                    Button { timerState.stop() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 32, height: 32)
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
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(timerState.didComplete ? Color.green.opacity(0.5) : Color.scBorder, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.3), value: timerState.didComplete)
    }

    private var buttonIcon: String {
        if timerState.didComplete { return "arrow.clockwise" }
        return timerState.isRunning ? "pause.fill" : "play.fill"
    }

    // MARK: - Navigation buttons

    private var navButtons: some View {
        HStack(spacing: Spacing.md) {
            Button {
                goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 56, height: 56)
                    .background(Color.scSurface)
                    .clipShape(Circle())
                    .foregroundStyle(isFirst ? Color.scTextSecondary.opacity(0.3) : Color.scTextPrimary)
            }
            .disabled(isFirst)
            .accessibilityLabel("Previous step")

            Spacer()

            Button {
                goNext()
            } label: {
                HStack(spacing: Spacing.sm) {
                    Text(isLast ? "Done!" : "Next")
                        .font(.scLabel)
                    Image(systemName: isLast ? "checkmark" : "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, Spacing.xl)
                .frame(height: 56)
                .background(isLast ? Color.green : Color.scAccent)
                .foregroundStyle(Color.scBackground)
                .clipShape(Capsule())
            }
            .accessibilityLabel(isLast ? "Finish cooking" : "Next step")
        }
        .padding(.top, Spacing.md)
    }

    // MARK: - Ingredients sheet

    private var ingredientsSheet: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        ForEach(recipe.ingredients.sorted { $0.order < $1.order }) { ing in
                            HStack(alignment: .top, spacing: Spacing.sm) {
                                Circle().fill(Color.scAccent).frame(width: 6, height: 6).padding(.top, 7)
                                Text(ing.rawText)
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

    // MARK: - Empty state

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

    let recipe = Recipe(title: "Pasta Primavera", extractionConfidence: 0.9, extractionMethod: "schema-org")
    recipe.steps = [
        CookingStep(order: 1, instruction: "Bring a large pot of salted water to a boil.", rawText: ""),
        CookingStep(order: 2, instruction: "Dice the carrots, celery, and onion.", rawText: ""),
        CookingStep(order: 3, instruction: "Sauté the vegetables in olive oil over medium heat for 4-6 minutes until softened.", rawText: ""),
        CookingStep(order: 4, instruction: "Cook pasta according to package directions, about 8-10 minutes.", rawText: ""),
        CookingStep(order: 5, instruction: "Toss pasta with vegetables and serve immediately.", rawText: ""),
    ]
    recipe.ingredients = [
        Ingredient(item: "pasta", rawText: "300g pasta"),
        Ingredient(item: "carrots", rawText: "2 carrots, diced"),
        Ingredient(item: "celery", rawText: "3 stalks celery"),
        Ingredient(item: "onion", rawText: "1 onion"),
    ]
    ctx.insert(recipe)

    return NavigationStack { CookModeView(recipe: recipe) }
        .modelContainer(container)
        .preferredColorScheme(.dark)
}
