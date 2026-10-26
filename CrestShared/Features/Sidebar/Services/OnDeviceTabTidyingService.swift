import Foundation
import FoundationModels

// MARK: - Types

/// Tidy ran before its word-vector table was downloaded and loaded.
struct TidyWordTableUnavailable: Error {}

/// Groups a Space's loose open tabs under headers on this device. Nothing
/// leaves it.
///
/// Most of the work happens before the person presses Tidy:
/// `TidyTabDescriptions` has Apple's on-device model describe each tab in a
/// few keyphrases in the background. Pressing Tidy embeds those keyphrases
/// with a static word-vector table, clusters them in milliseconds, and asks
/// the model only once, to name the groups. In a small Space, tabs whose
/// keyphrases are likely invented, such as a site's front page, are then
/// checked one by one against the names.
struct OnDeviceTabTidyingService {
    // MARK: - Static Variables

    /// Tidy is offered once the open section holds this many loose tabs.
    static let minimumLooseTabCount = 6

    /// Tabs are described in the background once the open section holds this
    /// many loose tabs, a little before Tidy is offered.
    static let minimumDescribedTabCount = 4

    /// Whether this device can run the on-device model now.
    static var isModelAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Spaces this small are checked tab by tab after naming; larger ones
    /// would wait too long for it.
    private static let maximumVerifiedTabCount = 20

    /// The name the model gives a group that is general browsing, and the
    /// check's answer for a tab that fits no name.
    private static let noTopic = "none"

    /// Group names that are kinds of browsing rather than topics, whose groups
    /// stay loose.
    private static let looseGroupName = try! NSRegularExpression(
        pattern:
            "^(none|e-?mail|mail|inbox|email inbox|calendars?|chat|communication|social( media)?|music|video|news"
            + "|.* news|general news|weather|sports?)$",
        options: [.caseInsensitive])
    private static let runTogetherNames = try! NSRegularExpression(
        pattern: "[,;|]\\s*(?=(?:group\\s*)?\\d+\\s*[:.)])", options: [.caseInsensitive])
    private static let echoedGroupLabel = try! NSRegularExpression(
        pattern: "^\\s*group\\s*\\d+\\s*[:.)\\-]\\s*", options: [.caseInsensitive])
    private static let nameLine = try! NSRegularExpression(
        pattern: "^\\s*(?:group\\s*)?(\\d+)\\s*[:.)\\-\u{2013}]\\s*(.+?)\\s*$", options: [.caseInsensitive])

    /// Always pick the likeliest answer, so the same tabs tidy the same way.
    private static let options = GenerationOptions(sampling: .greedy)

    /// Naming reads tab titles as data to transform, which the default
    /// guardrails sometimes refuse.
    private static let namingModel = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    private static var language: String {
        let languageCode = Locale.preferredLanguages.first ?? "en"
        return Locale.current.localizedString(forLanguageCode: languageCode) ?? "English"
    }

    private static var namingInstructions: String {
        """
        You name groups of a person's open browser tabs. Each name is the subject the group's tabs have in \
        common, the way a person would label a folder for them: one to three words, never a website's name, \
        broad enough to cover every tab in the group but not a generic category such as Technology, Travel or \
        Shopping. Name a group \(noTopic) when it is email, calendars, chat, social media, music, video, news, sports or \
        weather. Write one line per group: the group number, a colon, and only the name, never the tabs. \
        Write every name in \(language), except \(noTopic).
        """
    }

    // MARK: - Actions - Candidates

    /// The Space's open tabs outside every folder and split that show a web
    /// page, in sidebar order.
    @MainActor
    static func candidates(in space: SpaceModel) -> [TidyTabCandidate] {
        space.tabs.models.compactMap { tab in
            guard tab.placement == .current, tab.folderID == nil, tab.splitGroupID == nil,
                let address = tab.url.flatMap(URL.init(string:))
            else { return nil }
            return TidyTabCandidate(tabID: tab.id, pageTitle: tab.title, address: address)
        }
    }

    // MARK: - Actions - Warming

    /// Loads the model ahead of a likely Tidy, which saves about a second on
    /// the first one.
    static func prewarm() {
        LanguageModelSession(model: namingModel, instructions: namingInstructions).prewarm()
    }

