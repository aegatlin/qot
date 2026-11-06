import Foundation
import Testing

@testable import QotKit

/// The shared sync vectors (`core/tests/vectors/sync.json`, see
/// `core/tests/sync_vectors.rs`) through the Swift binding, so `qot_ffi`
/// can't drift from the core.
@Suite struct SyncVectorTests {
    nonisolated(unsafe) static let cases: [[String: Any]] = {
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try! Data(contentsOf: repo.appending(path: "core/tests/vectors/sync.json"))
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return json["cases"] as! [[String: Any]]
    }()

    @Test func thereAreVectors() {
        #expect(Self.cases.count >= 10)
    }

    @Test(arguments: 0..<12)
    func theBindingMatchesTheVectors(_ index: Int) throws {
        guard index < Self.cases.count else { return }
        let c = Self.cases[index]
        let name = c["name"] as! String
        let notes = try (c["notes"] as! [String]).map { try Note.fromBytes(bytes: Data(base64Encoded: $0)!) }
        let state = try SyncState.fromJson(json: json(c["state"]!))
        let expect = c["expect"] as! [String: Any]

        let push = planPush(notes: notes, state: state).map {
            ["note_id": $0.noteId, "data": $0.data.base64EncodedString(), "heads": $0.heads] as NSDictionary
        }
        #expect(push == (expect["push"] as! [NSDictionary]), "\(name): push")

        let incoming = (c["incoming"] as! [[String: Any]]).map {
            Incoming(
                seq: UInt64($0["seq"] as! Int), noteId: $0["note_id"] as! String,
                data: Data(base64Encoded: $0["data"] as! String)!)
        }
        let result = Result { try applyPulled(notes: notes, state: state, incoming: incoming) }
        guard let want = expect["pulled"] as? [String: Any] else {
            #expect(throws: (any Error).self, "\(name): must fail") { try result.get() }
            return
        }
        let pulled = try result.get()
        #expect(try object(pulled.state.toJson()) == (want["state"] as! NSDictionary), "\(name): state")

        let changed = pulled.changed.sorted { $0.id() < $1.id() }.map {
            ["id": $0.id(), "content": $0.content(), "deleted": $0.isDeleted(), "heads": $0.heads()]
                as NSDictionary
        }
        #expect(changed == (want["changed"] as! [NSDictionary]), "\(name): changed")

        var saved = Dictionary(uniqueKeysWithValues: notes.map { ($0.id(), $0) })
        for note in pulled.changed { saved[note.id()] = note }
        let after = planPush(
            notes: saved.keys.sorted().map { saved[$0]! }, state: pulled.state
        ).map(\.noteId)
        #expect(after == (want["push_after"] as! [String]), "\(name): push after")
    }

    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func object(_ json: String) throws -> NSDictionary {
        try JSONSerialization.jsonObject(with: Data(json.utf8)) as! NSDictionary
    }
}
