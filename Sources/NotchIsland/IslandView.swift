import AppKit
import SwiftUI

@MainActor
final class IslandState: ObservableObject {
    @Published var presentation = IslandPresentation.collapsed
    @Published var items = [IslandItem]()
    @Published var selection: CGWindowID?
    @Published var guidance: String?
    @Published var screenRecording = false
    @Published var accessibility = false
    @Published var activating = false
    var expanded: Bool { presentation.expanded }
}

struct IslandView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var state: IslandState
    var pin: () -> Void
    var dismiss: () -> Void
    var activate: (IslandItem) -> Void
    var moveSelection: (Int) -> Void
    var requestPermissions: () -> Void

    private let accent = Color(red: 0.34, green: 0.91, blue: 0.87)

    var body: some View {
        Group {
            if state.expanded {
                expanded
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
            } else {
                collapsed
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.08 : 0.22), value: state.expanded)
        .preferredColorScheme(.dark)
    }

    private var collapsed: some View {
        Button(action: pin) {
            Rectangle()
                .fill(.black.opacity(0.004))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("展开菜单栏收纳")
        .accessibilityLabel("展开菜单栏收纳")
    }

    private var expanded: some View {
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
                Label(state.guidance ?? "没有需要收纳的图标", systemImage: "menubar.rectangle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 50)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(state.items) { item in itemButton(item).id(item.id) }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: 52)
                    .onChange(of: state.selection) { _, selection in
                        if let selection { proxy.scrollTo(selection, anchor: nil) }
                    }
                }
            }
            HStack(spacing: 8) {
                if state.activating {
                    Text("正在请求原生菜单…")
                } else if let guidance = state.guidance, !state.items.isEmpty {
                    Text(guidance)
                        .help(guidance)
                }
                Spacer(minLength: 0)
                if !state.screenRecording || !state.accessibility {
                    Button("授权设置", action: requestPermissions)
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        .help("屏幕录制用于读取图标，辅助功能用于打开原应用菜单")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(minHeight: 19)
        }
        .padding(.horizontal, 15)
        .padding(.top, 22)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private func itemButton(_ item: IslandItem) -> some View {
        let selected = state.selection == item.id
        return Button { activate(item) } label: {
            Group {
                if let image = item.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: min(88, max(28, image.size.width)), height: min(32, image.size.height))
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 18))
                }
            }
            .frame(minWidth: 44, minHeight: 43)
            .padding(.horizontal, 3)
            .background(.white.opacity(selected ? 0.13 : 0.055), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? accent.opacity(0.65) : .white.opacity(0.08))
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
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
