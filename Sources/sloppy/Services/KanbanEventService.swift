import Foundation
import Protocols

public actor KanbanEventService {
    private var subscribers: [UUID: (projectId: String, continuation: AsyncStream<KanbanEvent>.Continuation)] = [:]

    public init() {}

    public func subscribe(projectId: String) -> AsyncStream<KanbanEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = (projectId, continuation)
            continuation.onTermination = { [id] _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    /// Core background consumers observe all projects through the same typed event stream.
    public func subscribeAll() -> AsyncStream<KanbanEvent> { subscribe(projectId: "") }

    public func push(_ event: KanbanEvent) {
        for subscriber in subscribers.values where subscriber.projectId.isEmpty || subscriber.projectId == event.projectId {
            subscriber.continuation.yield(event)
        }
    }

    private func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
