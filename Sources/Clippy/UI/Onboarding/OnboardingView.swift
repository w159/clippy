import SwiftUI

/// The first-run walkthrough: step list on the left, current step on the right,
/// Back / Skip / Continue in the footer. Every step, including informational ones, is skippable.
struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @Environment(\.clippyTokens) private var tokens

    var body: some View {
        GlassSurface(in: RoundedRectangle(cornerRadius: 20)) {
            VStack(spacing: 0) {
                header
                Divider()
                HStack(spacing: 0) {
                    stepList.frame(width: 190)
                    Divider()
                    OnboardingStepContent(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(24)
                }
                Divider()
                footer
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 520)
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }

    private var header: some View {
        HStack {
            Text("Welcome to Clippy").font(.title3.weight(.semibold)).foregroundStyle(tokens.textPrimary)
            Spacer()
            Text("Step \(viewModel.model.position) of \(viewModel.model.total)")
                .font(.callout).foregroundStyle(tokens.textSecondary)
                .accessibilityLabel("Step \(viewModel.model.position) of \(viewModel.model.total)")
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(OnboardingStep.allCases) { step in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: step)).frame(width: 18)
                        .foregroundStyle(step == viewModel.model.current ? tokens.accentText : tokens.textSecondary)
                    Text(step.title)
                        .fontWeight(step == viewModel.model.current ? .semibold : .regular)
                        .foregroundStyle(step == viewModel.model.current ? tokens.textPrimary : tokens.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(step == viewModel.model.current ? tokens.selection : .clear))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(step == viewModel.model.current ? .isSelected : [])
            }
            Spacer()
        }
        .padding(12)
    }

    private func icon(for step: OnboardingStep) -> String {
        if step.rawValue < viewModel.model.current.rawValue {
            return viewModel.model.skipped.contains(step) ? "minus.circle" : "checkmark.circle.fill"
        }
        return step == viewModel.model.current ? "circle.inset.filled" : "circle"
    }

    private var footer: some View {
        HStack {
            Button("Back") { viewModel.back() }.disabled(viewModel.model.isFirst)
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Skip for now") { viewModel.skipAll() }
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Closes the walkthrough; reopen it from Help, Show Welcome")
            Spacer()
            if viewModel.model.current.isSkippable {
                Button("Skip this step") { viewModel.skipStep() }
            }
            Button(viewModel.model.isLast ? "Get started" : "Continue") { viewModel.advance() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

#Preview("Onboarding") {
    OnboardingView(viewModel: OnboardingViewModel(defaults: UserDefaults(suiteName: "onboarding.preview") ?? .standard))
        .frame(width: 720, height: 520)
}
