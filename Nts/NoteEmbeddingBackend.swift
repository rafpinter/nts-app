import Foundation

protocol NoteEmbeddingBackend: Sendable {
    func download(progress: @escaping @Sendable (Double) -> Void) async throws
    func isAvailable() async -> Bool
    func embed(_ text: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [Float]
    func unload() async
}
