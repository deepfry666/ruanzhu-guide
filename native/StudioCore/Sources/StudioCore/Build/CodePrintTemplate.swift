import Foundation

struct PrintPaddingResult {
    let lines: [String]
    /// 补齐片段在最终行数组中的范围，供专项测试核对分布位置。
    let insertedRuns: [Range<Int>]
}

private struct PrintSeedGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func index(upperBound: Int) -> Int {
        guard upperBound > 1 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }
}

extension CodeWordTemplate {
    static let printLayoutValue = "60x52-nonempty-v2"
    public static let printLinesPerPage = 52

    public var usesLogicalLineLayout: Bool { logicalLinesPerPage > 0 }
    public var paginationDescription: String {
        usesLogicalLineLayout ? "60 页 × 每页 52 行非空原始代码（折行不重复计数）" : "60 页 × 每页 50 个版面行（含空行及折行）"
    }

    /// 先以原始行分好页，再在页内折行；长行不会被拆到另一页增加计数。
    var printedPages: [[String]] {
        if usesLogicalLineLayout {
            return stride(from: 0, to: lines.count, by: logicalLinesPerPage).map { start in
                lines[start..<min(start + logicalLinesPerPage, lines.count)].flatMap(codeRows)
            }
        }
        let all = rows
        return stride(from: 0, to: all.count, by: CodeLayout.rowsPerPage).map { start in
            Array(all[start..<min(start + CodeLayout.rowsPerPage, all.count)])
        }
    }

    var printLinePitchTwips: Int {
        guard usesLogicalLineLayout else { return CodeLayout.linePitchTwips }
        if let documentLinePitchTwips { return documentLinePitchTwips }
        let maximum = printedPages.map(\.count).max() ?? Self.printLinesPerPage
        return Self.printLinePitch(maximumRows: maximum)
    }

    static func printLinePitch(maximumRows: Int) -> Int {
        let available = CodeLayout.pageHeightTwips - CodeLayout.marginTopTwips - CodeLayout.marginBottomTwips - 280
        let fit = available / max(1, maximumRows)
        // 留出约一个折行高度的余量，避免 Word 在严格分页边界上自动再挤出第 61 页。
        return min(230, fit - 6)
    }

    /// 前后各保留约五页，补齐片段随机分散在中间区域。
    /// 使用由源文件指纹生成的固定种子，确保同一模板每次生成结果完全一致。
    static func distributedPrintLines(_ nonempty: [String], target: Int, seed: UInt64) -> PrintPaddingResult {
        guard nonempty.count < target else {
            let selected = nonempty.count == target
                ? nonempty
                : Array(nonempty.prefix(target / 2)) + Array(nonempty.suffix(target / 2))
            return PrintPaddingResult(lines: selected, insertedRuns: [])
        }

        let paddingCount = target - nonempty.count
        let edgeLines = min(printLinesPerPage * 5, max(0, nonempty.count / 3))
        let middleStart = edgeLines
        let middleEnd = nonempty.count - edgeLines
        let middleLength = max(1, middleEnd - middleStart)
        let middlePages = max(1, Int(ceil(Double(middleLength) / Double(printLinesPerPage))))
        let groupCount = max(1, min(paddingCount, middlePages))

        var generator = PrintSeedGenerator(seed: seed == 0 ? 0xC0DE_CAFE_52C0_DE00 : seed)
        var groupSizes = Array(repeating: paddingCount / groupCount, count: groupCount)
        for index in 0..<(paddingCount % groupCount) {
            groupSizes[index] += 1
        }
        if groupCount > 1 {
            for index in stride(from: groupCount - 1, through: 1, by: -1) {
                let other = generator.index(upperBound: index + 1)
                groupSizes.swapAt(index, other)
            }
        }

        var insertions: [Int: [String]] = [:]
        for group in 0..<groupCount where groupSizes[group] > 0 {
            let lower = middleStart + middleLength * group / groupCount
            let upper = middleStart + middleLength * (group + 1) / groupCount
            let position = lower + generator.index(upperBound: max(1, upper - lower))
            let size = groupSizes[group]
            let maximumStart = max(0, nonempty.count - min(size, nonempty.count))
            let safeStarts = (0...maximumStart).filter { start in
                isSafePaddingStart(nonempty[start])
                    && nonempty[start..<min(start + size, nonempty.count)].allSatisfy { !isFileBoundaryLine($0) }
            }
            let candidateStarts = safeStarts.isEmpty ? Array(0...maximumStart) : safeStarts
            let start = candidateStarts[generator.index(upperBound: candidateStarts.count)]
            let chunk = (0..<size).map { nonempty[(start + $0) % nonempty.count] }
            insertions[position, default: []].append(contentsOf: chunk)
        }

        var selected: [String] = []
        selected.reserveCapacity(target)
        var insertedRuns: [Range<Int>] = []
        for index in nonempty.indices {
            if let chunk = insertions[index] {
                let start = selected.count
                selected.append(contentsOf: chunk)
                insertedRuns.append(start..<selected.count)
            }
            selected.append(nonempty[index])
        }
        return PrintPaddingResult(lines: selected, insertedRuns: insertedRuns)
    }

