import Foundation

public enum RewriteConfigurationError: LocalizedError, Equatable {
    case defaultModelUnavailable
    case modelUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .defaultModelUnavailable:
            return "Choose a default model in Settings → Rewrite, or set a model for this instruction in Settings → Instructions."
        case .modelUnavailable(let id):
            return "The selected model (\(id)) is unavailable. Check its API key or refresh models in Settings → Rewrite. You can also choose another model or Use default for this instruction in Settings → Instructions."
        }
    }
}

/// An immutable snapshot so changing settings cannot redirect an operation already in progress.
public struct RewriteConfiguration: Equatable {
    public let instruction: Instruction
    public let model: RewriteModel
    public let systemPrompt: String

    public init(instruction: Instruction, defaultModelID: String, models: [RewriteModel],
                configuredProviders: Set<RewriteProvider>, baseSystemPrompt: String,
                corrections: [Correction] = []) throws {
        let id = instruction.modelOverrideID ?? defaultModelID
        guard let model = Self.availableModel(id, models: models, configuredProviders: configuredProviders) else {
            if let override = instruction.modelOverrideID { throw RewriteConfigurationError.modelUnavailable(override) }
            throw RewriteConfigurationError.defaultModelUnavailable
        }
        self.instruction = instruction
        self.model = model
        let composed = Instruction.composeSystemPrompt(base: baseSystemPrompt, style: instruction.systemPrompt)
        systemPrompt = Corrections.promptSection(corrections).map { composed + "\n\n" + $0 } ?? composed
    }

    /// Recheck the captured model before sending text, without resolving a different model or provider.
    public func validateAvailability(models: [RewriteModel], configuredProviders: Set<RewriteProvider>) throws {
        guard Self.availableModel(model.id, models: models, configuredProviders: configuredProviders) != nil else {
            throw RewriteConfigurationError.modelUnavailable(model.id)
        }
    }

    private static func availableModel(_ id: String, models: [RewriteModel],
                                       configuredProviders: Set<RewriteProvider>) -> RewriteModel? {
        models.first { $0.id == id && configuredProviders.contains($0.provider) }
    }
}
