import Foundation
public final class LayoutStore {
    public let url: URL
    private var blocked = false
    private var inspected = false
    public init(url: URL) { self.url = url }
    public func load() throws -> Layout {
        inspected = true
        guard FileManager.default.fileExists(atPath: url.path) else { return Layout() }
        do { return try JSONDecoder().decode(Layout.self, from: Data(contentsOf: url)).validated() }
        catch { blocked = true; throw LayoutError.invalid("布局读取失败，原文件已保留：\(url.path)\n\(error.localizedDescription)") }
    }
    /// Explicit user action only: retain the original bytes before starting a fresh layout.
    @discardableResult public func recoverByStartingNew(_ layout: Layout) throws -> URL {
        _ = try layout.validated()
        let backup = url.deletingLastPathComponent().appendingPathComponent("layout-corrupt-" + UUID().uuidString + ".json")
        try FileManager.default.copyItem(at: url, to: backup)
        blocked = false; inspected = true
        do { try save(layout) } catch { blocked = true; throw error }
        return backup
    }
    public func save(_ layout: Layout) throws {
        if !inspected { _ = try load() }
        guard !blocked else { throw LayoutError.invalid("布局保存已暂停，以保护无法读取的原文件。") }
        _ = try layout.validated()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(layout).write(to: url, options: .atomic)
    }
}
