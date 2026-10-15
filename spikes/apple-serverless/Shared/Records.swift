import CloudKit

/// 两端共用的记录约定：提醒（触发推送）与租约（执行权的比较后更新）。容器即产品以后要用的容器，实验只用开发环境。
enum Spike {
    static let container = CKContainer(identifier: "iCloud.com.sainner.kite")
    static var database: CKDatabase { container.privateCloudDatabase }
    static let alertType = "SpikeAlert"
    static let leaseType = "SpikeLease"
    static let alertSubscription = "spike-alerts"

    static func accountStatus() async -> String {
        do {
            switch try await container.accountStatus() {
            case .available: return "可用"
            case .noAccount: return "没有登录 iCloud"
            case .restricted: return "受限"
            case .couldNotDetermine: return "无法判断"
            case .temporarilyUnavailable: return "暂时不可用"
            @unknown default: return "未知"
            }
        } catch { return "出错：\(error.localizedDescription)" }
    }
}

func milliseconds(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
