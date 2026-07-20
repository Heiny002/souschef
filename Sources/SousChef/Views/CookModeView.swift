import SwiftUI
import SwiftData

/// Cook Mode — voice-first, full-screen step-by-step cooking interface.
/// Features: TTS reads steps aloud, voice commands, micro-step splitting,
/// stackable smart timers with per-side support and completion guidance.
struct CookModeView: View {
    let recipe: Recipe
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    // Voice + timers
    @StateObject private var voice = CookVoiceController()
    @StateObject private var timers = CookTimerStack()
    @State private var voiceEnabled = false

    // Navigation
    @State private var currentIndex = 0
    @State private var showIngredients = false
    /// Chip tapped → sheet showing that timer's step and controls.
    @State private var selectedTimerID: UUID?
    /// Voice "what timers do I have going?" → list of every timer.
    @State private var showTimerList = false

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

            // "What to do next" overlay when a timer finishes.
            if let done = timers.justCompleted {
                completionOverlay(done)
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
            voice.onCommand = nil   // break the voice → closure → view-state → voice cycle
            voice.deactivate()
            timers.stopAll()
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning from lock/background: snap every countdown back to wall-clock
            // truth immediately instead of waiting for the next ticker fire.
            if phase == .active { timers.reconcile() }
        }
        .onChange(of: timers.justCompleted) { _, done in
            // Speak the guidance so a cook with messy hands hears what to do next.
            if let done, voiceEnabled {
                voice.speak("Timer done. \(completionGuidance(for: done))")
            }
        }
        .sheet(isPresented: $showIngredients) {
            ingredientsSheet
        }
        .sheet(isPresented: Binding(
            get: { selectedTimerID != nil },
            set: { if !$0 { selectedTimerID = nil } }
        )) {
            timerDetailSheet
        }
        .sheet(isPresented: $showTimerList) {
            timerListSheet
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
        let rawInstructions = sorted.flatMap { MicroStepSplitter.split($0.instruction) }

        // Reorder so an oven preheat overlaps hands-off downtime (marinate/chill/rest).
        let sequenced = StepSequencer.reorder(rawInstructions)

        // Annotate first-mention ingredients with their measurements (in final cook order)
        let annotated = IngredientAnnotator.annotate(sequenced, with: recipe.ingredients)

        microSteps = annotated.map { instruction in
            MicroStep(
                instruction: instruction,
                detectedTimer: TimerDetector.detect(in: instruction)
            )
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
        // Timers are stackable and independent of navigation — the step-4 simmer keeps
        // counting while you move on to chop on step 5 (H8). Nothing to stop here.
        voice.stopSpeaking()
        withAnimation(.easeInOut(duration: 0.25)) { currentIndex += delta }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            speakCurrent()
        }
    }

    private func jump(to stepIndex: Int) {
        guard microSteps.indices.contains(stepIndex), stepIndex != currentIndex else { return }
        voice.stopSpeaking()
        withAnimation(.easeInOut(duration: 0.25)) { currentIndex = stepIndex }
    }

    // MARK: - Timer helpers

    private func startTimer(_ t: DetectedTimer, forStep index: Int) {
        guard microSteps.indices.contains(index) else { return }
        timers.add(t, stepIndex: index, stepInstruction: microSteps[index].instruction)
    }

    /// What the cook should do now that this timer finished — the flip prompt for a
    /// per-side timer, otherwise the step that follows the one the timer came from.
    private func completionGuidance(for t: CookTimer) -> String {
        if t.hasSidesLeft {
            if let subject = TimerSubjectExtractor.subject(in: t.stepInstruction) {
                return "Flip the \(subject) — ready for side \(t.sideNumber + 1) of \(t.totalSides)."
            }
            return "Time to flip — ready for side \(t.sideNumber + 1) of \(t.totalSides)."
        }
        if currentIndex > t.stepIndex {
            return "Step \(t.stepIndex + 1) is done cooking — keep going with your current step."
        }
        let next = t.stepIndex + 1
        if microSteps.indices.contains(next) {
            return "Up next: \(microSteps[next].instruction)"
        }
        return "That was the last step — you're done cooking!"
    }

