import Foundation
import CryptoKit

struct FluxgramDownloadMetadataSuggestion: Equatable {
    var author: String
    var title: String
    var tags: [String]
}

private func fluxgramNormalizedTags(_ values: [String]) -> [String] {
    var result: [String] = []
    for rawValue in values {
        let value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else {
            continue
        }
        guard !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
            continue
        }
        result.append(value)
    }
    return result
}

struct FluxgramDownloadMemoryEntry: Codable, Equatable {
    let signature: String
    let sourceLabel: String
    let sourceText: String
    let author: String
    let title: String
    let tags: [String]
    let updatedAt: TimeInterval
    let needsUpload: Bool

    private enum CodingKeys: String, CodingKey {
        case signature
        case sourceLabel
        case sourceText
        case author
        case title
        case tags
        case updatedAt
        case needsUpload
    }

    init(signature: String, sourceLabel: String, sourceText: String, author: String, title: String, tags: [String], updatedAt: TimeInterval, needsUpload: Bool) {
        self.signature = signature
        self.sourceLabel = sourceLabel
        self.sourceText = sourceText
        self.author = author
        self.title = title
        self.tags = tags
        self.updatedAt = updatedAt
        self.needsUpload = needsUpload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            signature: try container.decode(String.self, forKey: .signature),
            sourceLabel: try container.decode(String.self, forKey: .sourceLabel),
            sourceText: try container.decode(String.self, forKey: .sourceText),
            author: try container.decode(String.self, forKey: .author),
            title: try container.decode(String.self, forKey: .title),
            tags: try container.decode([String].self, forKey: .tags),
            updatedAt: try container.decode(TimeInterval.self, forKey: .updatedAt),
            // Existing on-device records predate NAS sync state. Treat them
            // as pending once so they are not silently lost during migration.
            needsUpload: try container.decodeIfPresent(Bool.self, forKey: .needsUpload) ?? true
        )
    }
}

enum FluxgramDownloadMemoryStore {
    private static let key = "com.fluxgram.ios.download-metadata-memory.v1"
    private static let lock = NSLock()
    private static let persistenceQueue = DispatchQueue(label: "com.fluxgram.ios.download-metadata-memory")
    private static var cachedEntries: [FluxgramDownloadMemoryEntry]?

    static func suggestions(for requests: [FluxgramNASDownloadRequest]) -> FluxgramDownloadMetadataSuggestion {
        let text = requests.compactMap { request -> String? in
            let value = request.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }.joined(separator: "\n")
        let label = requests.compactMap { request -> String? in
            let value = request.sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }.joined(separator: " · ")

        if let remembered = self.matchingEntry(sourceLabel: label, sourceText: text) {
            return FluxgramDownloadMetadataSuggestion(author: remembered.author, title: remembered.title, tags: remembered.tags)
        }

        let tags = fluxgramSuggestedDownloadTags(from: text)
        let author = fluxgramSuggestedDownloadAuthor(from: text)
        let title = fluxgramSuggestedDownloadTitle(from: text, author: author)
        return FluxgramDownloadMetadataSuggestion(author: author, title: title, tags: tags)
    }