    // MARK: - Actions - Headers

    /// The headers for `candidates`, each holding two or more of them in
    /// sidebar order. Every other tab stays loose. Background descriptions
    /// pause meanwhile. Throws `TidyWordTableUnavailable` before the table is
    /// loaded, or the model's error when naming fails.
    @MainActor
    func headers(for candidates: [TidyTabCandidate]) async throws -> [TidyFolderProposal] {
        guard let embedder = TidyModelDownloads.shared.embedder else { throw TidyWordTableUnavailable() }
        let descriptions = TidyTabDescriptions.shared
        return try await descriptions.pausing {
            let groupable = candidates.filter { !$0.isLooseSiteFrontPage }
            let vectors = groupable.map { candidate in
                let keyphrases = descriptions.keyphrases(for: candidate) ?? []
                return embedder.vector(
                    for: keyphrases.isEmpty ? candidate.cleanedTitle : keyphrases.joined(separator: "; "))
            }
            let groupedIndices = TidyTabGroups(vectors: vectors).groups()
                .filter { !Self.isOnlyFrontPagesOfDifferentSites($0.map { groupable[$0] }) }
            guard !groupedIndices.isEmpty else { return [] }
            var groups = groupedIndices.map { $0.map { groupable[$0] } }
            let groupVectors = groupedIndices.map { members in
                TidyTabEmbedder.unitLength(
                    members.map { vectors[$0] }.reduce(into: [Float](repeating: 0, count: vectors[0].count)) {
                        for index in $0.indices { $0[index] += $1[index] }
                    })
            }
            var names = try await Self.names(for: groups, meaning: groupVectors, embedder: embedder)
            if candidates.count <= Self.maximumVerifiedTabCount {
                (groups, names) = await Self.verified(groups, names: names)
            }
            return Self.proposals(groups: groups, names: names, inOrderOf: candidates)
        }
    }

    /// News, social and app home pages pair up by kind, not by anything the
    /// person is working on.
    private static func isOnlyFrontPagesOfDifferentSites(_ group: [TidyTabCandidate]) -> Bool {
        group.allSatisfy { $0.pathDepth <= 1 } && Set(group.map(\.host)).count == group.count
    }

