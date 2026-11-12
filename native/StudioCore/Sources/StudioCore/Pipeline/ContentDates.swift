import Foundation

// MARK: - 内容日期与最早日期
//
// 内容日期 = 截图里的「今天」，默认新建当天；没设过的老项目在重新规划时取当天并记下来，之后固定。
// 最早日期 = 历史记录最早能到哪天：项目填了就用它，没填按内容日期往前推 10 天。
// 历史记录只能落在 [最早日期, 内容日期]；不写内容日期以后的具体日期（提醒、到期写成「每月 17 日」「3 天后」）。
// 规划时程序给出可用日期，规划完把范围外的日期直接改到范围内（不再让大模型重写）。
// 不需要日期的软件（自动分档 dateMode = none）界面上不出现日期。

/// 没填最早日期时，历史记录最多往前推几天。
public let DEFAULT_HISTORY_DAYS = 10

public func dateRuleActive(_ state: JSON) -> Bool {
    validContentDate(state["request"]?["contentDate"].text ?? "")
}

/// 项目自己填的最早日期（没填或不合法时为 nil）。
public func explicitEarliestDate(_ state: JSON) -> String? {
    let value = state["request"]?["earliestDate"].text.jsTrimmed ?? ""
    return validContentDate(value) ? value : nil
}

public func earliestDateOf(_ state: JSON) -> String {
    let base = contentDateOf(state)
    guard let explicit = explicitEarliestDate(state) else { return addDays(base, -DEFAULT_HISTORY_DAYS) }
    return min(explicit, base)
}

/// 日期规则涉及的项目设置；写进各步骤的增量判断，改了日期才重新生成。没设置时不出现，旧项目哈希不变。
func datePolicyFields(_ state: JSON) -> JSON? {
    guard dateRuleActive(state) else { return nil }
    return .obj(["contentDate": state["request"]?["contentDate"], "earliestDate": JSON.maybe(explicitEarliestDate(state))])
}

private func gregorian() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func dateOf(_ key: String) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return gregorian().date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
}

public func addDays(_ key: String, _ days: Int) -> String {
    guard let date = dateOf(key), let moved = gregorian().date(byAdding: .day, value: days, to: date) else { return key }
    let c = gregorian().dateComponents([.year, .month, .day], from: moved)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}

public func daysBetween(_ from: String, _ to: String) -> Int {
    guard let a = dateOf(from), let b = dateOf(to) else { return 0 }
    return gregorian().dateComponents([.day], from: a, to: b).day ?? 0
}

private func dateKey(_ year: Int, _ month: Int, _ day: Int) -> String? {
    guard (1...12).contains(month), day >= 1 else { return nil }
    let key = String(format: "%04d-%02d-%02d", year, month, day)
    return validContentDate(key) ? key : nil
}

private func monthEnd(_ year: Int, _ month: Int) -> String? {
    guard (1...12).contains(month), let first = gregorian().date(from: DateComponents(year: year, month: month, day: 1)),
          let range = gregorian().range(of: .day, in: .month, for: first) else { return nil }
    return dateKey(year, month, range.count)
}

/// 出生日期、证件有效期、商品生产日期这类和「用这个软件」无关的事实日期不受最早日期限制。
private let FACT_DATE_CONTEXT = ["出生", "生日", "身份证", "证件", "有效期", "签发", "发证", "入职", "毕业", "入学", "成立于", "创立", "发行", "出版", "上映", "首播", "发售", "上市", "生产", "保质期", "建于", "纪念日"]

public struct DateMention: Sendable, Equatable {
    /// 原文里的写法
    public let text: String
    /// 用于比较的日期：精确到日的就是那天；只写到月的取当月最后一天
    public let key: String
    /// 年月日或年月写全了的为 true；「8月8日」「08-08 09:30」这种按内容日期所在年份推断
    public let hasYear: Bool
    public let factual: Bool
}

