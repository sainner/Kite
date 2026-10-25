import SwiftUI

/// 停靠栏的一项，从前到后：布局组（添加布局、本项目的各个布局文件夹）、分割线、实例组（各实例，代理在前、工具在后，添加实例在最后）。
enum DockBandItem: Identifiable {
    case addLayout
    case layout(ProjectLayout)
    case divider
    case entry(DockEntry)
    case addInstance

    var id: String {
        switch self {
        case .addLayout: "add-layout"
        case .layout(let layout): "layout:\(layout.id)"
        case .divider: "divider"
        case .entry(let entry): entry.id
        case .addInstance: "add-instance"
        }
    }

    /// 家族格：展开、收起时自己逐帧变长变短，排版量它这一刻多长（见 DockStackLayout）。
    var flexible: Bool {
        if case .entry(let entry) = self { entry.expands } else { false }
    }

    /// 两个添加入口的名字：悬停浮出的标签（见 WorkArea.dockHoverTips）和读屏都用它。
    static let addLayoutTitle = "把台面存成布局"
    static let addInstanceTitle = "新建实例"

    /// 这一项盖住的范围，堆叠时挡住后面的格子用（见 DockStackFade）；分割线不挡。
    var outline: DockItemOutline? {
        switch self {
        case .divider: nil
        case .layout: .folder
        case .entry(let entry) where entry.expands: .capsule
        default: .circle
        }
    }
}

/// 一项的轮廓：圆形格子、家族格的胶囊、布局文件夹的圆角矩形。
enum DockItemOutline {
    case circle, capsule, folder
}

extension DockModel {
    /// 停靠栏从前到后的各项：竖排从上到下，横排从右到左。
    var bandItems: [DockBandItem] {
        [.addLayout] + layouts.map(DockBandItem.layout) + [.divider] + all.map(DockBandItem.entry) + [.addInstance]
    }
}

/// 停靠栏各项的尺寸，画停靠栏（DockBand）和算卡片落点（DockGeometry）共用，竖排横排一样。
enum DockBandMetrics {
    /// 展开的家族格最长多长：照原来的间距排开八格，停靠栏看得见的那一段（visible）没那么长时到它的全长；再多就在里面堆叠、滚动。
    static func familyLimit(visible: CGFloat) -> CGFloat {
        min(2 * DockGroup.padding + 8 * Metrics.dragBubble + 7 * Metrics.gap, visible)
    }

    /// 展开时从家族格这一刻的前端到看得见那一段的末端还剩多长，展开的家族格就最长多长（至少三格），整格留在看得见的地方，
    /// 排不下的在里面堆叠，不用再滚停靠栏去找。front 是它照原来的间距排开时离前端多远，distance 是停靠栏离前端滚了多远。
    static func familyLimit(visible: CGFloat, front: CGFloat, distance: CGFloat) -> CGFloat {
        let least = 2 * DockGroup.padding + 3 * Metrics.dragBubble + 2 * Metrics.gap
        return min(max(visible - max(front - distance, 0), least), familyLimit(visible: visible))
    }

    /// 照原来的间距排开时沿排列方向多长：分割线一点，家族格收着是胶囊、展开是面板（最长 limit），其余一格。
    static func extent(_ item: DockBandItem, expansion: [String], limit: CGFloat) -> CGFloat {
        switch item {
        case .divider: return 1
        case .entry(let entry) where entry.expands:
            guard expansion.first == entry.id else { return DockGroup.foldedLength(entry) }
            return min(DockGroup.extent(entry, path: expansion.dropFirst()), limit)
        default: return Metrics.dragBubble
        }
    }

    /// 垂直于排列方向多宽：展开的家族格多出内边距，其余一格。
    static func breadth(_ item: DockBandItem, expansion: [String]) -> CGFloat {
        guard case .entry(let entry) = item, entry.expands, expansion.first == entry.id else { return Metrics.dragBubble }
        return DockGroup.breadth(entry, path: expansion.dropFirst())
    }
}

