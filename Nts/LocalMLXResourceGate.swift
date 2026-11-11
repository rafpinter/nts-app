import Foundation

actor LocalMLXResourceGate {
    enum Owner: Hashable, Sendable {
        case filenames
        case embeddings
    }

    static let shared = LocalMLXResourceGate()

    private var owner: Owner?
    private var occupied = false
    private var waiters: [(Owner, CheckedContinuation<Void, Never>)] = []
    private var unloaders: [Owner: @Sendable () async -> Void] = [:]

    func register(_ owner: Owner, unloader: @escaping @Sendable () async -> Void) {
        unloaders[owner] = unloader
    }

    func withResource<T: Sendable>(
        _ requested: Owner,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        if occupied {
            await withCheckedContinuation { waiters.append((requested, $0)) }
        } else {
            occupied = true
            await switchTo(requested)
        }

        do {
            try Task.checkCancellation()
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func switchTo(_ requested: Owner) async {
        if let owner, owner != requested {
            await unloaders[owner]?()
        }
        owner = requested
    }

    private func release() {
        if waiters.isEmpty {
            occupied = false
            return
        }
        let (nextOwner, continuation) = waiters.removeFirst()
        Task {
            await switchTo(nextOwner)
            continuation.resume()
        }
    }
}
