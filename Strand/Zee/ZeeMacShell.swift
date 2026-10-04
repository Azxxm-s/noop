#if os(macOS)
import SwiftUI

/// Zee mode on the Mac: the focused dashboard fills the window. The Zee | More switch in its header
/// (and in the sidebar of the full app) flips back to the original NOOP layout.
struct ZeeMacShell: View {
    var body: some View {
        NavigationStack {
            FocusView()
        }
        // The window hides its title bar, so leave room for the traffic-light buttons.
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 22) }
        .background(FT.bg.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }
}
#endif
