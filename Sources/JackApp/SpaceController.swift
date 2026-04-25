import Foundation
import SwiftUI

// MARK: - SpaceColor

/// Predefined accent colors for spaces.
enum SpaceColor: String, CaseIterable, Identifiable, Sendable {
    case blue, purple, pink, red, orange, yellow, green, teal, indigo, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue:    return .blue
        case .purple:  return .purple
        case .pink:    return .pink
        case .red:     return .red
        case .orange:  return .orange
        case .yellow:  return .yellow
        case .green:   return .green
        case .teal:    return .teal
        case .indigo:  return .indigo
        case .gray:    return .gray
        }
    }

    var nsColor: NSColor {
        switch self {
        case .blue:    return .systemBlue
        case .purple:  return .systemPurple
        case .pink:    return .systemPink
        case .red:     return .systemRed
        case .orange:  return .systemOrange
        case .yellow:  return .systemYellow
        case .green:   return .systemGreen
        case .teal:    return .systemTeal
        case .indigo:  return .systemIndigo
        case .gray:    return .systemGray
        }
    }
}

// MARK: - SpaceIcon

/// Icon for a space — either an SF Symbol or a single emoji character.
enum SpaceIcon: Hashable, Sendable {
    case symbol(String)
    case emoji(String)

    /// Icon categories for the picker.
    struct IconCategory: Identifiable {
        let id: String
        let label: String
        let icons: [SpaceIcon]
    }

    static let categories: [IconCategory] = [
        IconCategory(id: "general", label: "General", icons: [
            .symbol("building.2.fill"),
            .symbol("house.fill"),
            .symbol("briefcase.fill"),
            .symbol("bag.fill"),
            .symbol("tray.full.fill"),
            .symbol("doc.text.fill"),
            .symbol("folder.fill"),
            .symbol("archivebox.fill"),
            .symbol("cube.fill"),
            .symbol("shippingbox.fill"),
            .symbol("gift.fill"),
            .symbol("cart.fill"),
            .symbol("creditcard.fill"),
            .symbol("banknote.fill"),
        ]),
        IconCategory(id: "tools", label: "Tools & Dev", icons: [
            .symbol("gearshape.fill"),
            .symbol("wrench.and.screwdriver.fill"),
            .symbol("hammer.fill"),
            .symbol("screwdriver.fill"),
            .symbol("paintbrush.fill"),
            .symbol("paintbrush.pointed.fill"),
            .symbol("terminal.fill"),
            .symbol("chevron.left.forwardslash.chevron.right"),
            .symbol("ladybug.fill"),
            .symbol("ant.fill"),
            .symbol("cpu.fill"),
            .symbol("memorychip.fill"),
            .symbol("server.rack"),
            .symbol("externaldrive.fill"),
        ]),
        IconCategory(id: "devices", label: "Devices", icons: [
            .symbol("desktopcomputer"),
            .symbol("laptopcomputer"),
            .symbol("iphone"),
            .symbol("ipad"),
            .symbol("applewatch"),
            .symbol("headphones"),
            .symbol("airpodspro"),
            .symbol("tv.fill"),
            .symbol("gamecontroller.fill"),
            .symbol("keyboard.fill"),
            .symbol("computermouse.fill"),
            .symbol("printer.fill"),
        ]),
        IconCategory(id: "media", label: "Media", icons: [
            .symbol("music.note"),
            .symbol("music.note.list"),
            .symbol("film.fill"),
            .symbol("camera.fill"),
            .symbol("video.fill"),
            .symbol("photo.fill"),
            .symbol("mic.fill"),
            .symbol("waveform"),
            .symbol("speaker.wave.2.fill"),
            .symbol("play.rectangle.fill"),
            .symbol("book.fill"),
            .symbol("text.book.closed.fill"),
        ]),
        IconCategory(id: "shapes", label: "Shapes & Symbols", icons: [
            .symbol("star.fill"),
            .symbol("heart.fill"),
            .symbol("bolt.fill"),
            .symbol("flame.fill"),
            .symbol("drop.fill"),
            .symbol("snowflake"),
            .symbol("moon.fill"),
            .symbol("sun.max.fill"),
            .symbol("cloud.fill"),
            .symbol("sparkles"),
            .symbol("wand.and.stars"),
            .symbol("diamond.fill"),
            .symbol("seal.fill"),
            .symbol("shield.fill"),
            .symbol("crown.fill"),
            .symbol("flag.fill"),
        ]),
        IconCategory(id: "nature", label: "Nature & Places", icons: [
            .symbol("leaf.fill"),
            .symbol("tree.fill"),
            .symbol("globe"),
            .symbol("globe.americas.fill"),
            .symbol("globe.europe.africa.fill"),
            .symbol("globe.asia.australia.fill"),
            .symbol("map.fill"),
            .symbol("mappin.and.ellipse"),
            .symbol("mountain.2.fill"),
            .symbol("water.waves"),
            .symbol("pawprint.fill"),
            .symbol("hare.fill"),
            .symbol("bird.fill"),
            .symbol("fish.fill"),
        ]),
        IconCategory(id: "people", label: "People & Social", icons: [
            .symbol("person.2.fill"),
            .symbol("person.3.fill"),
            .symbol("figure.stand"),
            .symbol("figure.walk"),
            .symbol("figure.run"),
            .symbol("hand.raised.fill"),
            .symbol("hand.thumbsup.fill"),
            .symbol("bubble.left.fill"),
            .symbol("bubble.left.and.bubble.right.fill"),
            .symbol("envelope.fill"),
            .symbol("phone.fill"),
            .symbol("bell.fill"),
            .symbol("megaphone.fill"),
            .symbol("graduationcap.fill"),
        ]),
        IconCategory(id: "misc", label: "Other", icons: [
            .symbol("lightbulb.fill"),
            .symbol("puzzlepiece.fill"),
            .symbol("target"),
            .symbol("scope"),
            .symbol("chart.bar.fill"),
            .symbol("chart.pie.fill"),
            .symbol("clock.fill"),
            .symbol("calendar"),
            .symbol("bookmark.fill"),
            .symbol("tag.fill"),
            .symbol("pin.fill"),
            .symbol("paperclip"),
            .symbol("link"),
            .symbol("lock.fill"),
            .symbol("key.fill"),
            .symbol("eye.fill"),
            .symbol("airplane"),
            .symbol("car.fill"),
            .symbol("bicycle"),
            .symbol("trophy.fill"),
            .symbol("medal.fill"),
            .symbol("rosette"),
        ]),
    ]

