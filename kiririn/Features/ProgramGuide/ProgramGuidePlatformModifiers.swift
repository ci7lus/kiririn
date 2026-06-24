import SwiftUI

#if os(iOS)
    private struct ProgramGuideFloatingActionButton: View {
        let systemImage: String
        let help: String
        let namespace: Namespace.ID
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                let icon = Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .frame(width: 52, height: 52)
                if #available(iOS 26, *) {
                    icon
                        .glassEffect(.regular.interactive())
                        .contentShape(.circle)
                        .glassEffectUnion(
                            id: "ProgramGuideFloatingActionButton", namespace: namespace)
                } else {
                    icon
                        .background(.ultraThinMaterial, in: .circle)
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                }
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }
#endif

#if os(macOS)
    private struct ProgramGuideTitleModifier: ViewModifier {
        @Environment(\.isTabActive) private var isTabActive

        func body(content: Content) -> some View {
            content.navigationTitle(isTabActive ? "番組表" : "")
        }
    }

    private struct ProgramGuideSearchToolbarModifier: ViewModifier {
        let isSearchSheetPresented: Binding<Bool>
        @Environment(\.isTabActive) private var isTabActive

        func body(content: Content) -> some View {
            content.toolbar {
                if isTabActive {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            isSearchSheetPresented.wrappedValue = true
                        } label: {
                            Label("番組検索", systemImage: "magnifyingglass")
                        }
                        .help("番組を検索")
                    }
                }
            }
        }
    }
#endif

extension View {
    @ViewBuilder
    func programGuideTitle() -> some View {
        #if os(iOS)
            self.navigationBarTitleDisplayMode(.inline)
        #else
            self.modifier(ProgramGuideTitleModifier())
        #endif
    }

    @ViewBuilder
    func programGuideRefreshable(onReload: @escaping () async -> Void) -> some View {
        #if os(macOS)
            self.refreshable {
                await onReload()
            }
        #else
            self
        #endif
    }

    @ViewBuilder
    func programGuidePlatformActions(
        isSearchSheetPresented: Binding<Bool>,
        timelineOffsetHours: Binding<Int>,
        onScrollToNow: @escaping () -> Void,
        glassNamespace: Namespace.ID
    ) -> some View {
        #if os(iOS)
            self.overlay(alignment: .bottomTrailing) {
                let buttonsSpacing = if #available(iOS 26, *) { 0.0 } else { 12.0 }
                let buttons = VStack(spacing: buttonsSpacing) {
                    ProgramGuideFloatingActionButton(
                        systemImage: "clock.arrow.circlepath",
                        help: "現在の時刻にスクロール",
                        namespace: glassNamespace
                    ) {
                        if timelineOffsetHours.wrappedValue != 0 {
                            timelineOffsetHours.wrappedValue = 0
                        }
                        onScrollToNow()
                    }

                    ProgramGuideFloatingActionButton(
                        systemImage: "magnifyingglass",
                        help: "番組を検索",
                        namespace: glassNamespace
                    ) {
                        isSearchSheetPresented.wrappedValue = true
                    }
                }
                .padding(.trailing, 20)
                .padding(.bottom, 24)

                if #available(iOS 26, *) {
                    GlassEffectContainer { buttons }
                } else {
                    buttons
                }
            }
        #elseif os(macOS)
            self.modifier(
                ProgramGuideSearchToolbarModifier(isSearchSheetPresented: isSearchSheetPresented))
        #else
            self
        #endif
    }
}