    /// Spoken answer to "what timers do I have going?"
    private func timerSummary() -> String {
        let running = timers.runningTimers
        guard !running.isEmpty else { return "No timers are running." }
        let parts = running.map { t in
            let side = t.isPerSide ? ", side \(t.sideNumber) of \(t.totalSides)" : ""
            return "\(t.label)\(side), with \(spokenDuration(t.secondsRemaining)) left"
        }
        if running.count == 1 { return "One timer going: \(parts[0])." }
        return "\(running.count) timers going: \(parts.joined(separator: ". "))."
    }

    private func spokenDuration(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        if m > 0 && s > 0 { return "\(m) minute\(m == 1 ? "" : "s") \(s) second\(s == 1 ? "" : "s")" }
        if m > 0 { return "\(m) minute\(m == 1 ? "" : "s")" }
        return "\(s) second\(s == 1 ? "" : "s")"
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
        case .next:
            // A misheard "next" on the last step used to instantly exit Cook Mode
            // (audit UI/UX medium). Voice never dismisses — that stays a deliberate tap.
            if isLast {
                voice.speak("This is the last step. Tap Done when you're finished.")
            } else {
                goNext()
            }
        case .back:
            goBack()
        case .startTimer:
            if let existing = timers.timer(forStep: currentIndex) {
                // Paused → resume; completed per-side → next side.
                if existing.didComplete && existing.hasSidesLeft {
                    timers.startNextSide(id: existing.id)
                } else {
                    timers.start(id: existing.id)
                }
            } else if let t = current?.detectedTimer {
                startTimer(t, forStep: currentIndex)
            }
        case .stopTimer:
            // Pause this step's timer if it has one, otherwise the most recent running one.
            if let t = timers.timer(forStep: currentIndex), t.isRunning {
                timers.pause(id: t.id)
            } else if let last = timers.runningTimers.last {
                timers.pause(id: last.id)
            }
        case .listTimers:
            voice.speak(timerSummary())
            if timers.hasTimers { showTimerList = true }
        case .repeatStep:
            speakCurrent()
        case .showIngredients:
            showIngredients = true
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

                // Minimal timer chips — one per active timer, tap to see its step.
                if timers.hasTimers {
                    timerChips
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

                // "Start Timer" prompt — only while this step doesn't have its own timer
                // yet. Other steps' timers keep running in the chip row (stackable).
                if let t = current?.detectedTimer, timers.timer(forStep: currentIndex) == nil {
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

    // MARK: - Timer chips

    private var timerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(timers.timers) { t in
                    timerChip(t)
                }
            }
            .padding(.horizontal, Spacing.md)
        }
    }

