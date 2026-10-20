import SwiftUI

struct StatusDot: View {
    enum Look { case stopped, running, crashed, starting }

    var look: Look
    var size: CGFloat = 8
    @State private var pulse = false

    init(_ look: Look, size: CGFloat = 8) {
        self.look = look
        self.size = size
    }

    init(_ status: SiteStatus, size: CGFloat = 8) {
        switch status {
        case .stopped: self.init(Look.stopped, size: size)
        case .running: self.init(Look.running, size: size)
        case .partial: self.init(Look.crashed, size: size)
        case .starting: self.init(Look.starting, size: size)
        }
    }

    init(_ state: ProcessState, size: CGFloat = 8) {
        switch state {
        case .stopped: self.init(Look.stopped, size: size)
        case .running: self.init(Look.running, size: size)
        case .starting: self.init(Look.starting, size: size)
        case .exited(let code): self.init(code == 0 ? Look.stopped : Look.crashed, size: size)
        case .failed: self.init(Look.crashed, size: size)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(.black.opacity(look == .stopped ? 0 : 0.15), lineWidth: 0.5))
            .frame(width: size, height: size)
            .opacity(look == .starting && pulse ? 0.3 : 1)
            .animation(look == .starting ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = look == .starting }
            .onChange(of: look) { pulse = look == .starting }
    }

    private var color: Color {
        switch look {
        case .stopped: Color.secondary.opacity(0.45)
        case .running, .starting: Color(nsColor: .systemGreen)
        case .crashed: Color(nsColor: .systemRed)
        }
    }
}