/// 一串格子照原来的间距排开：各项离前端多远、整串多长。
nonisolated struct DockBandRun {
    let extents: [CGFloat]
    let starts: [CGFloat]
    let total: CGFloat

    init(extents: [CGFloat], gap: CGFloat) {
        var starts: [CGFloat] = [], along: CGFloat = 0
        for extent in extents {
            starts.append(along)
            along += extent + gap
        }
        self.extents = extents
        self.starts = starts
        total = max(along - gap, 0)
    }

    /// 第 index 项靠末端的那条边离整串末端多远，DockStackCurve 按它摆。
    func back(_ index: Int) -> CGFloat { total - starts[index] - extents[index] }
}

/// 堆叠的摆法：照原来的间距排开时靠末端那条边离整串末端 c 远的一项，这条边画在看得见的那一段（长 region）离末端多远。
/// 末端还有没滚到的时候，靠前端的一段照原来的间距，末端那段越往后挤得越紧，没滚到的都叠进末端，越远叠得越密、最后完全重合。
/// 从整串末端到挤的那段前端共 span 长，按 zone·(c/span)^(span/zone) 收进长 zone 的那段：末端贴着边，前端接上原来的间距、
/// 连斜率也接上。挤的程度随没滚到的多少连续变化：滚到末端时全部照原来的间距排开；排不满时靠前端；展开家族格时不挤。
/// 停靠栏（DockStackLayout）、展开的家族格排不下时（DockGroup.openSlots）和卡片落点（DockGeometry）都照它摆。
nonisolated struct DockStackCurve {
    /// 末端挤起来的那段占看得见那一段的比例，靠前端的其余部分照原来的间距。
    static let squeeze: CGFloat = 0.6

    /// 末端还有多长没滚到。
    let hidden: CGFloat
    let zone: CGFloat
    /// 挤到什么程度：0 照原来的间距排开（展开时），1 照上面的曲线挤；展开、收起途中按它在两种摆法之间插值。
    let stacking: CGFloat

    /// distance 是离前端滚了多远。
    init(total: CGFloat, region: CGFloat, distance: CGFloat, stacking: CGFloat) {
        hidden = total - region - distance
        zone = region * Self.squeeze
        self.stacking = stacking
    }

    func callAsFunction(_ c: CGFloat) -> CGFloat {
        let spread = c - hidden
        guard stacking > 0, hidden > 0, zone > 0, spread < zone else { return spread }
        let span = hidden + zone
        return spread + (zone * pow(max(c, 0) / span, span / zone) - spread) * stacking
    }

    /// 堆叠部分越靠后越透明：按这一处挤得多密（曲线的斜率，照原来的间距是 1，叠得越密越小，叠进末端的是 0）。
    func opacity(_ c: CGFloat) -> Double {
        let spread = c - hidden
        guard stacking > 0, hidden > 0, zone > 0, spread < zone else { return 1 }
        let span = hidden + zone
        let slope = Double(pow(max(c, 0) / span, span / zone - 1))
        return 1 - Double(stacking) * (1 - pow(slope, Self.fadePower))
    }

    /// 斜率换成透明度时的指数：小于 1，刚挤起来的几格淡得慢，叠进末端的才淡没。
    static let fadePower = 0.8
}

/// 停靠栏离前端滚了多远。单独放一个对象：滚动时只有读它的排版和各项的渐隐重算，外面的停靠栏不跟着重算。
@MainActor @Observable final class DockScroll {
    var distance: CGFloat = 0
}

