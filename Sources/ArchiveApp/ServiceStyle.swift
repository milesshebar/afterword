import SwiftUI
import ArchiveCore

extension ServiceKey {
    var shortLabel: String {
        switch self { case .imessage: return "iMsg"; case .sms: return "SMS"; case .messenger: return "FB"; case .instagram: return "IG"; case .groupme: return "GM"; case .skype: return "SK"; case .whatsapp: return "WA"; case .snapchat: return "SC"; case .aim: return "AIM"; case .telegram: return "TG"; case .slack: return "SL" }
    }
    var tint: Color {
        switch self {
        case .imessage: return Color(red: 0.04, green: 0.52, blue: 1.0)
        case .sms: return Color(red: 0.20, green: 0.69, blue: 0.36)
        case .messenger: return Color(red: 0.56, green: 0.36, blue: 0.96)
        case .instagram: return Color(red: 0.88, green: 0.24, blue: 0.52)
        case .groupme: return Color(red: 0.0, green: 0.66, blue: 0.86)
        case .skype: return Color(red: 0.0, green: 0.69, blue: 0.94)
        case .whatsapp: return Color(red: 0.15, green: 0.83, blue: 0.40)
        case .snapchat: return Color(red: 0.93, green: 0.78, blue: 0.0)
        case .aim: return Color(red: 0.98, green: 0.80, blue: 0.10)
        case .telegram: return Color(red: 0.16, green: 0.63, blue: 0.85)
        case .slack: return Color(red: 0.38, green: 0.12, blue: 0.41)
        }
    }
}

/// A small capsule naming a service, for list rows.
struct ServiceBadge: View {
    let service: ServiceKey
    var compact = false
    var body: some View {
        Text(compact ? service.shortLabel : service.label)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .foregroundStyle(service.tint)
            .background(service.tint.opacity(0.14), in: Capsule())
    }
}

/// The quiet label next to a bubble in a merged timeline: which service this message travelled on.
struct ServiceTag: View {
    let service: ServiceKey
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(service.tint).frame(width: 5, height: 5)
            Text(service.label).font(.system(size: 9))
        }
        .foregroundStyle(.tertiary)
        .fixedSize()
        .padding(.horizontal, 4)
        .accessibilityLabel(service.label)
    }
}

/// One filter chip of the person header.
struct ServiceChip: View {
    let service: ServiceKey
    let count: Int
    let on: Bool
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(service.tint).frame(width: 6, height: 6)
            Text(service.label).font(.system(size: 11, weight: .medium))
            Text(count.formatted()).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(on ? service.tint.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(on ? service.tint.opacity(0.55) : Color.clear, lineWidth: 1))
        .opacity(on ? 1 : 0.55)
        .contentShape(Capsule())
    }
}