    private static func isTopic(_ name: String) -> Bool {
        name.contains(where: \.isLetter) && name.lowercased() != noTopic
            && looseGroupName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) == nil
    }

    /// One header per topic name, merging groups the model named alike, with
    /// their tabs in sidebar order.
    private static func proposals(
        groups: [[TidyTabCandidate]], names: [String], inOrderOf candidates: [TidyTabCandidate]
    ) -> [TidyFolderProposal] {
        var namesInOrder: [String] = []
        var tabIDsByName: [String: Set<UUID>] = [:]
        for (group, name) in zip(groups, names) where isTopic(name) {
            let key = name.lowercased()
            if tabIDsByName[key] == nil { namesInOrder.append(name) }
            tabIDsByName[key, default: []].formUnion(group.map(\.tabID))
        }
        return namesInOrder.compactMap { name in
            let members = tabIDsByName[name.lowercased()] ?? []
            let tabIDs = candidates.map(\.tabID).filter(members.contains)
            return tabIDs.count >= 2 ? TidyFolderProposal(folderTitle: name, tabIDs: tabIDs) : nil
        }
    }

    // MARK: - Actions - Naming

    /// A name for each group, from a plain-text call that sees each group's
    /// six most typical titles and hosts. When the model leaves groups out it
    /// renumbers the rest, so each of its names then goes to the group whose
    /// meaning vector in `groupVectors` it matches best, and the groups left
    /// unnamed get one more call. A group still without a name gets "".
    private static func names(
        for groups: [[TidyTabCandidate]], meaning groupVectors: [[Float]], embedder: TidyTabEmbedder,
        isRetry: Bool = false
    ) async throws -> [String] {
        let prompt = groups.enumerated().map { number, group in
            "Group \(number + 1): " + group.prefix(6).map { "\($0.cleanedTitle) (\($0.host))" }.joined(separator: "; ")
        }.joined(separator: "\n")
        let text = try await LanguageModelSession(model: namingModel, instructions: namingInstructions)
            .respond(to: prompt, options: options).content
        let lines = runTogetherNames.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n")
        var namesByNumber: [Int: String] = [:]
        for line in lines.split(whereSeparator: \.isNewline).map(String.init) {
            guard let match = nameLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                let numberRange = Range(match.range(at: 1), in: line), let number = Int(line[numberRange]),
                let nameRange = Range(match.range(at: 2), in: line)
            else { continue }
            let named = String(line[nameRange])
            let unlabeled = echoedGroupLabel.stringByReplacingMatches(
                in: named, range: NSRange(named.startIndex..., in: named), withTemplate: "")
            namesByNumber[number] = String(unlabeled.prefix { !":,(;".contains($0) })
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"*. "))
        }
        guard namesByNumber.count < groups.count else { return groups.indices.map { namesByNumber[$0 + 1] ?? "" } }

        let names = namesByNumber.sorted { $0.key < $1.key }.map(\.value)
        let matches = names.indices.flatMap { nameIndex in
            let nameVector = embedder.vector(for: names[nameIndex])
            return groupVectors.indices.map { groupIndex in
                (
                    name: nameIndex, group: groupIndex,
                    similarity: zip(nameVector, groupVectors[groupIndex]).reduce(0) { $0 + $1.0 * $1.1 }
                )
            }
        }.sorted { $0.similarity > $1.similarity }
        var matched = groups.map { _ in "" }
        var usedNames: Set<Int> = []
        for match in matches where !usedNames.contains(match.name) {
            usedNames.insert(match.name)
            if matched[match.group].isEmpty { matched[match.group] = names[match.name] }
        }
        let unnamed = groups.indices.filter { matched[$0].isEmpty }
        guard !isRetry, !unnamed.isEmpty else { return matched }
        let retried = try await Self.names(
            for: unnamed.map { groups[$0] }, meaning: unnamed.map { groupVectors[$0] }, embedder: embedder,
            isRetry: true)
        for (index, name) in zip(unnamed, retried) { matched[index] = name }
        return matched
    }

    // MARK: - Actions - Checking

    /// Groups after checking the tabs most likely misfiled. A group named for
    /// a kind of browsing loses its front pages. In a group named for a topic,
    /// each front page or sign-in page picks among the topic names, guided, and
    /// leaves unless it picks its own group's. A refused pick keeps the tab.
    private static func verified(
        _ groups: [[TidyTabCandidate]], names: [String]
    ) async -> ([[TidyTabCandidate]], [String]) {
        var kept = groups
        for index in groups.indices where !names[index].isEmpty && !isTopic(names[index]) {
            kept[index].removeAll(where: \.isNearSiteRoot)
        }
        let topics = Array(Set(names.filter(isTopic))).sorted()
        let checks = groups.indices.flatMap { index in
            isTopic(names[index]) ? groups[index].filter(\.isNearSiteRoot).map { (index, $0) } : []
        }
        if !topics.isEmpty, !checks.isEmpty,
            let schema = try? GenerationSchema(
                root: DynamicGenerationSchema(name: "Topic", anyOf: topics + [noTopic]), dependencies: [])
        {
            let instructions = """
                Choose which of these topics a browser tab is about: \(topics.joined(separator: "; ")). \
                Answer "\(noTopic)" when it is about none of them.
                """
            let picks = await withTaskGroup(of: (UUID, String?).self) { taskGroup in
                for (_, candidate) in checks {
                    taskGroup.addTask {
                        let pick = try? await LanguageModelSession(instructions: instructions)
                            .respond(to: candidate.modelDescription, schema: schema, options: options)
                            .content.value(String.self)
                        return (candidate.tabID, pick)
                    }
                }
                var picks: [UUID: String] = [:]
                for await (tabID, pick) in taskGroup { picks[tabID] = pick }
                return picks
            }
            for (index, candidate) in checks {
                if let pick = picks[candidate.tabID], pick != names[index] {
                    kept[index].removeAll { $0.tabID == candidate.tabID }
                }
            }
        }
        let survivors = kept.indices.filter { kept[$0].count >= 2 }
        return (survivors.map { kept[$0] }, survivors.map { names[$0] })
    }
}