    // Returns a compact, text-only set of confirmed examples for the next AI
    // request. This is retrieval-augmented memory, not model fine-tuning: the
    // phone chooses relevant past confirmations and the model is told to use
    // them as examples of the user's decision logic.
    static func recognitionMemoryPrompt(sourceLabel: String, sourceText: String) -> String {
        let currentFeatures = self.features(sourceText)
        self.lock.lock()
        let entries = self.cachedEntries ?? self.load()
        self.cachedEntries = entries
        self.lock.unlock()

        let ranked = entries
            .filter { !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { entry in
                (entry: entry, score: self.similarity(current: currentFeatures, remembered: self.features(entry.sourceText), sourceLabel: sourceLabel, rememberedLabel: entry.sourceLabel))
            }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.entry.updatedAt > $1.entry.updatedAt
            }

        // Prefer genuinely related examples. If the text is structurally
        // different, include a small recent sample so the model can still
        // learn the user's conventions without blindly copying an old author.
        var selected = ranked.filter { $0.score >= 0.18 }.prefix(3).map { $0 }
        let usesGeneralExamples = selected.isEmpty
        if selected.isEmpty {
            selected = Array(ranked.prefix(2))
        }
        guard !selected.isEmpty else {
            return ""
        }

        let examples = selected.enumerated().map { index, item in
            let source = self.promptSafeText(item.entry.sourceText, limit: 520)
            let author = item.entry.author.isEmpty ? "未填写" : item.entry.author
            let title = item.entry.title.isEmpty ? "未填写" : item.entry.title
            let tags = item.entry.tags.isEmpty ? "未填写" : item.entry.tags.joined(separator: "、")
            return "案例\(index + 1)（相关度 \(String(format: "%.2f", item.score))）：\n原文：\(source)\n用户确认：作者名=\(author)；标题=\(title)；关键词=\(tags)"
        }.joined(separator: "\n\n")

        let heading = usesGeneralExamples
            ? "以下是用户过去确认过的少量通用偏好案例。当前文本与它们没有足够的表面相似度，只能参考判断习惯，不能照抄结果。"
            : "以下是用户过去确认过的少量相似案例。它们只用于学习判断逻辑，不要直接复制旧案例中的作者名、标题或关键词；如果当前原文没有证据，应输出未识别。"
        return """
        \(heading)
        \(examples)
        """
    }

    static func learn(sourceLabel: String, sourceText: String, author: String, title: String, tags: [String]) {
        let signature = self.signature(sourceLabel: sourceLabel, sourceText: sourceText)
        let normalizedSourceText = self.normalizedSourceText(sourceText)
        let normalizedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTags = fluxgramNormalizedTags(tags)
        let entry = FluxgramDownloadMemoryEntry(
            signature: signature,
            sourceLabel: sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceText: sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
            author: normalizedAuthor,
            title: normalizedTitle,
            tags: normalizedTags,
            updatedAt: Date().timeIntervalSince1970,
            needsUpload: true
        )
        self.lock.lock()
        var entries = self.cachedEntries ?? self.load()
        // AI 识别和下载面板可能使用不同的来源标题，但正文相同就代表
        // 同一批内容。合并时保留已有的非空字段，避免 AI 确认只更新作者
        // 和标签时把下载标题清空。
        if let existing = entries.first(where: {
            $0.signature == signature || self.normalizedSourceText($0.sourceText) == normalizedSourceText
        }) {
            let merged = FluxgramDownloadMemoryEntry(
                signature: signature,
                sourceLabel: entry.sourceLabel.isEmpty ? existing.sourceLabel : entry.sourceLabel,
                sourceText: entry.sourceText.isEmpty ? existing.sourceText : entry.sourceText,
                author: entry.author.isEmpty ? existing.author : entry.author,
                title: entry.title.isEmpty ? existing.title : entry.title,
                tags: entry.tags.isEmpty ? existing.tags : entry.tags,
                updatedAt: entry.updatedAt,
                needsUpload: true
            )
            entries.removeAll { $0.signature == existing.signature || self.normalizedSourceText($0.sourceText) == normalizedSourceText }
            entries.insert(merged, at: 0)
        } else {
            entries.removeAll { $0.signature == signature }
            entries.insert(entry, at: 0)
        }
        self.cachedEntries = Array(entries.prefix(120))
        self.saveLocked()
        self.lock.unlock()
    }

    static func pendingUploadEntries(limit: Int = 20) -> [FluxgramDownloadMemoryEntry] {
        self.lock.lock()
        let entries = self.cachedEntries ?? self.load()
        self.cachedEntries = entries
        self.lock.unlock()
        return Array(entries.filter(\.needsUpload).prefix(max(1, limit)))
    }

    static func pendingUploadCount() -> Int {
        self.lock.lock()
        let entries = self.cachedEntries ?? self.load()
        self.cachedEntries = entries
        self.lock.unlock()
        return entries.reduce(into: 0) { count, entry in
            if entry.needsUpload {
                count += 1
            }
        }
    }