    /// Flat list of all preset symbols.
    static let presetSymbols: [SpaceIcon] = categories.flatMap(\.icons)

    /// Default icon for team spaces.
    static let defaultTeam: SpaceIcon = .symbol("building.2.fill")

    /// The personal space icon (always person.fill, not editable).
    static let personal: SpaceIcon = .symbol("person.fill")

    /// Serialize to a storable string.
    var serialized: String {
        switch self {
        case .symbol(let name): return "sf:\(name)"
        case .emoji(let char):  return "em:\(char)"
        }
    }

    /// Deserialize from stored string.
    init?(serialized: String) {
        if serialized.hasPrefix("sf:") {
            self = .symbol(String(serialized.dropFirst(3)))
        } else if serialized.hasPrefix("em:") {
            self = .emoji(String(serialized.dropFirst(3)))
        } else {
            return nil
        }
    }
}

// MARK: - Space

struct Space: Identifiable, Hashable {
    let id: String
    let name: String
    let isPersonal: Bool

    static let personal = Space(id: "personal", name: "Pessoal", isPersonal: true)
}

// MARK: - SpaceAppearanceStore

/// Persists space colors and icons in UserDefaults.
private enum SpaceAppearanceStore {
    private static let colorKey = "spaceColors"
    private static let iconKey = "spaceIcons"

    static func color(for spaceId: String) -> SpaceColor {
        let map = UserDefaults.standard.dictionary(forKey: colorKey) as? [String: String]
        guard let raw = map?[spaceId], let c = SpaceColor(rawValue: raw) else {
            return .blue
        }
        return c
    }

    static func setColor(_ color: SpaceColor, for spaceId: String) {
        var map = (UserDefaults.standard.dictionary(forKey: colorKey) as? [String: String]) ?? [:]
        map[spaceId] = color.rawValue
        UserDefaults.standard.set(map, forKey: colorKey)
    }

    static func icon(for spaceId: String) -> SpaceIcon {
        let map = UserDefaults.standard.dictionary(forKey: iconKey) as? [String: String]
        guard let raw = map?[spaceId], let icon = SpaceIcon(serialized: raw) else {
            return .defaultTeam
        }
        return icon
    }

    static func setIcon(_ icon: SpaceIcon, for spaceId: String) {
        var map = (UserDefaults.standard.dictionary(forKey: iconKey) as? [String: String]) ?? [:]
        map[spaceId] = icon.serialized
        UserDefaults.standard.set(map, forKey: iconKey)
    }
}

// MARK: - SpaceController

@MainActor @Observable
final class SpaceController {
    private(set) var activeSpace: Space = .personal
    private(set) var availableSpaces: [Space] = [.personal]
    private(set) var pendingInvitations: [PendingInvitation] = []

