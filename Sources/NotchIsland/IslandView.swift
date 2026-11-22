import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class IslandState {
    var presentation = IslandPresentation.collapsed
    var layoutMode = IslandLayoutMode.wrap
    var items = [IslandItem]()
    var selection: CGWindowID?
    var guidance: String?
    var screenRecording = false
    var accessibility = false
    var activating = false
    var isLoading = false
    var notchHeight: CGFloat = 32
    var neckWidth: CGFloat = 187
    var iconsHeight: CGFloat = IslandShellLayout.singleRowIconsHeight
    var needsVerticalScroll = false
    var expanded: Bool { presentation.expanded }
}

private struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        return computeLayout(maxWidth: maxWidth, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(maxWidth: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let origin = result.origins[index]
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          proposal: ProposedViewSize(result.sizes[index]))
        }
    }

    private func computeLayout(maxWidth: CGFloat, subviews: Subviews) -> (origins: [CGPoint], sizes: [CGSize], size: CGSize) {
        var origins = [CGPoint]()
        var sizes = [CGSize]()
        origins.reserveCapacity(subviews.count)
        sizes.reserveCapacity(subviews.count)
        let limit = maxWidth.isFinite ? max(1, maxWidth) : .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + horizontalSpacing + size.width > limit {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            if x > 0 { x += horizontalSpacing }
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x)
        }
        return (origins, sizes, CGSize(width: totalWidth, height: y + rowHeight))
    }
}

