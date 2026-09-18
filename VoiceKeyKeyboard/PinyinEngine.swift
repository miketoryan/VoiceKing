import Foundation

@MainActor
final class PinyinEngine {
    struct Candidate: Sendable {
        let text: String
        let weight: Int
    }

    private var table: [String: [Candidate]] = [:]
    private var selectionCounts: [String: Int]

    private enum Defaults {
        static let selections = "voiceking.pinyin-selections"
        static let lastUpdate = "voiceking.pinyin-last-update"
    }

    private static let remoteDictionaryURL = URL(
        string: "https://raw.githubusercontent.com/rime/rime-pinyin-simp/master/pinyin_simp.dict.yaml"
    )!

    init() {
        selectionCounts = UserDefaults.standard.dictionary(
            forKey: Defaults.selections
        ) as? [String: Int] ?? [:]

        if let cached = try? Data(contentsOf: cacheURL),
           cached.count > 500_000 {
            table = Self.parse(cached)
        } else if let bundledURL = Bundle.main.url(
            forResource: "pinyin_simp.dict",
            withExtension: "yaml"
        ), let bundled = try? Data(contentsOf: bundledURL) {
            table = Self.parse(bundled)
        }
    }

    func candidates(for rawPinyin: String, limit: Int = 12) -> [String] {
        let key = Self.normalize(rawPinyin)
        guard !key.isEmpty, let candidates = table[key] else { return [] }

        return candidates
            .sorted { lhs, rhs in
                let lhsScore = lhs.weight + selectionBoost(for: lhs.text, key: key)
                let rhsScore = rhs.weight + selectionBoost(for: rhs.text, key: key)
                if lhsScore == rhsScore { return lhs.text.count < rhs.text.count }
                return lhsScore > rhsScore
            }
            .prefix(limit)
            .map(\.text)
    }

    func recordSelection(_ text: String, for rawPinyin: String) {
        let key = Self.normalize(rawPinyin)
        guard !key.isEmpty, !text.isEmpty else { return }

        let selectionKey = "\(key)|\(text)"
        selectionCounts[selectionKey, default: 0] += 1

        if selectionCounts.count > 800 {
            selectionCounts = Dictionary(
                uniqueKeysWithValues: selectionCounts
                    .sorted { $0.value > $1.value }
                    .prefix(500)
                    .map { ($0.key, $0.value) }
            )
        }
        UserDefaults.standard.set(selectionCounts, forKey: Defaults.selections)
    }

    func refreshFromNetworkIfNeeded() async {
        let lastUpdate = UserDefaults.standard.object(
            forKey: Defaults.lastUpdate
        ) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastUpdate) > 7 * 24 * 60 * 60 else { return }

        do {
            var request = URLRequest(url: Self.remoteDictionaryURL)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  data.count > 500_000 else { return }

            let updatedTable = Self.parse(data)
            guard updatedTable.count > 1_000 else { return }
            try data.write(to: cacheURL, options: .atomic)
            table = updatedTable
            UserDefaults.standard.set(Date(), forKey: Defaults.lastUpdate)
        } catch {
            // The bundled dictionary remains available when an update fails.
        }
    }

    private var cacheURL: URL {
        let directory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        return directory.appendingPathComponent("pinyin_simp.dict.yaml")
    }

    private func selectionBoost(for text: String, key: String) -> Int {
        selectionCounts["\(key)|\(text)", default: 0] * 1_000_000
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isASCII && $0.isLetter }
    }

    private static func parse(_ data: Data) -> [String: [Candidate]] {
        let contents = String(decoding: data, as: UTF8.self)
        var entries: [String: [Candidate]] = [:]
        entries.reserveCapacity(40_000)

        contents.enumerateLines { line, _ in
            guard !line.isEmpty,
                  line.first != "#",
                  line.first != "-",
                  line.first != "." else { return }

            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return }
            let text = String(fields[0])
            let key = normalize(String(fields[1]))
            guard !text.isEmpty, !key.isEmpty else { return }
            let weight = fields.count >= 3 ? Int(fields[2]) ?? 0 : 0
            entries[key, default: []].append(Candidate(text: text, weight: weight))
        }

        for (key, values) in entries {
            entries[key] = Array(
                values
                    .sorted { $0.weight > $1.weight }
                    .prefix(32)
            )
        }
        return entries
    }
}