    struct PendingInvitation: Identifiable {
        let id: String
        let spaceId: String
        let spaceName: String
        let email: String
    }

    struct SpaceMember: Identifiable {
        let id: String
        let userId: String
        let role: String
        let email: String
        let firstName: String?
        let lastName: String?
    }

    /// Tracked color/icon maps — mutating these triggers @Observable updates.
    private var colorMap: [String: SpaceColor] = [:]
    private var iconMap: [String: SpaceIcon] = [:]

    private static let activeSpaceKey = "activeSpaceId"
    private static let activeSpaceNameKey = "activeSpaceName"
    private static let cachedSpacesKey = "cachedSpaces"

    init() {
        if let raw = UserDefaults.standard.dictionary(forKey: "spaceColors") as? [String: String] {
            for (id, val) in raw {
                if let c = SpaceColor(rawValue: val) { colorMap[id] = c }
            }
        }
        if let raw = UserDefaults.standard.dictionary(forKey: "spaceIcons") as? [String: String] {
            for (id, val) in raw {
                if let icon = SpaceIcon(serialized: val) { iconMap[id] = icon }
            }
        }

        // Restore cached spaces so the sidebar is populated immediately on launch
        if let cached = UserDefaults.standard.array(forKey: Self.cachedSpacesKey) as? [[String: String]] {
            var spaces: [Space] = [.personal]
            for entry in cached {
                if let id = entry["id"], let name = entry["name"] {
                    spaces.append(Space(id: id, name: name, isPersonal: false))
                }
            }
            if spaces.count > 1 {
                availableSpaces = spaces
            }
        }

        if let savedId = UserDefaults.standard.string(forKey: Self.activeSpaceKey),
           savedId != "personal"
        {
            let savedName = UserDefaults.standard.string(forKey: Self.activeSpaceNameKey) ?? savedId
            activeSpace = Space(id: savedId, name: savedName, isPersonal: false)
        }
    }

    // MARK: - Color

    var activeSpaceColor: SpaceColor {
        colorMap[activeSpace.id] ?? .blue
    }

    func color(for space: Space) -> SpaceColor {
        colorMap[space.id] ?? .blue
    }

    func setColor(_ color: SpaceColor, for space: Space) {
        colorMap[space.id] = color
        SpaceAppearanceStore.setColor(color, for: space.id)
    }

    // MARK: - Icon

    var activeSpaceIcon: SpaceIcon {
        activeSpace.isPersonal ? .personal : (iconMap[activeSpace.id] ?? .defaultTeam)
    }

    func icon(for space: Space) -> SpaceIcon {
        space.isPersonal ? .personal : (iconMap[space.id] ?? .defaultTeam)
    }

    func setIcon(_ icon: SpaceIcon, for space: Space) {
        iconMap[space.id] = icon
        SpaceAppearanceStore.setIcon(icon, for: space.id)
    }

    // MARK: - Spaces

    /// The spaceId to pass to Convex queries.
    /// Returns nil for personal space.
    var currentSpaceId: String? {
        activeSpace.isPersonal ? nil : activeSpace.id
    }

    func refreshSpaces() async {
        var spaces: [Space] = [.personal]

        do {
            let token = try await ConvexHTTPClient.getToken()
            let result = try await ConvexHTTPClient.query(
                function: "spaces:list",
                args: [:],
                token: token
            )

            if let items = result as? [[String: Any]] {
                for item in items {
                    if let id = item["_id"] as? String,
                       let name = item["name"] as? String {
                        spaces.append(Space(id: id, name: name, isPersonal: false))
                    }
                }
            }
        } catch {
            NSLog("[SpaceController] Failed to fetch spaces: %@", String(describing: error))
        }

        availableSpaces = spaces
        cacheSpaces(spaces)

        if !activeSpace.isPersonal,
           !spaces.contains(where: { $0.id == activeSpace.id })
        {
            activeSpace = .personal
            persistActiveSpace()
        }
    }

    private func cacheSpaces(_ spaces: [Space]) {
        let nonPersonal = spaces.filter { !$0.isPersonal }
        let serialized = nonPersonal.map { ["id": $0.id, "name": $0.name] }
        UserDefaults.standard.set(serialized, forKey: Self.cachedSpacesKey)
    }

    func switchSpace(to space: Space) {
        activeSpace = space
        persistActiveSpace()
    }

    func createSpace(name: String) async throws -> String {
        let token = try await ConvexHTTPClient.getToken()
        let result = try await ConvexHTTPClient.mutation(
            function: "spaces:create",
            args: ["name": name],
            token: token
        )
        guard let spaceId = result as? String else {
            throw SpaceError.unexpected("No spaceId returned")
        }
        await refreshSpaces()
        return spaceId
    }

