import Foundation
import XCTest

final class LocalMLXResourceGateTests: XCTestCase {
    @objc func testModelSwitchesUnloadPreviousOwnerAndSerializeOperations() {
        let finished = expectation(description: "MLX resources are serialized")
        Task.detached {
            let gate = LocalMLXResourceGate()
            let probe = ResourceGateProbe()
            await gate.register(.filenames) { await probe.unloaded(.filenames) }
            await gate.register(.embeddings) { await probe.unloaded(.embeddings) }

            async let filenames: Bool = gate.withResource(.filenames) {
                await probe.perform()
                return true
            }
            async let embeddings: Bool = gate.withResource(.embeddings) {
                await probe.perform()
                return true
            }
            do {
                let completed = try await (filenames, embeddings)
                XCTAssertTrue(completed.0 && completed.1)
                let maximumActive = await probe.maximumActive
                let unloaded = await probe.unloadedOwners
                XCTAssertEqual(maximumActive, 1)
                XCTAssertEqual(unloaded.count, 1)
            } catch {
                XCTFail("Unexpected gate error: \(error)")
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
    }
}

private actor ResourceGateProbe {
    private(set) var active = 0
    private(set) var maximumActive = 0
    private(set) var unloadedOwners: [LocalMLXResourceGate.Owner] = []

    func perform() async {
        active += 1
        maximumActive = max(maximumActive, active)
        try? await Task.sleep(for: .milliseconds(20))
        active -= 1
    }

    func unloaded(_ owner: LocalMLXResourceGate.Owner) {
        unloadedOwners.append(owner)
    }
}