/// 停靠栏：一条带子，宽屏竖排在台面右边（StageDockRail），紧凑布局横排在底栏（CompactDockBar）。两端是这同一个组件，方向是参数：
/// 从前到后依次是布局组、分割线、实例组（见 DockBandItem），竖排从上到下，横排从右到左（和原来的底栏一样倒着排）。
/// 格子都是圆的，间距固定。放不下时不折叠、不分页、不缩小头像：靠前端的照原来的间距，溢出的一头挤起来叠进末端（DockStackCurve），
/// 叠得越密越透明、靠前的挡住后面的（DockStackFade），滚动翻看；前端滚出去的渐隐、画箭头。家族格原地展开，后面的让开、别的格子模糊淡出，展开时不挤。
///
/// 滚动区只借它的手势、惯性和滚动范围：里面是一条和照原来间距排开一样长的空轨道，格子钉在可视区里，由 DockStackLayout
/// 按离前端滚了多远来摆，加减格子时由排版的动画过渡，家族格展开、收起时按它这一刻的长让位（见 DockStackFlexible）。格子若直接排在滚动内容里、
/// 用 visualEffect 挪成堆叠，内容变长时末端锚定会让滚动偏移跟着动画，visualEffect 拿到的却是格子的终点，两者对不上，堆叠会先散开再收回。
/// 横排时展开不滚动：前端不动，家族格往后长，比底栏长时后面超出的手动滑过去看。展开途中家族格每帧都让底栏重排，iPhone 的滚动区
/// 每次重排都把位置拉回锚点，和滚动的动画轮流生效，整串来回抖（2026-10-19 真机记录）。
struct DockBand: View {
    let axis: Axis
    /// 点了有视图的实例：宽屏放上台面（在台面上就聚焦），紧凑布局切过去。
    let show: (Pane) -> Void
    /// 一出来先滚到离前端多远：停靠栏预览摆出「滚动翻看」的样子用，平时从前端起。
    var startDistance: CGFloat = 0
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.dockOnStage) private var onStage
    @Environment(\.dockCurrentPane) private var current
    /// 滚动区沿排列方向的长，含两头让出的一圈。
    @State private var length: CGFloat = 0
    @State private var scroll = DockScroll()
    @State private var position = ScrollPosition()
    /// 紧凑布局里刚加进来的窗口：切过去时把它滚到前端，见 reveal。
    @State private var fresh: Set<Pane> = []
    /// 已按 startDistance 滚过。
    @State private var started = false

    /// 头像的脉冲和选中底伸出格子，滚动区向四周多让出这一圈，免得被截掉；排版仍按格子算。
    static var margin: CGFloat { Metrics.dragBubble * DockPulse.reach }
    /// 当前窗口在轨道上的替身，见 reveal。
    private static let currentID = "dock-current"

    var body: some View {
        let dock = area.dockModel(onStage: onStage)
        let items = dock.bandItems
        let expansion = area.dockExpansion
        let dimmed = !expansion.isEmpty
        let vertical = axis == .vertical, margin = Self.margin
        let visible = max(length - 2 * margin, 0)
        let limit = area.dockFamilyLimit ?? DockBandMetrics.familyLimit(visible: visible)
        let extents = items.map { DockBandMetrics.extent($0, expansion: expansion, limit: limit) }
        let run = DockBandRun(extents: extents, gap: Metrics.gap)
        // 轨道两头含让出的一圈，不用 contentMargins：有内边距时滚动区坐标的原点不在边上，钉住会偏一圈
        let track = max(run.total, visible) + 2 * margin, breadth = Metrics.dragBubble + 2 * margin
        let currentIndex = current.flatMap { pane in items.firstIndex { if case .entry(let entry) = $0 { holds(entry, pane) } else { false } } }
        ScrollView(axis == .vertical ? .vertical : .horizontal, showsIndicators: false) {
            Color.clear
                .frame(width: vertical ? breadth : track, height: vertical ? track : breadth)
                // 展开着时点停靠栏里别的地方收起：别的格子压暗了不接点击，点到的是这条轨道
                .contentShape(Rectangle())
                .onTapGesture { area.collapseDock() }
                .allowsHitTesting(dimmed)
                .overlay(alignment: .leading) {
                    // 横排的当前窗口：前端（右边）多出让出的那一圈，替身的右端贴着可视区右边时，格子正好贴着头像那一段的右端
                    if !vertical, let currentIndex {
                        Color.clear.frame(width: extents[currentIndex] + margin, height: 1).id(Self.currentID)
                            .padding(.leading, track - margin - run.starts[currentIndex] - extents[currentIndex])
                    }
                }
                .overlay(alignment: vertical ? .top : .leading) {
                    DockBandStack(scroll: scroll, axis: axis, stacking: !dimmed, total: run.total) {
                        // 从后往前排，靠前的压在上面
                        ForEach(Array(zip(items.indices, items)).reversed(), id: \.1.id) { index, item in
                            ZStack { self.item(item, expansion: expansion, limit: limit) }
                                .modifier(DockDimmed(dimmed: dimmed && expansion.first != item.id))
                                .modifier(DockStackFade(scroll: scroll, back: run.back(index), length: extents[index], total: run.total,
                                                        region: visible, outline: item.outline, stacking: dimmed ? 0 : 1))
                                .transition(vertical ? .scale(scale: 0.6).combined(with: .opacity) : .move(edge: .top).combined(with: .opacity))
                                .layoutValue(key: DockStackStart.self, value: run.starts[index])
                                .layoutValue(key: DockStackLength.self, value: extents[index])
                                .layoutValue(key: DockStackFlexible.self, value: item.flexible)
                        }
                    }
                    // 格子挡住后面的格子（见 DockStackFade）只在这一组里挖，不挖穿到停靠栏底下
                    .compositingGroup()
                    .environment(\.dockAxis, axis)
                    .animation(WindowMotionKind.preview.animation, value: items.map(\.id))
                    .padding(margin)
                    .frame(width: vertical ? breadth : length, height: vertical ? length : breadth)
                    // 钉在可视区：滚动挪了多少，反着挪回来
                    .visualEffect { content, proxy in
                        let frame = proxy.frame(in: .scrollView(axis: axis))
                        return content.offset(x: vertical ? 0 : -frame.minX, y: vertical ? -frame.minY : 0)
                    }
                }
        }
        // 排满时停在前端，增减格子时前端不动
        .defaultScrollAnchor(vertical ? .top : .trailing)
        // 轨道变长变短时不跟着动画，前端立刻锚住、离前端的距离不变，格子让位交给 DockStackLayout 的动画
        .transaction(value: track) { $0.animation = nil }
        .scrollPosition($position)
        .onScrollGeometryChange(for: DockScrollGeometry.self) { geometry in
            vertical
                ? DockScrollGeometry(content: geometry.contentSize.height, offset: geometry.contentOffset.y, visible: geometry.visibleRect.height)
                : DockScrollGeometry(content: geometry.contentSize.width, offset: geometry.contentOffset.x, visible: geometry.visibleRect.width)
        } action: { old, new in
            scrolled(old: old, new: new, vertical: vertical)
        }
        .hintsScrollOverflow(axis, carets: vertical ? .startOnly : .endOnly, caretsDimmed: dimmed)
        .onGeometryChange(for: CGFloat.self) { vertical ? $0.size.height : $0.size.width } action: {
            length = $0
            area.dockVisibleLength = max($0 - 2 * margin, 0)
        }
        // 新窗口加进来和切过去可能不在同一次更新里，先记下，切过去时再滚
        .onChange(of: area.layout.panes) { old, new in
            guard current != nil else { return }
            // 累加：新窗口加进来、切过去之前别的窗口又有增减，也还记着它
            fresh = fresh.union(Set(new).subtracting(old)).intersection(new)
            reveal()
        }
        .onChange(of: current) {
            reveal()
            fresh = []
        }
        .padding(-margin)
        .task(id: model.revision(for: area)) {
            try? await model.ensureRoles(in: area)
        }
    }

    /// 离前端滚了多远：竖排是离顶边，横排离右边。轨道变长变短（展开、收起、增减格子）时，横排的滚动区留着离左端的位置，
    /// 离右端的距离跟着变，整串会跳：当场滚回离右端同样远的地方，前端不动；滚不到那么远时（收起后排得下了，展开时为露出后面滚过的
    /// 那一点要退回去），排版的距离跟着收起、展开的动画挪过去，不当场跳（2026-10-19 iPhone 逐帧截图：收起第一帧整串往左跳 7.5 点）。
    /// 竖排的滚动区本来就留着离顶边的位置。
    private func scrolled(old: DockScrollGeometry, new: DockScrollGeometry, vertical: Bool) {
        let distance: CGFloat
        if vertical {
            distance = min(max(new.offset, 0), max(new.content - new.visible, 0))
        } else {
            distance = new.distance
        }
        area.dockScrollDistance = distance
        if !started, startDistance > 0, new.content > new.visible {
            started = true
            let target = min(startDistance, new.content - new.visible)
            if vertical { position.scrollTo(y: target) } else { position.scrollTo(x: new.content - new.visible - target) }
        }
        guard new.content != old.content else {
            withTransaction(Transaction(animation: nil)) { scroll.distance = distance }
            return
        }
        var settled = distance
        if !vertical {
            let target = min(max(new.content - new.visible - old.distance, 0), max(new.content - new.visible, 0))
            if abs(target - new.offset) > 0.5 { withTransaction(Transaction(animation: nil)) { position.scrollTo(x: target) } }
            settled = new.content - target - new.visible
            area.dockScrollDistance = settled
        }
        if abs(settled - scroll.distance) > 0.5 { withAnimation(.snappy) { scroll.distance = settled } }
    }

    /// 紧凑布局里新加的窗口切过去时（新建的窗口会自动切过去），把它滚到头像那一段的前端；离末端太近滚不到时停在末端，
    /// 全部照原来的间距排开，它也就尽量靠前了。
    private func reveal() {
        guard axis == .horizontal, let current, fresh.contains(current) else { return }
        fresh = []
        withAnimation(.snappy) { position.scrollTo(id: Self.currentID, anchor: .trailing) }
    }

    /// 当前窗口在这一格：它自己，或家族格里的父代理、子代理。
    private func holds(_ entry: DockEntry, _ pane: Pane) -> Bool {
        switch entry {
        case .pane(let value): value == pane
        case .family(let family): family.pane == pane || entry.contains(instance: area.dockInstanceID(pane))
        case .instance: false
        }
    }

    @ViewBuilder
    private func item(_ item: DockBandItem, expansion: [String], limit: CGFloat) -> some View {
        switch item {
        case .addLayout: AddLayoutButton()
        case .layout(let layout): DockLayoutFolder(layout: layout)
        case .divider: DockBandDivider(axis: axis)
        case .addInstance: AddWindowButton()
        case .entry(let entry):
            switch entry {
            case .pane(let pane):
                DockPaneButton(pane: pane, show: show)
            case .family:
                DockFamilyItem(entry: entry, axis: axis, expanded: expansion.first == entry.id, openness: expansion.first == entry.id ? 1 : 0,
                               limit: limit,
                               selected: current.map { holds(entry, $0) } ?? false, show: show)
            case .instance:
                DockCellButton(entry: entry, depth: 0, veiled: true, reportsHover: true, showPane: show)
            }
        }
    }
}

