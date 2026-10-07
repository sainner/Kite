import SwiftUI

extension EnvironmentValues {
    @Entry var sidebarStickyRegions: [SidebarStickyRegion] = []
    @Entry var sidebarStickyHeader: SidebarStickyRegion?
}

/// 只传不随滚动变化的边界描述，位置由绘制时的几何信息求出，不回写视图状态。
nonisolated struct SidebarStickyRegion: Sendable {
    let space: Namespace.ID
    var start: CGFloat = 0
    let height: CGFloat
    let topInset: CGFloat
    var enabled = true

    func naturalFrame(in proxy: GeometryProxy) -> CGRect? {
        guard let bounds = proxy.bounds(of: .named(space)) else { return nil }
        let viewportY = proxy.frame(in: .scrollView(axis: .vertical)).minY
        return CGRect(x: 0, y: viewportY + bounds.minY + start, width: bounds.width, height: height)
    }

    func offset(in proxy: GeometryProxy) -> CGFloat {
        guard enabled, let bounds = proxy.bounds(of: .named(space)), let frame = naturalFrame(in: proxy) else { return 0 }
        return min(max(0, topInset - frame.minY), max(0, bounds.height - start - height))
    }

    func renderedFrame(in proxy: GeometryProxy) -> CGRect? {
        naturalFrame(in: proxy)?.offsetBy(dx: 0, dy: offset(in: proxy))
    }
}

/// 每层只裁掉被上级吸顶标题遮住的部分；被推出固定位置的标题同样接受裁切。
struct SidebarScrollingClip: ViewModifier {
    var topOverflow: CGFloat = 0
    var movingHeader: SidebarStickyRegion?
    var additionalRegions: [SidebarStickyRegion] = []
    @Environment(\.sidebarStickyRegions) private var regions

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .padding(.top, topOverflow)
            .mask {
                GeometryReader { proxy in
                    let ancestorClipTop = (regions + additionalRegions).reduce(CGFloat.zero) { result, region in
                        guard region.offset(in: proxy) > 0, let frame = region.renderedFrame(in: proxy) else { return result }
                        return max(result, frame.maxY)
                    }
                    let viewportY = proxy.frame(in: .scrollView(axis: .vertical)).minY
                    let start: CGFloat = {
                        guard let movingHeader, let frame = movingHeader.renderedFrame(in: proxy) else {
                            return ancestorClipTop - viewportY
                        }
                        // 分组末端把标题推出吸顶位置后，露出的高度随之缩小，不能跟着上级一起放宽裁切。
                        let leaving = movingHeader.enabled && frame.minY < movingHeader.topInset
                        let clipTop = leaving ? max(ancestorClipTop, movingHeader.topInset) : ancestorClipTop
                        return topOverflow + clipTop - frame.minY
                    }()
                    let clippedStart = min(proxy.size.height, max(0, start))
                    Path(CGRect(x: 0, y: clippedStart, width: proxy.size.width, height: proxy.size.height - clippedStart))
                        .fill(.black)
                }
            }
            .padding(.top, -topOverflow)
        #else
        content
        #endif
    }
}

/// 吸顶位移留在渲染阶段，避免把每个滚动像素变成整个分组的状态更新。
struct SidebarStickyHeader: ViewModifier {
    let region: SidebarStickyRegion
    var topOverflow: CGFloat = 0

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .environment(\.sidebarStickyHeader, region)
            .modifier(SidebarScrollingClip(topOverflow: topOverflow, movingHeader: region))
            .visualEffect { effect, proxy in
                effect.offset(y: region.offset(in: proxy))
            }
        #else
        content
        #endif
    }
}

/// 标题在所属分组内固定，后代只接收稳定的祖先边界，彼此不传播逐帧状态。
struct SidebarStickySection<Header: View, Content: View>: View {
    var enabled = true
    var topInset: CGFloat = 0
    let headerHeight: CGFloat
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @Namespace private var space
    @Environment(\.sidebarStickyRegions) private var ancestors

    var body: some View {
        let region = SidebarStickyRegion(space: space, height: headerHeight, topInset: topInset, enabled: enabled)
        VStack(alignment: .leading, spacing: 0) {
            header
                .modifier(SidebarStickyHeader(region: region))
                .zIndex(1)
            content
                .environment(\.sidebarStickyRegions, ancestors + [region])
                .environment(\.sidebarStickyHeader, nil)
        }
        .coordinateSpace(name: space)
    }
}