    static func printPaddingSeed(from digest: String) -> UInt64 {
        let first = UInt64(digest.prefix(16), radix: 16) ?? 0
        let second = UInt64(digest.dropFirst(16).prefix(16), radix: 16) ?? 0
        return first ^ second
    }

    static func isSafePaddingStart(_ line: String) -> Bool {
        let text = line.jsTrimmed
        guard !text.isEmpty else { return false }
        guard !isFileBoundaryLine(text), !text.hasPrefix("</") else { return false }
        return text != "}" && text != ");" && text != "};"
    }

    static func isFileBoundaryLine(_ line: String) -> Bool {
        let text = line.jsTrimmed
        return text.hasPrefix("package ") || text.hasPrefix("import ") || text.hasPrefix("<?xml")
    }

    /// 仅在用户明确要求补齐时调用。复制本模板已有代码，不由导入或正常出包隐式补行。
    public static func preparedForPrinting(data: Data) throws -> CodeWordTemplate {
        let source = try CodeWordTemplate(data: data)
        if source.usesLogicalLineLayout { return source }
        let nonempty = source.lines.filter { !$0.jsTrimmed.isEmpty }
        guard !nonempty.isEmpty else { throw StudioError("模板没有可复制的非空代码") }
        let target = CodeLayout.pages * printLinesPerPage
        let digest = sha256Hex(data)
        let distributed = distributedPrintLines(nonempty, target: target, seed: printPaddingSeed(from: digest))
        let selected = distributed.lines
        let original = canonicalDocx(lines: selected, sourceRows: source.sourceRows, sourceLines: source.sourceLineCount, sourceSha: digest)
        let zip = try ZipReader(original)
        let maxRows = stride(from: 0, to: selected.count, by: printLinesPerPage).map { start in
            selected[start..<(start + printLinesPerPage)].reduce(0) { $0 + codeRowCount($1) }
        }.max() ?? printLinesPerPage
        let pitch = printLinePitch(maximumRows: maxRows)
        guard pitch >= 200 else { throw StudioError("代码长行过多，无法以清晰字号排入 60 页，请先调整源代码长行") }
        var output = ZipWriter(date: Date(timeIntervalSince1970: 1_767_225_600))
        for entry in zip.entries {
            var bytes = try zip.read(entry)
            if entry.name == "word/document.xml" {
                // 只替换本方法刚生成的确定性段落样式，不重序列化代码文本；
                // FoundationXML 的保留实体序列化会破坏 Java 字符串中的字面量 "&#0;"。
                let parts = String(decoding: bytes, as: UTF8.self).components(separatedBy: paraProps)
                guard parts.count == selected.count + 1 else { throw StudioError("模板段落格式不完整") }
                var document = parts[0]
                for index in selected.indices {
                    var props = paraProps
                        .replacingOccurrences(of: "w:snapToGrid w:val=\"1\"", with: "w:snapToGrid w:val=\"0\"")
                        .replacingOccurrences(of: "w:line=\"240\" w:lineRule=\"auto\"", with: "w:line=\"\(pitch)\" w:lineRule=\"exact\"")
                    var additions = "<w:keepLines w:val=\"1\"/>"
                    if index % printLinesPerPage != printLinesPerPage - 1 { additions += "<w:keepNext w:val=\"1\"/>" }
                    if index > 0 && index % printLinesPerPage == 0 { additions += "<w:pageBreakBefore w:val=\"1\"/>" }
                    props = props.replacingOccurrences(of: "</w:pPr>", with: additions + "</w:pPr>")
                    document += props + parts[index + 1]
                }
                document = document.replacingOccurrences(of: "<w:docGrid w:type=\"lines\" w:linePitch=\"\(CodeLayout.linePitchTwips)\"/>", with: "")
                bytes = Data(document.utf8)
            } else if entry.name == "docProps/custom.xml" {
                var text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "<vt:lpwstr>\(layoutValue)</vt:lpwstr>", with: "<vt:lpwstr>\(printLayoutValue)</vt:lpwstr>")
                let added = max(0, target - nonempty.count)
                let properties = "<property fmtid=\"{D5CDD505-2E9C-101B-9397-08002B2CF9AE}\" pid=\"6\" name=\"ManualStudioRepeatedLines\"><vt:i4>\(added)</vt:i4></property>"
                    + "<property fmtid=\"{D5CDD505-2E9C-101B-9397-08002B2CF9AE}\" pid=\"7\" name=\"ManualStudioPaddingMode\"><vt:lpwstr>middle-random-v1</vt:lpwstr></property>"
                text = text.replacingOccurrences(of: "</Properties>", with: properties + "</Properties>")
                bytes = Data(text.utf8)
            }
            output.addFile(entry.name, bytes)
        }
        return try CodeWordTemplate(data: output.finish())
    }
}