/// 滚动区这一刻的几何：内容多长、滚到哪、看得见多长。
private nonisolated struct DockScrollGeometry: Equatable {
    var content: CGFloat
    var offset: CGFloat
    var visible: CGFloat
    /// 横排离右端滚了多远。
    var distance: CGFloat { content - offset - visible }
}

/// 按离前端滚了多远摆一串格子：滚动时只有这里和各项的渐隐重算。
private struct DockBandStack<Content: View>: View {
    let scroll: DockScroll
    let axis: Axis
    let stacking: Bool
    let total: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        DockStackLayout(axis: axis, distance: scroll.distance, stacking: stacking ? 1 : 0, total: total) { content }
    }
}

/// 一项照原来的间距排开时离前端多远，body 按格子算好交给排版。
private nonisolated struct DockStackStart: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// 一项照原来的间距排开时多长（家族格按展开、收起的终点算）。
private nonisolated struct DockStackLength: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// 家族格展开、收起时自己逐帧变长变短，排版量它这一刻实际多长，和终点差多少，它后面的就跟着挪多少：家族格和两边的格子一起动，
/// 不靠排版另走一段动画去对上它。别的格子不量。
private nonisolated struct DockStackFlexible: LayoutValueKey {
    static let defaultValue = false
}

/// 沿排列方向排一串格子，位置按 DockStackCurve；子视图从后往前给，靠前的压在上面。位置是排版算出来的，变化时由排版的动画过渡。
/// 每项离前端多远、整串多长都用 body 算好的，和轨道、替身同一套，滚动时不再逐格量：正在淡出的格子还在 subviews 里，但不占位置
/// （留在原来那格淡出），别的格子当场带着动画让位，淡出完不会再跳一下。只有家族格量这一刻的长（见 DockStackFlexible）。
/// 挤不挤（stacking）和离前端多远（distance）由排版自己逐帧插值：展开、收起时家族格每帧都让停靠栏重排一次，这些重排不带动画，
/// 交给排版的动画的话第一帧就到终点，后面的一下挤过去或散开、整串一下挪过去。滚动时 distance 不带动画，照滚到的位置摆。
private struct DockStackLayout: Layout {
    let axis: Axis
    var distance: CGFloat
    var stacking: CGFloat
    let total: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(stacking, distance) }
        set { (stacking, distance) = (newValue.first, newValue.second) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let vertical = axis == .vertical
        let region = vertical ? bounds.height : bounds.width
        let lengths = subviews.map { subview -> CGFloat in
            guard subview[DockStackFlexible.self] else { return subview[DockStackLength.self] }
            let size = subview.sizeThatFits(.unspecified)
            return vertical ? size.height : size.width
        }
        let deltas = zip(subviews, lengths).map { subview, length in length - subview[DockStackLength.self] }
        let total = self.total + deltas.reduce(0, +)
        let curve = DockStackCurve(total: total, region: region, distance: distance, stacking: stacking)
        // 从前往后摆，前面的家族格变长变短，后面的跟着让
        var shift: CGFloat = 0
        for index in subviews.indices.reversed() {
            let subview = subviews[index], length = lengths[index], delta = deltas[index]
            let back = total - (subview[DockStackStart.self] + shift) - length
            // 正在展开、收起的家族格按前端的边摆：它往后长进挤起来的那一段时，后端的边不跟着被挤、把整格推向前端
            let edge = abs(delta) > 0.5 ? curve(back + length) - length : curve(back)
            let point = vertical ? CGPoint(x: bounds.midX, y: bounds.maxY - edge - length) : CGPoint(x: bounds.minX + edge, y: bounds.midY)
            subview.place(at: point, anchor: vertical ? .top : .leading, proposal: .unspecified)
            shift += delta
        }
    }
}

