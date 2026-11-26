import Foundation
import Contacts
import ArchiveCore

/// Names from the Contacts app, resolved at view time (never stored in the archive). Highest priority of all name
/// origins: `contacts-app` 30 > `iphone-addressbook` 20 > `android-xml` 10. Needs the user's one-time permission.
@MainActor @Observable
final class ContactsResolver {
    enum Access: Equatable { case notDetermined, authorized, denied, restricted, unavailable }

    private(set) var access: Access = .notDetermined
    private(set) var names: [String: String] = [:]      // normalized handle -> display name
    private(set) var contactCount = 0
    let enabled: Bool

    /// An unbundled `swift run` binary has no NSContactsUsageDescription, and asking for access then kills the process.
    static var canPrompt: Bool { Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil }

    init(enabled: Bool) {
        self.enabled = enabled
        access = enabled ? Self.currentAccess() : .unavailable
    }

    private static func currentAccess() -> Access {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func refresh() async {
        guard enabled else { return }
        access = Self.currentAccess()
        guard access == .authorized else { names = [:]; contactCount = 0; return }
        let result = await Task.detached(priority: .utility) { Self.fetchAll() }.value
        names = result.names
        contactCount = result.count
    }

    func requestAccess() async {
        guard enabled, Self.canPrompt else { return }
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        await refresh()
    }

    nonisolated private static func fetchAll() -> (names: [String: String], count: Int) {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor, CNContactNicknameKey as CNKeyDescriptor,
        ]
        var out: [String: String] = [:]
        var n = 0
        let req = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: req) { c, _ in
            n += 1
            var name = CNContactFormatter.string(from: c, style: .fullName) ?? ""
            if name.isEmpty { name = c.nickname }
            if name.isEmpty { name = c.organizationName }
            if name.isEmpty { return }
            for p in c.phoneNumbers { if let h = HandleNormalizer.normalize(p.value.stringValue) { out[h.normalized] = out[h.normalized] ?? name } }
            for e in c.emailAddresses { if let h = HandleNormalizer.normalize(e.value as String) { out[h.normalized] = out[h.normalized] ?? name } }
        }
        return (out, n)
    }
}
