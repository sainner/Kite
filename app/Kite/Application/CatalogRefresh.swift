import Foundation

/// 同一服务实例内，序号表示快照已经覆盖到哪条事件。
struct EventCursor: Equatable {
    let instance: UUID
    let sequence: UInt64

    init?(_ raw: String) {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let instance = UUID(uuidString: String(parts[0])),
              let sequence = UInt64(parts[1]) else { return nil }
        self.instance = instance
        self.sequence = sequence
    }

    func covers(_ other: EventCursor) -> Bool {
        instance == other.instance && sequence >= other.sequence
    }
}

/// 各次列表读取共用游标；重连后，旧请求即使返回也不能更新新连接的列表。
@MainActor
final class CatalogRefresh {
    private(set) var generation = UUID()
    private var cursor: EventCursor?

    @discardableResult
    func reset() -> UUID {
        generation = UUID()
        cursor = nil
        return generation
    }

    func needsRefresh(_ event: EventCursor) -> Bool {
        !(cursor?.covers(event) ?? false)
    }

    @discardableResult
    func apply(_ snapshot: EventCursor, generation: UUID, update: () throws -> Void) rethrows -> Bool {
        guard generation == self.generation else { return false }
        if let cursor, cursor.instance != snapshot.instance || cursor.covers(snapshot) { return false }
        try update()
        cursor = snapshot
        return true
    }
}
