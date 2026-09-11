import Swinject

// A plain Trio Provider: BaseProvider would expose DeviceDataManager to this module.
enum AIAssistant {}

extension AIAssistant {
    final class Provider: Trio.Provider {
        let service: AIService
        let credentials: AICredentialProvider

        required init(resolver: Resolver) {
            service = resolver.resolve(AIService.self)!
            credentials = resolver.resolve(AICredentialProvider.self)!
        }
    }
}