/// 找出文字里的日期。只认得出年月日、年月、月日三类常见写法。
public func dateMentions(_ texts: [String], base: String) -> [DateMention] {
    let baseYear = Int(base.prefix(4)) ?? 2026
    var found: [DateMention] = []
    for raw in texts {
        var text = raw
        for (from, to) in [("－", "-"), ("–", "-"), ("—", "-"), ("−", "-"), ("／", "/"), ("．", "."), ("：", ":")] { text = text.replacingAll(from, with: to) }
        text = String(text.unicodeScalars.map { scalar -> Character in
            (0xFF10...0xFF19).contains(scalar.value) ? Character(UnicodeScalar(scalar.value - 0xFF10 + 0x30)!) : Character(scalar)
        })
        let ns = text as NSString
        var masked = Array(repeating: false, count: ns.length)
        func factual(_ range: NSRange) -> Bool {
            let before = ns.substring(with: NSRange(location: max(0, range.location - 10), length: min(10, range.location)))
            let afterStart = range.location + range.length
            let after = ns.substring(with: NSRange(location: afterStart, length: min(6, ns.length - afterStart)))
            let lineBefore = before.components(separatedBy: "\n").last ?? before
            let lineAfter = after.components(separatedBy: "\n").first ?? after
            return FACT_DATE_CONTEXT.contains { lineBefore.contains($0) } || ["出生", "生日"].contains { lineAfter.contains($0) }
        }
        func scan(_ pattern: String, _ make: ([String]) -> (String, Bool)?) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let range = match.range
                if (range.location..<(range.location + range.length)).contains(where: { masked[$0] }) { continue }
                let groups = (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
                guard let (key, hasYear) = make(groups) else { continue }
                for index in range.location..<(range.location + range.length) { masked[index] = true }
                found.append(DateMention(text: ns.substring(with: range).jsTrimmed, key: key, hasYear: hasYear, factual: factual(range)))
            }
        }
        // 2026-10-08、2026/10/8、2026.10.08、2026年10月8日
        scan(#"(?<![0-9])((?:19|20)[0-9]{2})\s*(?:[-/.]|年)\s*([0-9]{1,2})\s*(?:[-/.]|月)\s*([0-9]{1,2})(?![0-9])\s*[日号]?"#) { g in
            dateKey(Int(g[0])!, Int(g[1])!, Int(g[2])!).map { ($0, true) }
        }
        // 2026-08 期、2026年8月（不认小数点，避免把金额当成年月）
        scan(#"(?<![0-9¥￥.])((?:19|20)[0-9]{2})\s*(?:[-/]|年)\s*([0-9]{1,2})(?![0-9.])\s*月?"#) { g in
            monthEnd(Int(g[0])!, Int(g[1])!).map { ($0, true) }
        }
        // 8月8日、10月12号（没写年份：按内容日期所在年份）
        scan(#"(?<![0-9])([0-9]{1,2})\s*月\s*([0-9]{1,2})\s*[日号]"#) { g in
            dateKey(baseYear, Int(g[0])!, Int(g[1])!).map { ($0, false) }
        }
        // 08-08、09-28 09:30（列表里常见的月-日；10–12 月要后面跟着时间才认，免得把「10-12 人」当成日期）
        for pattern in [#"(?<![0-9.:/-])(0[1-9])-(0[1-9]|[12][0-9]|3[01])(?![0-9-])"#, #"(?<![0-9.:/-])(1[0-2])-(0[1-9]|[12][0-9]|3[01])(?=\s+[0-9]{1,2}:[0-9]{2})"#] {
            scan(pattern) { g in dateKey(baseYear, Int(g[0])!, Int(g[1])!).map { ($0, false) } }
        }
    }
    return found
}

/// 早于最早日期的日期（原文写法，去重）。allowed：截图里本来就有的日期，正文照实描述不算违规。
public func datesBefore(_ texts: [String], earliest: String, base: String, allowed: Set<String> = []) -> [String] {
    uniqued(dateMentions(texts, base: base).filter { mention in
        if mention.factual || allowed.contains(mention.key) { return false }
        // 没写年份又晚于内容日期的，当作未来安排
        if !mention.hasYear && mention.key > base { return false }
        return mention.key < earliest
    }.map(\.text))
}

