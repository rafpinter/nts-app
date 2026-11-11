import Darwin
import Foundation
import MLX

struct EvaluationCase: Codable, Sendable {
    let name: String
    let text: String
    static let fixtures = [
        Self(name: "bread-en", text: "How to bake sourdough bread: flour, water, starter and a slow overnight rise."),
        Self(name: "bread-paraphrase", text: "Making sourdough requires flour, water and a starter. Let the dough ferment overnight before baking."),
        Self(name: "bread-pt", text: "Como fazer pão de fermentação natural: farinha, água e fermento. Deixe a massa crescer durante a noite antes de assar."),
        Self(name: "database-en", text: "Recover a SQLite database by checking transactions, WAL files and migration integrity."),
        Self(name: "database-pt", text: "Recuperar um banco de dados SQLite verificando transações, arquivos WAL e a integridade das migrações."),
        Self(name: "unicode", text: "# Café 👩‍💻\n日本語 — مرحبا\n\n- [ ] Preserve Unicode and Markdown.\n"),
        Self(name: "late-a", text: String(repeating: "A daily journal records ordinary errands and appointments. ", count: 150) + String(repeating: "Sourdough bread needs flour, water, starter and overnight fermentation. ", count: 35)),
        Self(name: "late-b", text: String(repeating: "A daily journal records ordinary errands and appointments. ", count: 150) + String(repeating: "SQLite recovery needs transactions, WAL files and database migration integrity. ", count: 35)),
    ]
}
struct EvaluationResult: Codable {
    let fixture: EvaluationCase
    let embedding: NoteEmbedding
    let seconds: [Double]
}
struct Memory: Codable {
    let activeMiB: Double
    let cacheMiB: Double
    let peakMLXMiB: Double
    let peakRSSMiB: Double
    static func snapshot() -> Memory {
        let gpu = GPU.snapshot()
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let mib = 1024.0 * 1024.0
        return Memory(activeMiB: Double(gpu.activeMemory) / mib, cacheMiB: Double(gpu.cacheMemory) / mib,
                      peakMLXMiB: Double(gpu.peakMemory) / mib, peakRSSMiB: Double(usage.ru_maxrss) / mib)
    }
}
struct Report: Encodable {
    let configuration: EmbeddingModelConfiguration
    let configurationHash: String
    let artifactDirectory: String
    let artifactBytes: Int
    let loadSeconds: Double
    let reloadSeconds: Double
    let results: [EvaluationResult]
    let scores: [String: Double]
    let loadedMemory: Memory
    let evaluatedMemory: Memory
    let unloadedMemory: Memory
    let machine: String
}

@main
struct LocalEmbeddingEval {
    static func main() async {
        do {
            if CommandLine.arguments.contains("--help") {
                print("Usage: sh Developer/LocalEmbeddingEval/run.sh [--download] [--repeats 1...5] [--output path] [--model-directory path]\nSynthetic fixtures only. Downloads require --download; otherwise inference is local-only.")
                return
            }
            #if !arch(arm64)
            throw EvaluationFailure("The MLX evaluator requires Apple Silicon")
            #endif
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            let config = EmbeddingModelConfiguration()
            print("Model: \(config.modelID) @ \(config.revision)")
            let directory = try await prepareArtifact(config, download: options.allowDownload, directory: options.directory)
            let encoder: any TextEmbedding = MLXNoteEmbedder(configuration: config, directory: directory)
            let start = Date()
            try await encoder.load()
            let loadSeconds = Date().timeIntervalSince(start)
            let loaded = Memory.snapshot()
            var results: [EvaluationResult] = []
            do {
                for fixture in EvaluationCase.fixtures {
                    var first: NoteEmbedding?
                    var timings: [Double] = []
                    for _ in 0..<options.repeats {
                        let start = Date()
                        let embedding = try await encoder.embed(fixture.text)
                        timings.append(Date().timeIntervalSince(start))
                        if let first {
                            guard cosine(first.vector, embedding.vector) > 0.99999 else {
                                throw EvaluationFailure("Repeated embeddings changed unexpectedly")
                            }
                        } else { first = embedding }
                    }
                    guard let first else { throw EvaluationFailure("No evaluation result") }
                    guard first.chunks.reduce(0, { $0 + $1.contentTokens }) == first.contentIDs.count else {
                        throw EvaluationFailure("Chunk coverage lost input tokens")
                    }
                    results.append(EvaluationResult(fixture: fixture, embedding: first, seconds: timings))
                    print("\(fixture.name): \(first.contentIDs.count) content tokens, \(first.chunks.count) chunks, seconds=\(timings)")
                }
                do { _ = try await encoder.embed(" \n\t"); throw EvaluationFailure("Empty input was not rejected") }
                catch let error as EvaluationFailure where error.localizedDescription.contains("Empty notes") { }
            } catch { await encoder.unload(); throw error }
            let scores = [
                "bread-paraphrase": cosine(results[0].embedding.vector, results[1].embedding.vector),
                "bread-cross-language": cosine(results[0].embedding.vector, results[2].embedding.vector),
                "bread-unrelated": cosine(results[0].embedding.vector, results[3].embedding.vector),
                "database-cross-language": cosine(results[3].embedding.vector, results[4].embedding.vector),
                "long-note-tail-difference": cosine(results[6].embedding.vector, results[7].embedding.vector),
            ]
            guard scores["bread-paraphrase"]! > scores["bread-unrelated"]!,
                  scores["bread-cross-language"]! > scores["bread-unrelated"]!,
                  scores["long-note-tail-difference"]! < 0.9999 else {
                throw EvaluationFailure("Semantic fixtures failed; do not accept this model/backend")
            }
            let evaluated = Memory.snapshot()
            await encoder.unload()
            let unloaded = Memory.snapshot()
            let reload = Date()
            try await encoder.load()
            let reloadSeconds = Date().timeIntervalSince(reload)
            let reloaded = try await encoder.embed(EvaluationCase.fixtures[0].text)
            guard cosine(reloaded.vector, results[0].embedding.vector) > 0.99999 else {
                throw EvaluationFailure("Reload changed the vector")
            }
            await encoder.unload()
            let artifactBytes = try config.requiredFiles.reduce(0) { total, name in
                let value = try directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey])
                return total + (value.fileSize ?? 0)
            }
            let report = Report(configuration: config, configurationHash: try config.fingerprint,
                                artifactDirectory: directory.path, artifactBytes: artifactBytes,
                                loadSeconds: loadSeconds, reloadSeconds: reloadSeconds, results: results, scores: scores,
                                loadedMemory: loaded, evaluatedMemory: evaluated, unloadedMemory: unloaded,
                                machine: ProcessInfo.processInfo.operatingSystemVersionString)
            let json = JSONEncoder()
            json.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: options.output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try json.encode(report).write(to: options.output, options: .atomic)
            print("Scores: \(scores)\nLoad seconds: \(loadSeconds); reload: \(reloadSeconds)")
            print("Peak RSS MiB: \(evaluated.peakRSSMiB); MLX peak MiB: \(evaluated.peakMLXMiB); artifact bytes: \(artifactBytes)")
            print("Report: \(options.output.path)")
        } catch {
            FileHandle.standardError.write(Data("Embedding evaluation failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
    }
}