    static func allEntries() -> [FluxgramDownloadMemoryEntry] {
        self.lock.lock()
        let entries = self.cachedEntries ?? self.load()
        self.cachedEntries = entries
        self.lock.unlock()
        return entries
    }

    static func markUploaded(signatures: Set<String>) {
        guard !signatures.isEmpty else {
            return
        }
        self.lock.lock()
        var entries = self.cachedEntries ?? self.load()
        var didChange = false
        entries = entries.map { entry in
            guard entry.needsUpload, signatures.contains(entry.signature) else {
                return entry
            }
            didChange = true
            return FluxgramDownloadMemoryEntry(
                signature: entry.signature,
                sourceLabel: entry.sourceLabel,
                sourceText: entry.sourceText,
                author: entry.author,
                title: entry.title,
                tags: entry.tags,
                updatedAt: entry.updatedAt,
                needsUpload: false
            )
        }
        self.cachedEntries = entries
        if didChange {
            self.saveLocked()
        }
        self.lock.unlock()
    }

    static func learn(requests: [FluxgramNASDownloadRequest], author: String, title: String, tags: [String]) {
        let normalizedTags = fluxgramNormalizedTags(tags)
        var sourceLabels: [String] = []
        var sourceTexts: [String] = []
        for request in requests {
            let sourceLabel = request.sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceText = request.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sourceLabel.isEmpty || !sourceText.isEmpty else {
                continue
            }
            if !sourceLabel.isEmpty {
                sourceLabels.append(sourceLabel)
            }
            if !sourceText.isEmpty {
                sourceTexts.append(sourceText)
            }
            self.learn(sourceLabel: sourceLabel, sourceText: sourceText, author: author, title: title, tags: normalizedTags)
        }

        // Keep one aggregate record for a multi-message selection as well as
        // the individual records above. This lets a later download of the
        // same group reuse the AI-confirmed author/title/tags in one lookup.
        if requests.count > 1, !sourceTexts.isEmpty {
            self.learn(
                sourceLabel: sourceLabels.joined(separator: " · "),
                sourceText: sourceTexts.joined(separator: "\n"),
                author: author,
                title: title,
                tags: normalizedTags
            )
        }
    }

    private static func matchingEntry(sourceLabel: String, sourceText: String) -> FluxgramDownloadMemoryEntry? {
        let signature = self.signature(sourceLabel: sourceLabel, sourceText: sourceText)
        let normalizedSourceText = self.normalizedSourceText(sourceText)
        self.lock.lock()
        if let cachedEntries = self.cachedEntries {
            self.lock.unlock()
            return cachedEntries.first(where: {
                $0.signature == signature || self.normalizedSourceText($0.sourceText) == normalizedSourceText
            })
        }
        let entries = self.load()
        self.cachedEntries = entries
        self.lock.unlock()
        return entries.first(where: {
            $0.signature == signature || self.normalizedSourceText($0.sourceText) == normalizedSourceText
        })
    }

