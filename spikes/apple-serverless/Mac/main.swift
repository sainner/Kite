import CloudKit
import Foundation

// Mac 端实验命令：带 iCloud 权限的 App 包，从终端或 launchd 直接运行可执行文件。
//   status                 iCloud 账号状态与用户记录 ID
//   notify <文字>          写一条提醒，iPhone 订阅了它就会收到推送；正文带发送时刻
//   lease-race <次数>      同一版本上两个写入同时比较后更新，应当一个成功、一个报版本冲突
//   lease-renew <次数>     连续按版本续约，量每次写入的耗时
//   cleanup                删掉实验写入的提醒
let args = Array(CommandLine.arguments.dropFirst())
let database = Spike.database

func record(_ id: String) -> CKRecord.ID { CKRecord.ID(recordName: id) }

/// 按版本条件保存：服务器上的版本和手里的不一致时返回版本冲突。
func conditionalSave(_ record: CKRecord) async -> Result<CKRecord, Error> {
    do {
        let (saved, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        return saved[record.recordID] ?? .failure(CKError(.internalError))
    } catch { return .failure(error) }
}

func describe(_ error: Error) -> String {
    if let error = error as? CKError, error.code == .serverRecordChanged { return "版本冲突" }
    return (error as NSError).localizedDescription
}

func lease() async throws -> CKRecord {
    do { return try await database.record(for: record("lease-test")) }
    catch let error as CKError where error.code == .unknownItem {
        let fresh = CKRecord(recordType: Spike.leaseType, recordID: record("lease-test"))
        fresh["device"] = "init"
        fresh["epoch"] = 0
        return try await database.save(fresh)
    }
}

func stats(_ values: [Int]) -> String {
    guard !values.isEmpty else { return "无" }
    let sorted = values.sorted()
    return "最少 \(sorted.first!) 毫秒，中位 \(sorted[sorted.count / 2]) 毫秒，最多 \(sorted.last!) 毫秒"
}

switch args.first {
case "status":
    print("iCloud 账号：\(await Spike.accountStatus())")
    do { print("用户记录：\(try await Spike.container.userRecordID().recordName)") }
    catch { print("读用户记录失败：\(describe(error))") }
case "notify":
    let text = args.dropFirst().joined(separator: " ")
    let alert = CKRecord(recordType: Spike.alertType)
    let sent = Date()
    alert["title"] = "Kite 实验提醒"
    alert["body"] = "\(text.isEmpty ? "测试" : text)（发送于 \(sent.formatted(date: .omitted, time: .standard))）"
    alert["sentAt"] = sent
    do {
        _ = try await database.save(alert)
        print("已写入提醒，用时 \(milliseconds(since: sent)) 毫秒")
    } catch { print("写入失败：\(describe(error))") }
case "lease-race":
    let rounds = Int(args.dropFirst().first ?? "5") ?? 5
    var wins: [String: Int] = ["A": 0, "B": 0, "都成功": 0, "都失败": 0]
    var latencies: [Int] = []
    for round in 1...rounds {
        do {
            let base = try await lease()
            let epoch = (base["epoch"] as? Int ?? 0) + 1
            // 两个写入都从同一个版本出发，模拟两台设备同时抢执行权。
            func attempt(_ device: String) async -> (String, Result<CKRecord, Error>, Int) {
                let copy = base.copy() as! CKRecord
                copy["device"] = device
                copy["epoch"] = epoch
                let start = Date()
                let result = await conditionalSave(copy)
                return (device, result, milliseconds(since: start))
            }
            async let a = attempt("A")
            async let b = attempt("B")
            let results = await [a, b]
            var succeeded: [String] = []
            var parts: [String] = []
            for (device, result, elapsed) in results {
                latencies.append(elapsed)
                switch result {
                case .success: succeeded.append(device); parts.append("\(device)：成功（\(elapsed) 毫秒）")
                case .failure(let error): parts.append("\(device)：\(describe(error))（\(elapsed) 毫秒）")
                }
            }
            let detail = parts.joined(separator: "，")
            print("第 \(round) 轮 epoch \(epoch)：\(detail)")
            switch succeeded.count {
            case 1: wins[succeeded[0], default: 0] += 1
            case 2: wins["都成功", default: 0] += 1
            default: wins["都失败", default: 0] += 1
            }
        } catch { print("第 \(round) 轮读取租约失败：\(describe(error))") }
    }
    print("结果：A 胜 \(wins["A"]!)，B 胜 \(wins["B"]!)，都成功 \(wins["都成功"]!)，都失败 \(wins["都失败"]!)；写入耗时 \(stats(latencies))")
case "lease-renew":
    let rounds = Int(args.dropFirst().first ?? "10") ?? 10
    var latencies: [Int] = []
    do {
        var current = try await lease()
        for _ in 1...rounds {
            let copy = current.copy() as! CKRecord
            copy["device"] = Host.current().localizedName ?? "mac"
            copy["epoch"] = (current["epoch"] as? Int ?? 0) + 1
            let start = Date()
            switch await conditionalSave(copy) {
            case .success(let saved): current = saved; latencies.append(milliseconds(since: start))
            case .failure(let error): print("续约失败：\(describe(error))")
            }
        }
        print("续约 \(latencies.count) 次：\(stats(latencies))")
    } catch { print("读取租约失败：\(describe(error))") }
case "cleanup":
    do {
        let (matches, _) = try await database.records(matching: CKQuery(recordType: Spike.alertType, predicate: NSPredicate(value: true)))
        let ids = matches.map(\.0)
        _ = try await database.modifyRecords(saving: [], deleting: ids)
        print("删掉 \(ids.count) 条提醒")
    } catch { print("清理失败：\(describe(error))") }
default:
    print("用法：KiteSpikeMac status | notify <文字> | lease-race [次数] | lease-renew [次数] | cleanup")
}
