import SwiftUI

struct AIProviderEditor: View {
    @ObservedObject var model: AIProviderManagerModel
    let descriptor: ProviderDescriptor
    @State private var draft: ProviderInstance

    init(model: AIProviderManagerModel, instance: ProviderInstance, descriptor: ProviderDescriptor) {
        self.model = model
        self.descriptor = descriptor
        _draft = State(initialValue: instance)
    }

    var body: some View {
        Group {
            AIProviderDetailSection(model: model, draft: $draft, descriptor: descriptor)
            if AIProviderSettingsLogic.supportsAdvanced(descriptor) {
                AIProviderAdvancedSection(model: model, draft: $draft, descriptor: descriptor)
            }
            AIConnectionTestSection(model: model, providerID: draft.id)
        }
        .onChange(of: draft) { _, _ in model.commit(&draft) }
    }
}
