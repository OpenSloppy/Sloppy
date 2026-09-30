import Protocols

extension CoreService {
    public func petImageGenerationStatus() async -> AgentPetImageGenerationStatusResponse {
        AgentPetImageGenerationStatusResponse(
            available: false,
            providers: [],
            message: "Agent avatars are assigned automatically from the bundled PNG bot catalog."
        )
    }
}
