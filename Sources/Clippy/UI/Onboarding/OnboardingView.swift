import SwiftUI

/// The first-run walkthrough: one full-window hero per step, progress dots and a glass footer.
/// Every step, including informational ones, is skippable.
struct OnboardingView: View {
    var viewModel: OnboardingViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                OnboardingStepContent(viewModel: viewModel)
                    .frame(maxWidth: 460)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.top, 44)
                    .padding(.bottom, 16)
                    .id(viewModel.model.current)
                    .transition(.opacity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: viewModel.model.current)
            footer
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 520)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(colors: [Color.accentColor.opacity(0.16), .clear], startPoint: .top, endPoint: .center)
            }
        }
        .clipShape(shape)
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }

    private var progressDots: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStep.allCases) { step in
                Capsule()
                    .fill(step == viewModel.model.current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: step == viewModel.model.current ? 18 : 7, height: 7)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: viewModel.model.current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(viewModel.model.position) of \(viewModel.model.total)")
    }

    private var footer: some View {
        VStack(spacing: 12) {
            progressDots
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button("Back") { viewModel.back() }
                        .buttonStyle(.glass)
                        .disabled(viewModel.model.isFirst)
                        .keyboardShortcut(.leftArrow, modifiers: .command)
                    Button("Skip for now") { viewModel.skipAll() }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityHint("Closes the walkthrough; reopen it from Help, Show Welcome")
                    Spacer()
                    if viewModel.model.current.isSkippable && !viewModel.model.isFirst {
                        Button(viewModel.model.current.isPermission ? "Continue without granting" : "Skip this step") { viewModel.skipStep() }
                            .buttonStyle(.glass)
                    }
                    Button(viewModel.model.isLast ? "Get started" : "Continue") { viewModel.advance() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }
}

#Preview("Onboarding") {
    OnboardingView(viewModel: OnboardingViewModel(defaults: UserDefaults(suiteName: "onboarding.preview") ?? .standard))
        .frame(width: 720, height: 520)
}
