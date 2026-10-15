import Foundation

public enum LayoutNode: Codable, Equatable {
    case application(String)
    case folder(id: String, name: String, apps: [String])
    public var id: String { switch self { case .application(let id): return id; case .folder(let id, _, _): return id } }
    public var folderName: String? { if case .folder(_, let name, _) = self { return name }; return nil }
    public var apps: [String] { switch self { case .application(let id): return [id]; case .folder(_, _, let apps): return apps } }
}
public enum LayoutError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}
public struct Layout: Codable, Equatable {
    public var version = 1
    public var nodes: [LayoutNode]
    public var hidden: Set<String> = []
    public init(nodes: [LayoutNode] = []) { self.nodes = nodes }
    public var applicationIDs: [String] { nodes.flatMap(\.apps) }
    public func children(of id: String) -> [String] { nodes.first { $0.id == id }?.apps ?? [] }
    public func validated() throws -> Layout {
        guard version == 1 else { throw LayoutError.invalid("不支持的布局版本，已保留原文件。") }
        let ids = nodes.map(\.id), apps = applicationIDs
        guard Set(ids).count == ids.count, Set(apps).count == apps.count, apps.allSatisfy({ !$0.isEmpty }), nodes.allSatisfy({ !$0.id.isEmpty }) else { throw LayoutError.invalid("布局包含重复或空标识，已保留原文件。") }
        return self
    }
    public mutating func merge(discovered: [String]) {
        let old = Set(applicationIDs)
        var added = Set<String>()
        for id in discovered where !old.contains(id) && !id.isEmpty && added.insert(id).inserted { nodes.append(.application(id)) }
    }
    public mutating func group(_ source: String, with target: String, name: String) throws -> String {
        guard source != target, applicationIDs.contains(source), let targetIndex = nodes.firstIndex(of: .application(target)) else { throw LayoutError.invalid("只能将两个不同应用组成文件夹。") }
        _ = targetIndex
        try remove(source)
        guard let index = nodes.firstIndex(of: .application(target)) else { throw LayoutError.invalid("找不到目标应用。") }
        let id = "folder:" + UUID().uuidString
        nodes[index] = .folder(id: id, name: name, apps: [target, source])
        return id
    }
    private mutating func remove(_ id: String) throws {
        if let i = nodes.firstIndex(where: { $0.id == id }) { nodes.remove(at: i); return }
        for i in nodes.indices {
            if case .folder(let fid, let name, var apps) = nodes[i], let j = apps.firstIndex(of: id) {
                apps.remove(at: j)
                if apps.isEmpty { nodes.remove(at: i) } else { nodes[i] = .folder(id: fid, name: name, apps: apps) }
                return
            }
        }
        throw LayoutError.invalid("找不到要移动的应用。")
    }
    public mutating func move(_ id: String, into folder: String?, before target: String?) throws {
        guard id != folder, id != target else { return }
        if let folder, children(of: folder) == [id] { return }
        guard let node = nodes.first(where: { $0.id == id }) ?? applicationIDs.first(where: { $0 == id }).map(LayoutNode.application) else { throw LayoutError.invalid("找不到移动项。") }
        if let folder {
            guard case .application = node, nodes.contains(where: { $0.id == folder && $0.folderName != nil }) else { throw LayoutError.invalid("文件夹不能嵌套。") }
        }
        try remove(id)
        if let folder, let i = nodes.firstIndex(where: { $0.id == folder }), case .folder(let fid, let name, var apps) = nodes[i] {
            let j = target.flatMap { apps.firstIndex(of: $0) } ?? apps.count
            apps.insert(id, at: j); nodes[i] = .folder(id: fid, name: name, apps: apps)
        } else {
            let i = target.flatMap { t in nodes.firstIndex { $0.id == t } } ?? nodes.count
            nodes.insert(node, at: i)
        }
    }
    public mutating func renameFolder(_ id: String, to name: String) {
        if let i = nodes.firstIndex(where: { $0.id == id }), case .folder(let fid, _, let apps) = nodes[i] { nodes[i] = .folder(id: fid, name: String(name.prefix(64)), apps: apps) }
    }
}
