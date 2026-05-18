import SwiftUI

#if os(macOS)
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
    func programGuideTitle(showsNavigationTitle: Bool, size: CGSize) -> some View {
        #if os(iOS)
            self
                .modifier(
                    ProgramGuideTitleModifier(
                        isEnabled: showsNavigationTitle && size.height >= size.width
                    )
                )
                .navigationBarTitleDisplayMode(.inline)
        #else
            self
                .modifier(ProgramGuideTitleModifier(isEnabled: true))
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
        onScrollToNow: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
            self.overlay(alignment: .bottomTrailing) {
                VStack(spacing: 12) {
                    Button {
                        if timelineOffsetHours.wrappedValue != 0 {
                            timelineOffsetHours.wrappedValue = 0
                        } else {
                            onScrollToNow()
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title3.weight(.semibold))
                            .frame(width: 52, height: 52)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                    .help("現在の時刻にスクロール")

                    Button {
                        isSearchSheetPresented.wrappedValue = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.title3.weight(.semibold))
                            .frame(width: 52, height: 52)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                    .help("番組を検索")
                }
                .padding(.trailing, 20)
                .padding(.bottom, 24)
            }
        #elseif os(macOS)
            self.modifier(
                ProgramGuideSearchToolbarModifier(isSearchSheetPresented: isSearchSheetPresented))
        #else
            self
        #endif
    }
}
