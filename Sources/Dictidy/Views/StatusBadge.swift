import SwiftUI

/// The single status indicator used everywhere Dictidy needs to say "is this set up?".
/// Replaces the four ad-hoc treatments (Ready pill / Downloaded / green "Granted" / numbered seals).
///
///     StatusBadge(.ready)                        // ✓ Ready (green)
///     StatusBadge(.ready, label: "Downloaded")   // ✓ Downloaded (green)
///     StatusBadge(.actionNeeded, label: "Not granted")
///     StatusBadge(.working, label: "Downloading…")
struct StatusBadge: View {

    enum State {
        case ready          // set up and working
        case actionNeeded   // needs the user to do something
        case working        // transient in-progress

        var defaultLabel: String {
            switch self {
            case .ready:        return "Ready"
            case .actionNeeded: return "Action needed"
            case .working:      return "Working…"
            }
        }
        var tint: Color {
            switch self {
            case .ready:        return .green
            case .actionNeeded: return .orange
            case .working:      return .secondary
            }
        }
    }

    let state: State
    var label: String?

    init(_ state: State, label: String? = nil) {
        self.state = state
        self.label = label
    }

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(label ?? state.defaultLabel)
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(state.tint)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .ready:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .actionNeeded:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .working:
            ProgressView().controlSize(.small)
        }
        Group {}.font(.caption)
    }
}

/// Convenience for the common permission/toggle row: title on the left, StatusBadge on the right,
/// an optional action button, and a full-wrapping caption underneath.
struct StatusRow<Trailing: View>: View {
    let title: String
    let state: StatusBadge.State
    var badgeLabel: String?
    var caption: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title).font(.body).fontWeight(.medium)
                StatusBadge(state, label: badgeLabel)
                Spacer()
                trailing()
            }
            if let caption {
                Text(caption)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)   // never clip
            }
        }
    }
}

extension StatusRow where Trailing == EmptyView {
    init(title: String, state: StatusBadge.State, badgeLabel: String? = nil, caption: String? = nil) {
        self.init(title: title, state: state, badgeLabel: badgeLabel, caption: caption) { EmptyView() }
    }
}