/// 堆叠部分越靠后越透明（见 DockStackCurve.opacity）。按这一项照原来的间距排开时的位置算，滚动时只有这一层跟着重算，
/// 里面的格子不重算；排得下时不读滚动。
/// 每一项先按自己的轮廓挖掉压在下面（靠后）的格子再画：叠在一起时每一处只看得到最靠前的那一格，按它自己的透明度，
/// 不再半透明叠半透明，末端几格几乎重合时也不会累加成一块亮斑，整体越往后越淡。透明度仍是每格一个数，卡片落进堆叠处
/// 按同一个数画（DockGeometry），交接前后一样。挖的只是这一组里的格子（DockBand 给整串套了 compositingGroup）；
/// 卡片自己画着头像、这一格不画的时候照样挖：卡片落进堆叠处、从那里飞出去时，同格子画着时一样只露最靠前的。
private struct DockStackFade: ViewModifier, Animatable {
    let scroll: DockScroll
    let back: CGFloat
    let length: CGFloat
    let total: CGFloat
    let region: CGFloat
    let outline: DockItemOutline?
    var stacking: CGFloat

    var animatableData: CGFloat {
        get { stacking }
        set { stacking = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(total > region ? DockStackCurve(total: total, region: region, distance: scroll.distance, stacking: stacking)
                .opacity(back + length / 2) : 1)
            .background { cutout.blendMode(.destinationOut) }
    }

    @ViewBuilder private var cutout: some View {
        switch outline {
        case .circle: Circle()
        case .capsule: Capsule()
        case .folder: RoundedRectangle(cornerRadius: DockLayoutFolder.radius, style: .continuous)
        case nil: EmptyView()
        }
    }
}

/// 布局组与实例组之间的分割线，横在带子上。
private struct DockBandDivider: View {
    let axis: Axis

