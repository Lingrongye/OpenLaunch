import Foundation
import Testing
@testable import OpenLaunchCore
struct LayoutTests {
 @Test func testGroupingKeepsBothAppsAndMovingOutDissolvesEmptyFolder() throws {
  var layout = Layout(nodes: [.application("a"), .application("b"), .application("c")])
  let folder = try layout.group("a", with: "b", name: "工具")
  #expect(layout.children(of: folder) == ["b", "a"])
  try layout.move("a", into: nil, before: "c")
  try layout.move("b", into: nil, before: "c")
  #expect(layout.applicationIDs == ["a", "b", "c"])
  #expect(!layout.nodes.contains { $0.id == folder })
 }
 @Test func testIncompleteScanDoesNotDeleteStoredApps() {
  var layout = Layout(nodes: [.application("missing")])
  layout.merge(discovered: ["new"])
  #expect(layout.applicationIDs == ["missing", "new"])
 }
 @Test func testCorruptionRefusesOverwrite() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("layout.json")
  try Data("broken".utf8).write(to: url)
  let store = LayoutStore(url: url)
  #expect(throws: (any Error).self) { try store.load() }
  #expect(throws: (any Error).self) { try store.save(Layout(nodes: [.application("a")])) }
  #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
 }
 @Test func testPersistenceRoundTrip() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let store = LayoutStore(url: dir.appendingPathComponent("layout.json"))
  var layout = Layout(nodes: [.application("a"), .application("b")])
  _ = try layout.group("a", with: "b", name: "工具")
  try store.save(layout)
  #expect(try store.load() == layout)
 }
}
@Test func movingOnlyChildWithinItsFolderKeepsFolder() throws {
 var layout = Layout(nodes: [.folder(id: "f", name: "工具", apps: ["a"])])
 try layout.move("a", into: "f", before: nil)
 #expect(layout.nodes == [.folder(id: "f", name: "工具", apps: ["a"])])
}
@Test func invalidFolderMoveDoesNotLoseSource() throws {
 var layout = Layout(nodes: [.application("a")])
 #expect(throws: (any Error).self) { try layout.move("a", into: "unknown", before: nil) }
 #expect(layout.applicationIDs == ["a"])
}
@Test func explicitRecoveryKeepsCorruptBackup() throws {
 let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
 defer { try? FileManager.default.removeItem(at: dir) }
 let url = dir.appendingPathComponent("layout.json"); try Data("broken".utf8).write(to: url)
 let store = LayoutStore(url: url)
 #expect(throws: (any Error).self) { try store.load() }
 let backup = try store.recoverByStartingNew(Layout(nodes: [.application("a")]))
 #expect(try String(contentsOf: backup, encoding: .utf8) == "broken")
 #expect(try store.load().applicationIDs == ["a"])
}
