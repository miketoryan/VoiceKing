import Foundation

@MainActor
final class PinyinEngine {
    private var indexData = Data()
    private var lineOffsets: [Int] = []
    private var selectionCounts: [String: Int]

    private enum Defaults {
        static let selections = "voiceking.pinyin-selections"
        static let lastUpdate = "voiceking.pinyin-last-update"
    }

    // The compact index is generated from Rime pinyin_simp. Keeping the update in
    // VoiceKing's repository lets the keyboard map it directly instead of parsing
    // the much larger YAML dictionary inside the memory-constrained extension.
    private static let remoteIndexURL = URL(
        string: "https://raw.githubusercontent.com/miketoryan/VoiceKing/main/VoiceKeyKeyboard/Resources/pinyin_index.tsv"
    )!

    init() {
        selectionCounts = UserDefaults.standard.dictionary(
            forKey: Defaults.selections
        ) as? [String: Int] ?? [:]

        if !loadIndex(at: cacheURL),
           let bundledURL = Bundle.main.url(
               forResource: "pinyin_index",
               withExtension: "tsv"
           ) {
            _ = loadIndex(at: bundledURL)
        }
    }

    func candidates(for rawPinyin: String, limit: Int = 12) -> [String] {
        let key = Self.normalize(rawPinyin)
        guard !key.isEmpty,
              let lineIndex = findLine(for: Array(key.utf8)) else { return [] }

        let values = candidates(onLine: lineIndex)
        return values
            .enumerated()
            .sorted { lhs, rhs in
                let lhsBoost = selectionBoost(for: lhs.element, key: key)
                let rhsBoost = selectionBoost(for: rhs.element, key: key)
                if lhsBoost == rhsBoost { return lhs.offset < rhs.offset }
                return lhsBoost > rhsBoost
            }
            .prefix(limit)
            .map(\.element)
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
            var request = URLRequest(url: Self.remoteIndexURL)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  Self.looksLikeIndex(data) else { return }

            try data.write(to: cacheURL, options: .atomic)
            guard loadIndex(at: cacheURL) else { return }
            UserDefaults.standard.set(Date(), forKey: Defaults.lastUpdate)
        } catch {
            // The bundled compact index remains available when an update fails.
        }
    }

    private var cacheURL: URL {
        let directory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        return directory.appendingPathComponent("pinyin_index.tsv")
    }

    private func loadIndex(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              Self.looksLikeIndex(data) else { return false }

        var offsets = [0]
        offsets.reserveCapacity(40_000)
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard bytes.count > 1 else { return }
            for position in 0..<(bytes.count - 1)
                where bytes[position] == 0x0A && position + 1 < bytes.count {
                offsets.append(position + 1)
            }
        }

        indexData = data
        lineOffsets = offsets
        return true
    }

    private static func looksLikeIndex(_ data: Data) -> Bool {
        data.count > 200_000 &&
            data.prefix(128).contains(0x09) &&
            data.prefix(128).contains(0x0A)
    }

    private func findLine(for key: [UInt8]) -> Int? {
        guard !lineOffsets.isEmpty else { return nil }
        var lowerBound = 0
        var upperBound = lineOffsets.count

        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            let comparison = compareKey(key, withLine: middle)
            if comparison == 0 { return middle }
            if comparison < 0 {
                upperBound = middle
            } else {
                lowerBound = middle + 1
            }
        }
        return nil
    }

    private func compareKey(_ key: [UInt8], withLine lineIndex: Int) -> Int {
        var position = lineOffsets[lineIndex]
        var keyPosition = 0

        while position < indexData.count {
            let byte = indexData[position]
            if byte == 0x09 || byte == 0x0A { break }
            if keyPosition >= key.count { return -1 }
            if key[keyPosition] < byte { return -1 }
            if key[keyPosition] > byte { return 1 }
            position += 1
            keyPosition += 1
        }

        if keyPosition < key.count { return 1 }
        return 0
    }

    private func candidates(onLine lineIndex: Int) -> [String] {
        let start = lineOffsets[lineIndex]
        let end = lineIndex + 1 < lineOffsets.count
            ? lineOffsets[lineIndex + 1] - 1
            : indexData.count
        guard start < end else { return [] }

        let line = indexData[start..<end]
        return String(decoding: line, as: UTF8.self)
            .split(separator: "\t")
            .dropFirst()
            .map(String.init)
    }

    private func selectionBoost(for text: String, key: String) -> Int {
        selectionCounts["\(key)|\(text)", default: 0]
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isASCII && $0.isLetter }
    }
}