    private static func load() -> [FluxgramDownloadMemoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: self.key),
              let decoded = try? JSONDecoder().decode([FluxgramDownloadMemoryEntry].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    // Call while `lock` is held. Persisting the same snapshot while updates
    // are serialized prevents a rapid sequence of confirmations from letting
    // an older asynchronous write overwrite a newer local correction.
    private static func saveLocked() {
        let entries = self.cachedEntries ?? []
        self.persistenceQueue.sync {
            guard let data = try? JSONEncoder().encode(entries) else {
                return
            }
            UserDefaults.standard.set(data, forKey: self.key)
        }
    }

    private static func signature(sourceLabel: String, sourceText: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8))
        hasher.update(data: Data("\u{0000}".utf8))
        hasher.update(data: Data(sourceText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedSourceText(_ value: String) -> String {
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private struct MemoryFeatures {
        let tokens: Set<String>
        let structure: Set<String>
    }

    private static func features(_ text: String) -> MemoryFeatures {
        let normalized = text.lowercased()
        var tokens = Set<String>()
        var structure = Set<String>()

        func collect(_ pattern: String, prefix: String = "") {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return
            }
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            for match in regex.matches(in: normalized, range: range) {
                guard let valueRange = Range(match.range, in: normalized) else {
                    continue
                }
                let value = String(normalized[valueRange])
                if !value.isEmpty {
                    tokens.insert(prefix + value)
                }
            }
        }

        collect(#"#[^\s#，,。！？!?；;：:]{1,40}"#, prefix: "hashtag:")
        collect(#"[a-z0-9][a-z0-9_.@-]{1,}"#)
        collect(#"[a-z]{2,8}[-_ ]?\d{2,6}"#, prefix: "code:")

        // Chinese/Japanese names and labels have no whitespace. Keep short
        // runs and overlapping bigrams as lightweight structural anchors.
        if let regex = try? NSRegularExpression(pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}]{2,}"#) {
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            for match in regex.matches(in: normalized, range: range) {
                guard let valueRange = Range(match.range, in: normalized) else {
                    continue
                }
                let value = String(normalized[valueRange])
                if value.count <= 16 {
                    tokens.insert("cjk:" + value)
                }
                let characters = Array(value)
                if characters.count >= 2 {
                    for index in 0..<(characters.count - 1) {
                        tokens.insert("gram:" + String(characters[index...index + 1]))
                    }
                }
            }
        }

        let markers: [(String, String)] = [
            (#"作者|作者名|主演|主演名|演员|出演|署名|author|cast"#, "author-marker"),
            (#"平台|来源|channel|official|频道"#, "platform-marker"),
            (#"by\s+|@[a-z0-9_.-]{2,}"#, "by-marker"),
            (#"#[^\s#，,。！？!?；;：:]{1,40}"#, "hashtag"),
            (#"[a-z]{2,8}[-_ ]?\d{2,6}"#, "number-code")
        ]
        for (pattern, name) in markers {
            if normalized.range(of: pattern, options: .regularExpression) != nil {
                structure.insert(name)
            }
        }

        let lineCount = normalized.split(whereSeparator: \.isNewline).count
        structure.insert("lines:\(min(lineCount, 6))")
        return MemoryFeatures(tokens: tokens, structure: structure)
    }

    private static func similarity(current: MemoryFeatures, remembered: MemoryFeatures, sourceLabel: String, rememberedLabel: String) -> Double {
        let sharedTokens = current.tokens.intersection(remembered.tokens).count
        let tokenTotal = current.tokens.union(remembered.tokens).count
        let tokenScore = tokenTotal == 0 ? 0.0 : Double(sharedTokens * 2) / Double(current.tokens.count + remembered.tokens.count)

        let sharedStructure = current.structure.intersection(remembered.structure).count
        let structureTotal = current.structure.union(remembered.structure).count
        let structureScore = structureTotal == 0 ? 0.0 : Double(sharedStructure) / Double(structureTotal)

        var score = tokenScore * 0.62 + structureScore * 0.28
        if !sourceLabel.isEmpty && !rememberedLabel.isEmpty && sourceLabel.caseInsensitiveCompare(rememberedLabel) == .orderedSame {
            score += 0.10
        }
        return min(1.0, score)
    }

    private static func promptSafeText(_ value: String, limit: Int) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\u{0000}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else {
            return cleaned
        }
        let end = cleaned.index(cleaned.startIndex, offsetBy: limit)
        return String(cleaned[..<end]) + "…"
    }
}

// AI 分析与下载面板共用同一份本地学习记录。确认后的结果先保存在
// iPhone；NAS 暂时离线时不会丢失，恢复连接后由服务自动补传。
public func fluxgramStoreAIRecognitionMemory(sourceLabel: String, sourceText: String, author: String, tags: [String]) {
    FluxgramDownloadMemoryStore.learn(
        sourceLabel: sourceLabel,
        sourceText: sourceText,
        author: author,
        title: "",
        tags: tags
    )
    FluxgramNASService.shared.syncPendingDownloadMemory()
}

public func fluxgramAIRecognitionMemoryPrompt(sourceLabel: String, sourceText: String) -> String {
    return FluxgramDownloadMemoryStore.recognitionMemoryPrompt(sourceLabel: sourceLabel, sourceText: sourceText)
}

private func fluxgramSuggestedDownloadAuthor(from sourceText: String) -> String {
    let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = text
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let platformWords: Set<String> = [
        "抖音", "斗鱼", "微博", "快手", "小红书", "b站", "哔哩哔哩",
        "stripchat", "onlyfans", "fansly", "chaturbate", "pornhub", "xhamster",
        "xvideos", "redgifs", "manyvids", "telegram", "tg", "x"
    ]
    let stopWords: Set<String> = [
        "无码", "破解", "高清", "磁链", "点击", "复制", "有码", "字幕",
        "流出", "合集", "周年", "纪念", "专属", "梦幻", "共演",
        "高颜妹子", "多p", "啪啪做爱", "狂插", "口交", "潮吹", "内射",
        "制服", "丝袜", "内衣", "泳装", "浴衣", "女仆", "教师", "护士",
        "视角", "第一视角", "第三视角", "自拍", "露脸", "无码", "有码",
        "作者", "作者名", "主演", "主演名", "平台", "channel", "official"
    ]
    let separatorSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,、/|｜；;：:（）()【】[]《》<>「」『』"))
    if let explicit = lines.first(where: { $0.localizedCaseInsensitiveContains("作者") || $0.localizedCaseInsensitiveContains("主演") || $0.localizedCaseInsensitiveContains("author") || $0.localizedCaseInsensitiveContains("by ") }) {
        let cleaned = explicit
            .replacingOccurrences(of: #"(?i)^(作者名|作者|主演名|主演|author|by)\s*[:：]?\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.components(separatedBy: separatorSet).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let names = parts.filter { candidate in
            guard candidate.count >= 2 && candidate.count <= 24 else { return false }
            guard !stopWords.contains(candidate) else { return false }
            return candidate.range(of: #"^[\p{Han}\p{Hiragana}\p{Katakana}A-Za-z0-9_·・ー]+$"#, options: .regularExpression) != nil
        }
        if !names.isEmpty {
            return names.prefix(4).joined(separator: "、")
        }
    }

    if let firstLine = lines.first {
        let trimmed = firstLine
            .replacingOccurrences(of: #"(?i)\s*(vip|svip|官方|频道)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2 && trimmed.count <= 24,
           trimmed.range(of: #"^[\p{Han}\p{Hiragana}\p{Katakana}A-Za-z0-9_·・ー]+$"#, options: .regularExpression) != nil,
           !platformWords.contains(trimmed.lowercased()),
           !stopWords.contains(trimmed.lowercased()) {
            return trimmed
        }
    }

    // The source label is commonly a Telegram sender or platform name. It is
    // not reliable evidence for the content author, so leave this blank and
    // let the user or the AI confirmation step fill it in explicitly.
    return ""
}

private func fluxgramSuggestedDownloadTitle(from sourceText: String, author: String) -> String {
    let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = text
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !lines.isEmpty else {
        return ""
    }

    let authorCandidates = Set(author.split(separator: "、").map { String($0) })
    let codeRegex = try? NSRegularExpression(pattern: #"(?i)\b([A-Z]{2,8}[-_ ]?\d{2,6})\b"#)
    for line in lines {
        if let codeRegex,
           let match = codeRegex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
           match.numberOfRanges >= 2,
           let codeRange = Range(match.range(at: 1), in: line) {
            let remainder = String(line[codeRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                return remainder
            }
        }
        let cleaned = line
            .replacingOccurrences(of: #"(?i)\s*(vip|svip|官方|频道)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || authorCandidates.contains(cleaned) {
            continue
        }
        if cleaned.count > 80 {
            return String(cleaned.prefix(80))
        }
        if cleaned.range(of: #"^[\p{Han}\p{Hiragana}\p{Katakana}A-Za-z0-9_·・ー#\-\s]+$"#, options: .regularExpression) != nil {
            return cleaned
        }
    }
    return ""
}

private func fluxgramSuggestedDownloadTags(from sourceText: String) -> [String] {
    let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    let platformWords: Set<String> = [
        "抖音", "斗鱼", "微博", "快手", "小红书", "b站", "哔哩哔哩",
        "stripchat", "onlyfans", "fansly", "chaturbate", "pornhub", "xhamster",
        "xvideos", "redgifs", "manyvids", "telegram", "tg", "x"
    ]
    let contentTerms = [
        "成人", "色情", "美乳", "巨乳", "裸", "写真", "福利", "性爱", "制服",
        "内衣", "泳装", "女仆", "护士", "教师", "学生", "空姐", "丝袜",
        "口交", "中出", "颜射", "潮吹", "自慰", "手淫", "第一视角", "3P", "逆3P", "POV"
    ]
    let pattern = #"#([^\s#，,。！？!?；;：:]{1,40})"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return []
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    var result: [String] = []
    for match in regex.matches(in: text, range: range) {
        guard match.numberOfRanges >= 2, let candidateRange = Range(match.range(at: 1), in: text) else {
            continue
        }
        let candidate = String(text[candidateRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = candidate.lowercased()
        if candidate.isEmpty || platformWords.contains(candidate) || platformWords.contains(normalized) {
            continue
        }
        if !contentTerms.contains(where: { candidate.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) && candidate.range(of: #"^[\p{Han}\p{Hiragana}\p{Katakana}A-Za-z0-9_·・ー]+$"#, options: .regularExpression) == nil {
            continue
        }
        if !result.contains(candidate) {
            result.append(candidate)
        }
    }
    return Array(result.prefix(8))
}

func fluxgramDesiredDownloadFileName(
    originalFileName: String,
    sourceText: String,
    author: String,
    title: String,
    sequenceIndex: Int,
    codeOverride: String? = nil
) -> String {
    let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    let ext = (originalFileName as NSString).pathExtension
    let sanitizedAuthor = fluxgramNormalizedFileComponent(author)
    let code = codeOverride ?? (fluxgramSuggestedDownloadCode(from: text) ?? "")

    var parts: [String] = []
    if !code.isEmpty {
        parts.append(code)
    }
    // The download screen blocks submission without an author. Do not fall
    // back to message text here, otherwise a missing AI result can silently
    // produce an unrelated filename.
    if !sanitizedAuthor.isEmpty {
        parts.append(sanitizedAuthor)
    }
    // A catalogue number identifies a work, so keep the filename stable and
    // let the preflight duplicate check reject an already-present work. Files
    // without a number still need a sequence to remain distinct.
    if code.isEmpty {
        parts.append(String(max(sequenceIndex, 1)))
    }
    let baseName = parts.joined(separator: "-")
    return ext.isEmpty ? baseName : "\(baseName).\(ext)"
}

public func fluxgramDownloadCode(from sourceText: String) -> String? {
    return fluxgramSuggestedDownloadCode(from: sourceText)
}

private func fluxgramSuggestedDownloadCode(from sourceText: String) -> String? {
    // Catalogue numbers are not limited to a fixed digit count. In
    // particular, FC2 identifiers commonly exceed six digits.
    guard let codeRegex = try? NSRegularExpression(pattern: #"(?i)\b([A-Z][A-Z0-9]{1,7}[-_ ]?\d{2,})\b"#) else {
        return nil
    }
    let range = NSRange(sourceText.startIndex..<sourceText.endIndex, in: sourceText)
    guard let match = codeRegex.firstMatch(in: sourceText, range: range),
          match.numberOfRanges >= 2,
          let codeRange = Range(match.range(at: 1), in: sourceText) else {
        return nil
    }
    return String(sourceText[codeRange])
        .replacingOccurrences(of: "_", with: "-")
        .replacingOccurrences(of: " ", with: "-")
        .uppercased()
}

private func fluxgramNormalizedFileComponent(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return ""
    }
    let sanitized = trimmed
        .replacingOccurrences(of: #"[/\\:*?"<>|]"#, with: "_", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
        .replacingOccurrences(of: #"[_]{2,}"#, with: "_", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "_. "))
    return sanitized.isEmpty ? "" : sanitized
}