    func deleteSpace(_ space: Space) async throws {
        guard !space.isPersonal else { return }

        let token = try await ConvexHTTPClient.getToken()
        _ = try await ConvexHTTPClient.mutation(
            function: "spaces:remove",
            args: ["spaceId": space.id],
            token: token
        )

        activeSpace = .personal
        persistActiveSpace()
        await refreshSpaces()
    }

    // MARK: - Invitations

    func inviteToSpace(spaceId: String, email: String) async throws {
        let token = try await ConvexHTTPClient.getToken()
        _ = try await ConvexHTTPClient.mutation(
            function: "spaces:invite",
            args: ["spaceId": spaceId, "email": email],
            token: token
        )
    }

    func fetchPendingInvitations() async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            let result = try await ConvexHTTPClient.query(
                function: "spaces:pendingInvitations",
                args: [:],
                token: token
            )

            guard let items = result as? [[String: Any]] else {
                pendingInvitations = []
                return
            }

            pendingInvitations = items.compactMap { item in
                guard let id = item["_id"] as? String,
                      let spaceId = item["spaceId"] as? String,
                      let spaceName = item["spaceName"] as? String,
                      let email = item["email"] as? String
                else { return nil }
                return PendingInvitation(id: id, spaceId: spaceId, spaceName: spaceName, email: email)
            }
        } catch {
            NSLog("[SpaceController] Failed to fetch invitations: %@", String(describing: error))
        }
    }

    func acceptInvitation(id: String) async throws {
        let token = try await ConvexHTTPClient.getToken()
        _ = try await ConvexHTTPClient.mutation(
            function: "spaces:acceptInvitation",
            args: ["invitationId": id],
            token: token
        )
        await refreshSpaces()
        await fetchPendingInvitations()
    }

    func declineInvitation(id: String) async throws {
        let token = try await ConvexHTTPClient.getToken()
        _ = try await ConvexHTTPClient.mutation(
            function: "spaces:declineInvitation",
            args: ["invitationId": id],
            token: token
        )
        await fetchPendingInvitations()
    }

    // MARK: - Space Invitations

    struct SpacePendingInvitation: Identifiable {
        let id: String
        let email: String
        let createdAt: Double
    }

    func fetchPendingInvitationsForSpace(spaceId: String) async throws -> [SpacePendingInvitation] {
        let token = try await ConvexHTTPClient.getToken()
        let result = try await ConvexHTTPClient.query(
            function: "spaces:pendingInvitationsForSpace",
            args: ["spaceId": spaceId],
            token: token
        )

        guard let items = result as? [[String: Any]] else { return [] }

        return items.compactMap { item in
            guard let id = item["_id"] as? String,
                  let email = item["email"] as? String,
                  let createdAt = item["createdAt"] as? Double
            else { return nil }
            return SpacePendingInvitation(id: id, email: email, createdAt: createdAt)
        }
    }

    // MARK: - Members

    func fetchMembers(spaceId: String) async throws -> [SpaceMember] {
        let token = try await ConvexHTTPClient.getToken()
        let result = try await ConvexHTTPClient.query(
            function: "spaces:members",
            args: ["spaceId": spaceId],
            token: token
        )

        guard let items = result as? [[String: Any]] else { return [] }

        return items.compactMap { item in
            guard let id = item["_id"] as? String,
                  let userId = item["userId"] as? String,
                  let role = item["role"] as? String,
                  let email = item["email"] as? String
            else { return nil }
            return SpaceMember(
                id: id,
                userId: userId,
                role: role,
                email: email,
                firstName: item["firstName"] as? String,
                lastName: item["lastName"] as? String
            )
        }
    }

    func removeMember(spaceId: String, userId: String) async throws {
        let token = try await ConvexHTTPClient.getToken()
        _ = try await ConvexHTTPClient.mutation(
            function: "spaces:removeMember",
            args: ["spaceId": spaceId, "userId": userId],
            token: token
        )
    }

    func leaveSpace(spaceId: String) async throws {
        let token = try await ConvexHTTPClient.getToken()
        _ = try await ConvexHTTPClient.mutation(
            function: "spaces:leaveSpace",
            args: ["spaceId": spaceId],
            token: token
        )
        activeSpace = .personal
        persistActiveSpace()
        await refreshSpaces()
    }

    // MARK: - Private

    private func persistActiveSpace() {
        UserDefaults.standard.set(activeSpace.id, forKey: Self.activeSpaceKey)
        UserDefaults.standard.set(activeSpace.name, forKey: Self.activeSpaceNameKey)
    }
}

enum SpaceError: LocalizedError {
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .unexpected(let msg): return msg
        }
    }
}
