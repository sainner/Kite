import CoreImage.CIFilterBuiltins
import SwiftUI

/// Kite 账号页：宽处分两栏，左栏是账号与计价表，右栏是用量；右栏放不下半年的热力图时排成一栏。
struct AccountSettingsPage: View {
    /// 量到宽度之前为 nil，先排成一栏。
    @State private var columns: Bool?

    var body: some View {
        ScrollView {
            AccountPageLayout(columns: columns ?? false) {
                KiteAccountSection()
                AccountUsageOverview()
                TokenPriceSection()
            }
            .padding(CardMetrics.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 刚打开时直接按量到的宽度排，之后改变栏数才带动画。
        .onGeometryChange(for: Bool.self) { AccountPageLayout.fitsColumns(width: $0.size.width - CardMetrics.inset * 2) } action: { fits in
            if columns == nil { columns = fits } else { withAnimation(.snappy) { columns = fits } }
        }
        .dotClip()
    }
}

/// 依次放账号、用量、计价表三块。两栏时左栏宽度固定，账号下面接计价表，表格放不下时横向滚动；右栏的用量最宽到一整年（53 周）的热力图，
/// 柱状图与热力图左右对齐。一栏时依次排下来，宽度同样以一整年为限。
/// 自己排而不是在 HStack 与 VStack 之间切换：两种排法下各块的身份不变，二维码这类状态不丢，切换时位置能连续过渡。
private struct AccountPageLayout: Layout {
    let columns: Bool

    private static let side = DotMetrics.module * 26
    private static let gap = DotMetrics.module * 2
    /// 一整年的热力图，加上两边与卡片标签对齐的留白。
    private static let usage = DotMetrics.pitch * 53 + 24
    private static let spacing: CGFloat = 28

    /// 右栏至少放得下半年的热力图才分两栏。
    static func fitsColumns(width: CGFloat) -> Bool { width >= side + gap + DotMetrics.pitch * 26 + 24 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frames(width: proposal.width ?? Self.usage, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews).frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        func height(_ index: Int, _ width: CGFloat) -> CGFloat {
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        guard subviews.count == 3 else { return ([], .zero) }
        if columns {
            let right = max(0, min(Self.usage, width - Self.side - Self.gap))
            let account = height(0, Self.side), usage = height(1, right), prices = height(2, Self.side)
            return ([CGRect(x: 0, y: 0, width: Self.side, height: account),
                     CGRect(x: Self.side + Self.gap, y: 0, width: right, height: usage),
                     CGRect(x: 0, y: account + Self.spacing, width: Self.side, height: prices)],
                    CGSize(width: Self.side + Self.gap + right, height: max(account + Self.spacing + prices, usage)))
        }
        let column = min(Self.usage, width)
        var y: CGFloat = 0
        let frames = (0..<3).map { index in
            let frame = CGRect(x: 0, y: y, width: column, height: height(index, column))
            y = frame.maxY + Self.spacing
            return frame
        }
        return (frames, CGSize(width: column, height: y - Self.spacing))
    }
}

/// Kite 账号：当前登录的邮箱、设备概况与退出登录，右侧是让新设备扫码登录的按钮。邮箱过长时省略中间。
struct KiteAccountSection: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @State private var working = false

    var body: some View {
        let devices = model.account.devices.filter(\.joined)
        CardSection("账号") {
            HStack(spacing: 12) {
                SidebarAvatar()
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.account.user?.email ?? "未登录").font(Theme.title)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if model.account.signedIn {
                        Text("\(devices.count) 台设备 · \(devices.filter(\.online).count) 台在线")
                            .font(Theme.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
                DeviceInvitationButton()
            }
            .padding(.vertical, 8)
            Button("退出登录", role: .destructive) {
                guard !working else { return }
                error = nil
                working = true
                Task {
                    defer { working = false }
                    do {
                        try await model.account.signOut()
                        model.clearAccountConnections()
                        model.sidebarSection = .workspaces
                    } catch { self.error = error.localizedDescription }
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.danger)
            .disabled(!model.account.signedIn)
            if let error { Text(error).foregroundStyle(Theme.danger) }
            // 账号层的错误只在这一页写全，侧栏用户栏的提示点开到这里。
            if let error = model.account.error { Text(error).foregroundStyle(Theme.danger).textSelection(.enabled) }
        }
        .disabled(working)
    }
}

/// Kite 账号下所有工作机、所有订阅账号的用量合计，画在页面的点阵上。计量单位在这里切换，各账号窗口跟着用。
struct AccountUsageOverview: View {
    @Environment(AppModel.self) private var model
    @AppStorage(UsageUnit.storageKey) private var unit = UsageUnit.tokens

    private static let spacing = DotMetrics.module * 2
    private static let figureColumns = [GridItem(.adaptive(minimum: DotMetrics.module * 11), spacing: spacing, alignment: .topLeading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CardLabel("用量")
                Spacer(minLength: 0)
                Picker("计量单位", selection: $unit) {
                    ForEach(UsageUnit.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().clickPointer()
            }
            Group {
                if let usage = model.totalUsage {
                    VStack(alignment: .leading, spacing: Self.spacing) {
                        TimelineView(.everyMinute) { context in
                            LazyVGrid(columns: Self.figureColumns, alignment: .leading, spacing: Self.spacing) {
                                usage.figures(unit: unit, today: Calendar.current.startOfDay(for: context.date))
                            }
                        }
                        AccountUsageSection(usage: usage, stale: false)
                    }
                } else {
                    Text("还没有用量记录，工作机连上并读取账号后显示").font(Theme.secondary).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            CardNote("合计各台工作机上订阅账号的本机会话记录。金额按工作机内置的 API 标准价折算，订阅本身不按 token 计费。")
        }
    }
}

/// Kite 模型目录里各模型的单价，供参考；从一台在线工作机读取，工作机折算用量金额用的是同一张表。
/// 两家厂商排在同一张表里，各占一组；放不下时横向滚动。
struct TokenPriceSection: View {
    @Environment(AppModel.self) private var model
    @State private var table: TokenPriceTable?
    @State private var error: String?

    /// Claude 的缓存写入分 5 分钟与 1 小时两档，前者和 OpenAI 的缓存写入同列。
    private static let columns: [(title: String, value: (TokenPriceTable.Rates) -> Double?)] = [
        ("输入", \.input), ("缓存命中", \.cacheRead), ("缓存写入", \.cacheWrite), ("1 小时写入", \.cacheWrite1h), ("输出", \.output),
    ]

    var body: some View {
        let connection = model.availableWorkers.first
        CardSection("计价表", note: table.map {
            "美元 / 百万 token，取自 Claude 与 OpenAI 官方 API 价格页的标准档，\($0.checked) 核对。Claude 的「缓存写入」是 5 分钟缓存。"
        }) {
            if let table {
                ScrollView(.horizontal) { grid(table).padding(.vertical, 10) }
            } else if let error {
                Text(error).foregroundStyle(Theme.danger)
            } else {
                Text(connection == nil ? "连接工作机后显示" : "正在读取…").foregroundStyle(.secondary)
            }
        }
        .task(id: connection?.id) {
            guard let connection else { return }
            do {
                table = try await connection.client.request("/token-prices", as: TokenPriceTable.self)
                error = nil
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    private func grid(_ table: TokenPriceTable) -> some View {
        let providers = table.models.map(\.provider).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            // Grid 只认直接放进来的 GridRow，颜色加在单元格上，不套在行外面。
            GridRow {
                Text("模型").foregroundStyle(.secondary)
                ForEach(Self.columns, id: \.title) { Text($0.title).foregroundStyle(.secondary).gridColumnAlignment(.trailing) }
            }
            ForEach(providers, id: \.self) { provider in
                GridRow {
                    Text(provider).font(Theme.caption.weight(.semibold)).padding(.top, 6).gridCellColumns(Self.columns.count + 1)
                }
                ForEach(table.models.filter { $0.provider == provider }) { price in
                    row(price.model, rates: price.rates)
                    if let long = price.long {
                        // 长提示档写成「haiku-5.5 (>100k)」。
                        row("\(price.model) (>\(Int(long.above / 1000))k)", rates: long.rates, tint: .secondary)
                    }
                }
            }
        }
        .font(Theme.caption)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }

    private func row(_ title: String, rates: TokenPriceTable.Rates, tint: Color = .primary) -> some View {
        GridRow {
            Text(title).foregroundStyle(tint)
            ForEach(Self.columns, id: \.title) { column in
                Text(column.value(rates).map { $0.formatted(.number.precision(.fractionLength(2...3))) } ?? "—").foregroundStyle(tint)
            }
        }
    }
}

/// 账号行右侧的图标按钮：点开生成一次性登录二维码，新设备扫码即可登录。二维码过期前再点开仍是同一张。
struct DeviceInvitationButton: View {
    @Environment(AppModel.self) private var model
    @State private var presented = false
    @State private var invitation: (image: Image?, expiresAt: Date)?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Button { presented = true } label: {
            PaneButtonLabel("新设备扫码登录", systemImage: "qrcode")
        }
        .buttonStyle(PaneButtonStyle())
        .fixedSize()
        .help("新设备扫码登录")
        .disabled(!model.account.signedIn)
        .popover(isPresented: $presented) {
            content
                .padding(CardMetrics.sheetInset)
                .frame(width: 248)
                .presentationCompactAdaptation(.popover)
                .onAppear { if invitation.map({ $0.expiresAt <= .now }) ?? true { generate() } }
        }
    }

    private var content: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 12) {
                Text("新设备扫码登录").font(Theme.title)
                if let invitation, context.date < invitation.expiresAt, let image = invitation.image {
                    image.resizable().interpolation(.none).scaledToFit().frame(width: 200, height: 200)
                    Text("用新设备扫描即可登录你的账号。\(invitation.expiresAt.formatted(date: .omitted, time: .shortened)) 前有效，只能使用一次。")
                        .font(Theme.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                } else if working {
                    ProgressView().frame(width: 200, height: 200)
                } else {
                    Text(error ?? "二维码已过期").font(Theme.secondary)
                        .foregroundStyle(error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.danger))
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button("重新生成", action: generate)
                }
            }
        }
    }

    private func generate() {
        guard !working else { return }
        error = nil
        working = true
        Task {
            defer { working = false }
            do {
                let url = try await model.account.invitation()
                invitation = (qrCode(url.absoluteString), Date().addingTimeInterval(5 * 60))
            } catch { self.error = error.localizedDescription }
        }
    }

    private func qrCode(_ text: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return Image(decorative: image, scale: 1)
    }
}