/// 晚于内容日期的具体日期（原文写法，去重）：截图和正文里不写今天以后的具体日期。与使用软件无关的事实日期不算。
public func datesAfter(_ texts: [String], base: String, allowed: Set<String> = []) -> [String] {
    let mentioned = dateMentions(texts, base: base).filter { !$0.factual && !allowed.contains($0.key) && $0.key > base }.map(\.text)
    // 截图上单独一条就是「10-20」「10-21 明天」这种（日期选择条），10–12 月也按日期算
    let baseYear = Int(base.prefix(4)) ?? 2026
    let standalone = texts.compactMap { text -> String? in
        guard let match = Rx.match(#"^\s*(1[0-2]|0?[1-9])-([0-2]?[0-9]|3[01])\s*(?:今天|明天|后天|周.)?\s*$"#, text),
              let month = Int(match[1] ?? ""), let day = Int(match[2] ?? "") else { return nil }
        let key = String(format: "%04d-%02d-%02d", baseYear, month, day)
        return validContentDate(key) && key > base && !allowed.contains(key) ? text.jsTrimmed : nil
    }
    return uniqued(mentioned + standalone)
}

public func dateKeys(_ texts: [String], base: String) -> Set<String> {
    Set(dateMentions(texts, base: base).map(\.key))
}

/// 程序复核：交给大模型的反馈（只在项目设置了内容日期时检查）。
public func dateProblems(_ state: JSON, _ label: String, _ texts: [String], allowed: Set<String> = []) -> [String] {
    guard dateRuleActive(state) else { return [] }
    let base = contentDateOf(state)
    let earliest = earliestDateOf(state)
    let later = datesAfter(texts, base: base, allowed: allowed)
    let laterProblem = later.isEmpty ? [] : ["\(label)里出现了今天（\(base)）以后的具体日期：\(later.prefix(8).joined(separator: "、"))。不写以后的具体日期，提醒、到期写成「每月 17 日」「3 天后」这类说法"]
    let hits = datesBefore(texts, earliest: earliest, base: base, allowed: allowed)
    if hits.isEmpty { return laterProblem }
    return laterProblem + ["\(label)里出现了早于 \(earliest) 的日期：\(hits.prefix(8).joined(separator: "、"))。历史记录只能在 \(earliest) 至 \(base) 之间，请改到这个范围内；提醒、到期这类以后的事不写具体日期"]
}

/// 规划时可用的日期：今天、前 1、3、6、10 天（不早于最早日期）。
public func datePool(_ state: JSON) -> [String] {
    let base = contentDateOf(state)
    let earliest = earliestDateOf(state)
    return uniqued([0, -1, -3, -6, -10].map { addDays(base, $0) }.filter { $0 >= earliest })
}

/// 「10-19（今天）、10-18、10-16」
func datePoolText(_ state: JSON) -> String {
    let base = contentDateOf(state)
    return datePool(state).map { key in "\(key.dropFirst(5))\(key == base ? "（今天）" : "")" }.joined(separator: "、")
}

/// 写进规划的日期规定：按自动分档决定要不要日期。没设置内容日期的历史项目不加。
public func planDateRule(_ state: JSON, _ profile: AppProfile?) -> String {
    guard dateRuleActive(state) else { return "" }
    if profile?.dateMode == "none" {
        return "\n\n日期：这个软件不需要显示日期。界面上不出现年月日，时间信息用时长、进度或「刚刚」「今天」表达；不规划以历史记录为主的页面。"
    }
    return "\n\n日期（程序会检查）：今天是 \(contentDateOf(state))。界面上要日期时只能用这几天：\(datePoolText(state))；列表里也可以写「今天」「昨天」或只写时间。不写年份，不写今天以后的具体日期（提醒、到期写成「每月 17 日」「3 天后」这类说法）。汇总要和列表一致：「本月」「近 7 天」只算范围内的记录，条数、合计照着 ledger 算；列表从新到旧；同一条记录各屏日期一致；累计次数、天数要符合刚开始用十来天。"
}

/// 写进正文和设计说明的日期规定（截图已经定了，只要求和截图一致）。没设置内容日期的历史项目不加。
public func contentDateRule(_ state: JSON) -> String {
    guard dateRuleActive(state) else { return "" }
    if AppProfile(state["appProfile"])?.dateMode == "none" { return "\n\n日期：正文不写具体日期。" }
    return "\n\n日期：正文里的日期必须和截图上的一致，不新增截图上没有的日期；不写 \(earliestDateOf(state)) 以前或 \(contentDateOf(state)) 以后的具体日期。"
}

/// 写进生图提示词的日期规定（英文，一句话）。
public func imageDateRule(_ state: JSON) -> String {
    guard dateRuleActive(state) else { return "" }
    switch AppProfile(state["appProfile"])?.dateMode {
    case "none": return "Do not show calendar dates anywhere; use times, durations or relative words such as 刚刚 / 今天 instead."
    case "recent": return "Show dates only where the sample values contain them, exactly as written; do not add other dates or any year."
    default: return "Any date shown must be between \(earliestDateOf(state)) and \(contentDateOf(state)); do not show earlier years."
    }
}

/// 把一个日期写回原来的写法：数字段逐个替换，原来两位的仍补成两位。
private func rewriteDate(_ text: String, _ mention: DateMention, to key: String) -> String {
    let parts = key.split(separator: "-").map { Int($0)! }
    guard let regex = try? NSRegularExpression(pattern: "[0-9]+") else { return text }
    let ns = text as NSString
    let groups = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    // 年月日 / 年月 / 月日
    let values: [Int] = mention.hasYear ? (groups.count >= 3 ? parts : [parts[0], parts[1]]) : [parts[1], parts[2]]
    guard groups.count >= values.count else { return text }
    var result = text
    for (index, match) in groups.prefix(values.count).enumerated().reversed() {
        let original = ns.substring(with: match.range)
        let value = values[index]
        let replacement = original.count >= 2 && value < 10 ? String(format: "%02d", value) : String(value)
        result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
    }
    return result
}

/// 规划完程序把范围外的日期改到范围内：早于最早日期的按先后顺序挪到最早日期起的几天；
/// 写了今天以后具体日期的改成今天。与使用软件无关的事实日期（出生、有效期等）不动。
/// 返回替换表（原写法 → 新写法），没有要改的返回空。
public func outOfRangeDateFixes(_ texts: [String], _ state: JSON) -> [(String, String)] {
    guard dateRuleActive(state) else { return [] }
    let base = contentDateOf(state)
    let earliest = earliestDateOf(state)
    let mentions = dateMentions(texts, base: base).filter { !$0.factual }
    let early = Set(mentions.filter { $0.key < earliest }.map(\.key)).sorted()
    let span = max(0, daysBetween(earliest, base))
    var target: [String: String] = [:]
    for (index, key) in early.enumerated() { target[key] = addDays(earliest, min(index, span)) }
    for mention in mentions where mention.key > base { target[mention.key] = base }
    var fixes: [(String, String)] = []
    var seen = Set<String>()
    for mention in mentions.sorted(by: { $0.text.count > $1.text.count }) {
        guard let key = target[mention.key], !seen.contains(mention.text) else { continue }
        // 只写到年月的：落到目标日期所在的月份
        let fixed = rewriteDate(mention.text, mention, to: key)
        if fixed != mention.text { fixes.append((mention.text, fixed)) }
        seen.insert(mention.text)
    }
    return fixes
}

/// 把替换表应用到规划里会进截图和正文的文字上（示例数据、应包含、画面描述、底账、文字契约）。
public func applyDateFixes(_ plan: JSON, _ fixes: [(String, String)]) -> JSON {
    guard !fixes.isEmpty else { return plan }
    func fix(_ value: JSON) -> JSON {
        guard var text = value.string else { return value }
        for (from, to) in fixes { text = text.replacingAll(from, with: to) }
        return .string(text)
    }
    var next = plan
    next["ledger"] = .array(plan["ledger"].items.map(fix))
    next["screens"] = .array(plan["screens"].items.map { screen in
        var item = screen
        for key in ["sampleData", "mustShow"] { item[key] = .array(screen[key].items.map(fix)) }
        item["visualBrief"] = fix(screen["visualBrief"] ?? .string(""))
        var contract = screen["textContract"] ?? .emptyObject
        for (key, value) in contract.fields { contract[key] = fix(value) }
        item["textContract"] = contract
        return item
    })
    return next
}

/// 规划里会进截图和正文的文字（找日期用）
public func planDatedTexts(_ plan: JSON) -> [String] {
    var texts = plan["ledger"].items.map(\.jsString)
    for screen in plan["screens"].items {
        texts.append(contentsOf: (screen["sampleData"].items + screen["mustShow"].items).map(\.jsString))
        texts.append(screen["visualBrief"].text)
        texts.append(contentsOf: screen["textContract"].fields.map(\.value.jsString))
    }
    return texts
}