    var body: some View {
        let long = Metrics.dragBubble * 0.6
        Rectangle().fill(Theme.rule)
            .frame(width: axis == .vertical ? long : 1, height: axis == .vertical ? 1 : long)
            .accessibilityHidden(true)
    }
}

/// 带子上的家族格：收着和展开是同一个 DockGroup，openness 从 0 到 1 逐帧插值，从胶囊原地拉长成一排。
/// 展开后最长 limit（见 DockBandMetrics.familyLimit），再多就在里面照停靠栏的堆叠排（DockGroup.viewport）、滚动翻看：
/// 始终套着滚动区，排得下、排不下是同一个家族格的两种状态，里面再展开一层、子代理多了越过上限时不换视图。
/// 滚动区同停靠栏只借手势和范围，家族格钉在可视区里按滚了多远自己堆叠；它若跟着滚动内容走，收起时还带着滚过的那一段。
private struct DockFamilyItem: View, Animatable {
    let entry: DockEntry
    let axis: Axis
    let expanded: Bool
    /// 展开到哪，逐帧走。
    var openness: CGFloat
    let limit: CGFloat
    var selected = false
    let show: (Pane) -> Void
    @Environment(WorkArea.self) private var area
    @State private var position = ScrollPosition()
    /// 从前端滚了多远。
    @State private var offset: CGFloat = 0

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    var body: some View {
        let path = area.dockExpansion.dropFirst()
        let vertical = axis == .vertical
        let extent = DockGroup.extent(entry, path: path), breadth = DockGroup.breadth(entry, path: path)
        let shown = min(extent, limit), scrolls = extent > shown + 0.5
        let folded = DockGroup.foldedLength(entry), t = openness
        let along = folded + (shown - folded) * t, across = Metrics.dragBubble + (breadth - Metrics.dragBubble) * t
        let range = max(extent - shown, 0)
        // 收起时边叠回去边滚回前端：前端滚出去的回到原来的间距再叠起来，不从外面飞进来
        let viewport = DockViewport(length: shown, offset: offset * min(max(t, 0), 1))
        ScrollView(axis == .vertical ? .vertical : .horizontal, showsIndicators: false) {
            Color.clear
                .frame(width: vertical ? across : along + range, height: vertical ? along + range : across)
                .overlay(alignment: vertical ? .top : .trailing) {
                    DockGroup(entry: entry, depth: 0, expanded: expanded, openness: openness, selected: selected, viewport: viewport,
                              showPane: show)
                        .frame(width: vertical ? across : along, height: vertical ? along : across, alignment: vertical ? .top : .trailing)
                        // 钉在可视区：滚动挪了多少，反着挪回来
                        .visualEffect { content, proxy in
                            let frame = proxy.frame(in: .scrollView(axis: axis))
                            return content.offset(x: vertical ? 0 : -frame.minX, y: vertical ? -frame.minY : 0)
                        }
                }
        }
        .scrollDisabled(!expanded || !scrolls)
        // 钉住的家族格不出可视区，前端滚出去的由它自己渐隐；收着时脉冲伸出格子，不截
        .scrollClipDisabled()
        .defaultScrollAnchor(vertical ? .top : .trailing)
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            vertical ? geometry.contentOffset.y : geometry.contentSize.width - geometry.contentOffset.x - geometry.visibleRect.width
        } action: { _, new in
            let value = max(new, 0)
            withTransaction(Transaction(animation: nil)) { offset = value }
            area.dockFamilyOffset = value
        }
        .frame(width: vertical ? across : along, height: vertical ? along : across)
        // 收好了、或排得下不用滚了，回到前端：下次展开从父代理排起
        .onChange(of: openness <= 0 || !scrolls) { _, rewind in
            guard rewind else { return }
            withTransaction(Transaction(animation: nil)) {
                position.scrollTo(edge: vertical ? .top : .trailing)
                offset = 0
            }
            area.dockFamilyOffset = 0
        }
    }
}
