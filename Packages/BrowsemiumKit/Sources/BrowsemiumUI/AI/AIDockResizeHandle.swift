import AppKit
import SwiftUI

/// Drag handle for the assistant dock. Keeps its own transient gesture state
/// so the drag is never re-created mid-gesture — the previous implementation
/// rebuilt the handle on every frame, which made resizing stutter and drop.
@MainActor
struct AIDockResizeHandle: View {
    @Binding var width: CGFloat
    let maximumWidth: CGFloat

    @GestureState private var isDragging = false
    @State private var dragStartWidth: CGFloat?

    private var clampedWidth: (CGFloat) -> CGFloat {
        { proposed in
            min(max(BrowserMetrics.aiDockMinimumWidth, proposed), max(maximumWidth, BrowserMetrics.aiDockMinimumWidth))
        }
    }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 10)
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(isDragging ? Color.browsemiumBorderStrong : Color.clear)
                    .frame(width: 2)
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .updating($isDragging) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = width
                        }
                        width = clampedWidth((dragStartWidth ?? width) - value.translation.width)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        BrowserHaptics.perform()
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    NSCursor.resizeLeftRight.set()
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            .accessibilityLabel("Resize assistant panel")
            .help("Drag to resize the assistant panel")
    }
}