    /// Minimal once started: just an icon and the countdown. Enlarges (and fills with
    /// the accent color) when 10 seconds or less remain so an imminent expiry is
    /// glanceable from across the counter.
    private func timerChip(_ t: CookTimer) -> some View {
        let urgent = t.isRunning && t.secondsRemaining <= 10
        return Button {
            selectedTimerID = t.id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: t.didComplete ? "checkmark.circle.fill"
                                  : (t.isRunning ? "timer" : "pause.fill"))
                    .font(.system(size: urgent ? 24 : 14, weight: .medium))
                Text(t.didComplete ? "Done" : t.formattedTime)
                    .font(.custom("Lora-Bold", size: urgent ? 30 : 17))
                    .monospacedDigit()
            }
            .padding(.horizontal, urgent ? Spacing.lg : Spacing.md)
            .padding(.vertical, urgent ? Spacing.sm : 6)
            .background(urgent ? Color.scAccent : Color.scSurface)
            .foregroundStyle(
                t.didComplete ? Color.green
                    : (urgent ? Color.scBackground
                       : (t.isRunning ? Color.scAccent : Color.scTextSecondary))
            )
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    t.didComplete ? Color.green.opacity(0.5)
                        : (urgent ? Color.clear : Color.scBorder),
                    lineWidth: 1
                )
            )
        }
        .animation(.easeInOut(duration: 0.25), value: urgent)
        .accessibilityLabel(chipAccessibilityLabel(t))
    }

    private func chipAccessibilityLabel(_ t: CookTimer) -> String {
        if t.didComplete { return "\(t.label) timer finished. Tap for details." }
        let state = t.isRunning ? "running" : "paused"
        return "\(t.label) timer \(state), \(spokenDuration(t.secondsRemaining)) left, step \(t.stepIndex + 1). Tap for details."
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

    // MARK: - Timer prompt (before this step's timer is started)

    private func timerPrompt(_ t: DetectedTimer) -> some View {
        Button {
            startTimer(t, forStep: currentIndex)
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

    // MARK: - Completion overlay ("what to do next")

    private func completionOverlay(_ done: CookTimer) -> some View {
        VStack {
            Spacer()
            VStack(spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.green)
                    Text("\(done.label) timer done")
                        .font(.scHeadline)
                        .foregroundStyle(Color.scTextPrimary)
                }

                Text(completionGuidance(for: done))
                    .font(.custom("Lora-Regular", size: 20, relativeTo: .title3))
                    .foregroundStyle(Color.scTextPrimary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                if done.hasSidesLeft {
                    Button {
                        timers.startNextSide(id: done.id)
                    } label: {
                        Text("Start side \(done.sideNumber + 1)")
                            .font(.scLabel)
                            .padding(.horizontal, Spacing.xl)
                            .frame(height: 48)
                            .background(Color.scAccent)
                            .foregroundStyle(Color.scBackground)
                            .clipShape(Capsule())
                    }
                    Button("Not yet") { timers.justCompleted = nil }
                        .font(.scLabel)
                        .foregroundStyle(Color.scTextSecondary)
                } else {
                    Button {
                        // A finished timer's job is done — clear the chip too.
                        timers.remove(id: done.id)
                    } label: {
                        Text("Got it")
                            .font(.scLabel)
                            .padding(.horizontal, Spacing.xl)
                            .frame(height: 48)
                            .background(Color.scAccent)
                            .foregroundStyle(Color.scBackground)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(Spacing.lg)
            .background(Color.scSurface)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.green.opacity(0.5), lineWidth: 1)
            )
            .padding(Spacing.lg)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.45).ignoresSafeArea())
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .animation(.easeInOut(duration: 0.25), value: timers.justCompleted != nil)
    }

    // MARK: - Timer detail sheet (chip tapped → show the step)

    @ViewBuilder
    private var timerDetailSheet: some View {
        if let id = selectedTimerID, let t = timers.timer(id: id) {
            NavigationStack {
                ZStack {
                    Color.scBackground.ignoresSafeArea()
                    VStack(spacing: Spacing.lg) {
                        // Countdown
                        VStack(spacing: Spacing.xs) {
                            Text(t.didComplete ? "Done! 🎉" : t.formattedTime)
                                .font(.custom("Lora-Bold", size: 56, relativeTo: .largeTitle))
                                .foregroundStyle(t.didComplete ? Color.green : Color.scAccent)
                                .monospacedDigit()
                            Text(t.label + (t.isPerSide ? " · side \(t.sideNumber) of \(t.totalSides)" : ""))
                                .font(.scLabel)
                                .foregroundStyle(Color.scTextSecondary)
                        }

                        // Progress bar
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.scBorder)
                                Capsule()
                                    .fill(t.didComplete ? Color.green : Color.scAccent)
                                    .frame(width: g.size.width * t.progressFraction)
                            }
                        }
                        .frame(height: 4)
                        .padding(.horizontal, Spacing.lg)

                        // The step this timer belongs to
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Step \(t.stepIndex + 1)")
                                .font(.scCaption)
                                .foregroundStyle(Color.scTextSecondary)
                            Text(t.stepInstruction)
                                .font(.scBody)
                                .foregroundStyle(Color.scTextPrimary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.md)
                        .background(Color.scSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, Spacing.md)

                        if t.stepIndex != currentIndex {
                            Button {
                                jump(to: t.stepIndex)
                                selectedTimerID = nil
                            } label: {
                                Label("Go to this step", systemImage: "arrow.right.circle")
                                    .font(.scLabel)
                            }
                            .foregroundStyle(Color.scAccent)
                        }

                        Spacer()

                        // Controls
                        HStack(spacing: Spacing.md) {
                            Button {
                                if t.didComplete && t.hasSidesLeft {
                                    timers.startNextSide(id: t.id)
                                } else if t.isRunning {
                                    timers.pause(id: t.id)
                                } else if !t.didComplete {
                                    timers.start(id: t.id)
                                } else {
                                    timers.reset(id: t.id)
                                }
                            } label: {
                                Image(systemName: detailButtonIcon(t))
                                    .font(.system(size: 22, weight: .medium))
                                    .frame(width: 56, height: 56)
                                    .background(Color.scSurface)
                                    .foregroundStyle(Color.scTextPrimary)
                                    .clipShape(Circle())
                            }
                            .accessibilityLabel(t.isRunning ? "Pause timer" : "Start timer")

                            Button {
                                timers.reset(id: t.id)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 20, weight: .medium))
                                    .frame(width: 56, height: 56)
                                    .background(Color.scSurface)
                                    .foregroundStyle(Color.scTextPrimary)
                                    .clipShape(Circle())
                            }
                            .accessibilityLabel("Reset timer")

                            Button {
                                timers.remove(id: t.id)
                                selectedTimerID = nil
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 20, weight: .medium))
                                    .frame(width: 56, height: 56)
                                    .background(Color.scSurface)
                                    .foregroundStyle(Color.red.opacity(0.8))
                                    .clipShape(Circle())
                            }
                            .accessibilityLabel("Remove timer")
                        }
                        .padding(.bottom, Spacing.lg)
                    }
                    .padding(.top, Spacing.xl)
                }
                .navigationTitle("Timer")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color.scBackground, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { selectedTimerID = nil }
                            .foregroundStyle(Color.scAccent)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func detailButtonIcon(_ t: CookTimer) -> String {
        if t.didComplete { return t.hasSidesLeft ? "play.fill" : "arrow.clockwise" }
        return t.isRunning ? "pause.fill" : "play.fill"
    }

    // MARK: - Timer list sheet ("what timers do I have going?")

    private var timerListSheet: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                if timers.hasTimers {
                    ScrollView {
                        VStack(spacing: Spacing.sm) {
                            ForEach(timers.timers) { t in
                                Button {
                                    showTimerList = false
                                    jump(to: t.stepIndex)
                                } label: {
                                    HStack(spacing: Spacing.md) {
                                        Image(systemName: t.didComplete ? "checkmark.circle.fill"
                                                          : (t.isRunning ? "timer" : "pause.fill"))
                                            .font(.system(size: 18))
                                            .foregroundStyle(t.didComplete ? Color.green
                                                             : (t.isRunning ? Color.scAccent : Color.scTextSecondary))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(t.label + (t.isPerSide ? " · side \(t.sideNumber) of \(t.totalSides)" : ""))
                                                .font(.scLabel)
                                                .foregroundStyle(Color.scTextPrimary)
                                            Text("Step \(t.stepIndex + 1): \(t.stepInstruction)")
                                                .font(.scCaption)
                                                .foregroundStyle(Color.scTextSecondary)
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                        Text(t.didComplete ? "Done" : t.formattedTime)
                                            .font(.custom("Lora-Bold", size: 22))
                                            .foregroundStyle(t.didComplete ? Color.green : Color.scAccent)
                                            .monospacedDigit()
                                    }
                                    .padding(Spacing.md)
                                    .background(Color.scSurface)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }
                        .padding(Spacing.md)
                    }
                } else {
                    Text("No timers running")
                        .font(.scBody)
                        .foregroundStyle(Color.scTextSecondary)
                }
            }
            .navigationTitle("Timers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.scBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showTimerList = false }
                        .foregroundStyle(Color.scAccent)
                }
            }
        }
        .presentationDetents([.medium, .large])
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
