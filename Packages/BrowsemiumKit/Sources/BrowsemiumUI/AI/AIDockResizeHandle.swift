import AppKit 
import SwiftUI

/// Drag handle for the assistant dock. Keeps its own transient gesture state
/// so the drag is never re-created mid-gesture — the previous implementation
/// rebuilt the handle on every frame, which made resizing stutter and drop.
@MainActor
struct AIDockResizeHandle: View {
    @Binding var width: CGFloat
    let maximumWidth: CGFloat
    let onCommit: () -> Void

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
            .frame(width: 8)
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(isDragging ? Color.browsemiumBorderStrong : Color.clear)
                    .frame(width: 2)
            }
            .gesture(
                // Global (window) coordinates on purpose: the handle moves
                // while the dock resizes, so a local-space translation feeds
                // the movement back into the drag and the width oscillates.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($isDragging) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        let anchor = dragStartWidth ?? width
                        if dragStartWidth == nil {
                            dragStartWidth = anchor
                        }
                        width = clampedWidth(anchor - value.translation.width)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        BrowserHaptics.perform()
                        onCommit()
                    }
            )
            .onChange(of: isDragging) { _, dragging in
                // A cancelled gesture never calls onEnded; clear the anchor so
                // the next drag does not start from a stale width.
                if !dragging {
                    dragStartWidth = nil
                }
            }
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
