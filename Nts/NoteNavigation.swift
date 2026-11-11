import Foundation

enum NoteNavigation {
    enum Direction {
        case previous, next
    }

    static func target(in notes: [URL], selected: URL?, direction: Direction) -> URL? {
        guard !notes.isEmpty else { return nil }
        guard let selected, let index = notes.firstIndex(of: selected) else { return notes.first }
        let target = index + (direction == .previous ? -1 : 1)
        return notes.indices.contains(target) ? notes[target] : nil
    }
}