struct IslandView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: IslandState
    var pin: () -> Void
    var dismiss: () -> Void
    var activate: (IslandItem) -> Void
    var moveSelection: (Int) -> Void
    var requestPermissions: () -> Void

    @State private var hoveredItemID: CGWindowID?

    private let accent = Color(red: 0.34, green: 0.91, blue: 0.87)

    private var hoveredItem: IslandItem? {
        guard let hoveredItemID else { return nil }
        return state.items.first { $0.id == hoveredItemID }
    }

    private var selectedItem: IslandItem? {
        guard let selection = state.selection else { return nil }
        return state.items.first { $0.id == selection }
    }

    private var permissionButtonTitle: String? {
        switch (state.screenRecording, state.accessibility) {
        case (true, true): nil
        case (false, false): "授权设置 (2)"
        case (false, true): "授权屏幕录制"
        case (true, false): "授权辅助功能"
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if state.expanded {
                expanded
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
            } else {
                collapsed
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: reduceMotion ? 0.08 : 0.18), value: state.expanded)
        .onChange(of: state.expanded) { _, isExpanded in
            if !isExpanded { hoveredItemID = nil }
        }
        .preferredColorScheme(.dark)
    }

    private var collapsed: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.allowsHitTesting(false)
                Button(action: pin) {
                    Rectangle()
                        .fill(.black.opacity(0.01))
                        .frame(width: state.neckWidth,
                               height: state.notchHeight + IslandShellLayout.collapsedHitExtension)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("展开菜单栏收纳")
                .accessibilityLabel("展开菜单栏收纳")
                Color.clear.allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
            .frame(height: state.notchHeight + IslandShellLayout.collapsedHitExtension)
            Spacer(minLength: 0)
        }
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            // Top notch band: center neck catches hover/click/right-click,
            // while left/right wings remain fully transparent (alpha == 0) so adjacent menu bar items stay clickable.
            HStack(spacing: 0) {
                Color.clear.allowsHitTesting(false)
                notchNeckTarget
                    .frame(width: state.neckWidth, height: state.notchHeight)
                Color.clear.allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
            .frame(height: state.notchHeight)

            expandedBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var notchNeckTarget: some View {
        if state.presentation == .preview {
            Button(action: pin) {
                Rectangle()
                    .fill(.black.opacity(0.01))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("固定面板")
        } else {
            Rectangle()
                .fill(.black.opacity(0.01))
                .contentShape(Rectangle())
        }
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("菜单栏收纳")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if state.items.count > 1 {
                    smallButton("chevron.left", "上一个图标") { moveSelection(-1) }
                    smallButton("chevron.right", "下一个图标") { moveSelection(1) }
                }
                if state.presentation == .preview {
                    smallButton("pin", "固定面板", action: pin)
                }
                smallButton("chevron.up", "收起面板", action: dismiss)
            }
            if state.items.isEmpty {
                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: IslandShellLayout.singleRowIconsHeight)
                } else {
                    Label(state.guidance ?? "没有需要收纳的图标", systemImage: "menubar.rectangle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: IslandShellLayout.singleRowIconsHeight)
                }
            } else {
                itemsContainer
            }
            HStack(spacing: 8) {
                if state.activating {
                    Text("正在请求原生菜单…")
                } else if let hovered = hoveredItem {
                    Text(hovered.name)
                        .foregroundStyle(.primary.opacity(0.85))
                } else if let guidance = state.guidance, !state.items.isEmpty {
                    Text(guidance)
                        .help(guidance)
                } else if state.presentation == .pinned, let selected = selectedItem {
                    Text(selected.name)
                }
                Spacer(minLength: 0)
                if let permissionTitle = permissionButtonTitle {
                    Button(permissionTitle, action: requestPermissions)
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        .help("屏幕录制用于读取图标，辅助功能用于打开原应用菜单")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(minHeight: 22)
        }
        .padding(.horizontal, 15)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .background {
            if state.presentation == .preview {
                Button(action: pin) {
                    Rectangle().fill(.black.opacity(0.012)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("固定面板")
            }
        }
    }

    @ViewBuilder
    private var itemsContainer: some View {
        switch state.layoutMode {
        case .wrap:
            if state.needsVerticalScroll {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        wrapFlowContent
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: state.iconsHeight)
                    .onChange(of: state.selection) { _, selection in
                        if let selection { proxy.scrollTo(selection, anchor: nil) }
                    }
                }
            } else {
                wrapFlowContent
                    .frame(height: state.iconsHeight, alignment: .topLeading)
            }
        case .scroll:
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: IslandShellLayout.itemSpacing) {
                        ForEach(state.items) { item in itemButton(item).id(item.id) }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.automatic)
                .frame(height: IslandShellLayout.singleRowIconsHeight)
                .onChange(of: state.selection) { _, selection in
                    if let selection { proxy.scrollTo(selection, anchor: nil) }
                }
            }
        }
    }

    private var wrapFlowContent: some View {
        FlowLayout(horizontalSpacing: IslandShellLayout.itemSpacing,
                   verticalSpacing: IslandShellLayout.rowSpacing) {
            ForEach(state.items) { item in itemButton(item).id(item.id) }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func itemButton(_ item: IslandItem) -> some View {
        let keyboardSelected = state.presentation == .pinned && state.selection == item.id
        let isHovered = hoveredItemID == item.id
        return Button { activate(item) } label: {
            Group {
                if let image = item.image {
                    if item.isAppIconFallback {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: min(88, max(28, image.size.width)),
                                   height: min(32, max(18, image.size.height)))
                    }
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 18))
                }
            }
            .frame(minWidth: 44, minHeight: 43)
            .padding(.horizontal, 3)
            .background(.white.opacity(isHovered ? 0.16 : keyboardSelected ? 0.13 : 0.055),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(keyboardSelected ? accent.opacity(0.72) : isHovered ? .white.opacity(0.28) : .white.opacity(0.08))
                    .allowsHitTesting(false)
            }
            .scaleEffect(isHovered && !reduceMotion ? 1.04 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredItemID = item.id
            } else if hoveredItemID == item.id {
                hoveredItemID = nil
            }
        }
        .help(item.name)
        .accessibilityLabel(item.name)
        .accessibilityHint("打开原应用菜单")
        .disabled(state.activating)
    }

    private func smallButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 28, height: 25)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}
