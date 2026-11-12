import Foundation

// MARK: - 自动分档
//
// 拿到软件名先判断三件事，后面每一步只加载这一档需要的规则：
// - category：方向（游戏、手机工具、交通出行……），决定规划时参考什么
// - dateMode：none（界面不显示日期）/ recent（天生带日期的记录类，只用最近十来天）
// - facts：截图里会出现、现实中有标准答案、不能乱编的数据领域（违法代码、税率……）
// 规划开始时发一个很短的请求判断，结果存进项目（state.appProfile），重新规划时复用。没配模型或请求失败时按关键词判断。

public let APP_CATEGORIES = ["游戏", "手机工具", "AI创作与影音", "健康习惯学习", "交通出行", "货运配送零工", "社保公积金个税证件", "购物二手商家", "生活缴费记账", "企业管理", "其他"]

public struct AppProfile: Sendable, Equatable {
    public var reason: String
    public var category: String
    /// none：不显示日期；recent：只用最近十来天的日期
    public var dateMode: String
    public var facts: [String]
    /// llm / keywords
    public var source: String

    public var json: JSON {
        .obj(["reason": .string(reason), "category": .string(category), "dateMode": .string(dateMode), "facts": JSON(facts), "source": .string(source)])
    }

    public init(reason: String, category: String, dateMode: String, facts: [String], source: String) {
        self.reason = reason
        self.category = APP_CATEGORIES.contains(category) ? category : "其他"
        self.dateMode = dateMode == "recent" ? "recent" : "none"
        self.facts = uniqued(facts.map(\.jsTrimmed).filter { !$0.isEmpty })
        self.source = source
    }

    public init?(_ json: JSON?) {
        guard let json, let category = json["category"]?.string, let mode = json["dateMode"]?.string else { return nil }
        self.init(reason: json["reason"].text, category: category, dateMode: mode, facts: json["facts"].items.map(\.jsString), source: json["source"].text)
    }

    /// 日志里的一行
    public var summary: String {
        "\(category) · \(dateMode == "recent" ? "日期只用最近十来天" : "不显示日期")\(facts.isEmpty ? "" : " · 真实数据：\(facts.joined(separator: "、"))")"
    }
}

public let CLASSIFY_SYSTEM = """
你根据软件名判断这个手机 App 属于哪一类，供后面规划截图用。按顺序输出：
- reason：一句话依据。
- category：从这些里选一个：\(APP_CATEGORIES.joined(separator: "、"))。
- dateMode：截图里要不要显示日期。软件的核心是账单、缴费、订单、运单、打卡、工时、健康监测、记录流水这类带时间的记录时写 recent；游戏、工具、创作、影音、浏览、娱乐、查询资料这类不靠日期的写 none。拿不准写 none。
- facts：截图里会出现、现实中有标准答案、不能随便编的数据领域，例如「交通违法代码和记分」「驾考题目」「社保缴费比例」「个税税率」「火车车次」。没有就给空数组。
"""

public let CLASSIFY_SCHEMA: JSON = .obj([
    "type": "object",
    "required": ["reason", "category", "dateMode", "facts"],
    "properties": .obj([
        "reason": .obj(["type": "string"]),
        "category": .obj(["type": "string", "enum": JSON(APP_CATEGORIES)]),
        "dateMode": .obj(["type": "string", "enum": ["none", "recent"]]),
        "facts": .obj(["type": "array", "items": .obj(["type": "string"])]),
    ]),
])

public func classifyUserPrompt(softwareName: String, emphasis: String, notes: String) -> String {
    [
        "软件名：\(softwareName)",
        emphasis.isEmpty ? "" : "用户强调的功能：\(emphasis)",
        notes.isEmpty ? "" : "补充说明：\(notes)",
        #"输出 JSON：{"reason":"","category":"","dateMode":"none","facts":[]}"#,
    ].filter { !$0.isEmpty }.joined(separator: "\n")
}

/// 关键词判断（兜底）：按软件名和补充说明里的字样分档。
public func keywordAppProfile(_ text: String) -> AppProfile {
    let rules: [(String, String, String)] = [
        ("游戏", #"游戏|模拟|闯关|跑酷|消除|消一消|贪吃蛇|争霸|捉迷藏|枪战|射击|塔防|拼图|象棋|五子棋|僵尸|赛车|吞噬|沙盒|养成|弓箭|解谜|魔方|骰|刮刮乐|钓鱼|脑力|通关"#, "none"),
        ("交通出行", #"违章|违法|违规|交规|罚款|驾考|科目[一二三四]|公交|地铁|行程码|火车|铁路|车次|ETC|导航|地图|顺风车|充电桩|电桩|油价|景点|景区"#, "none"),
        ("货运配送零工", #"货车|货运|拉货|运货|司机|骑手|配送|跑腿|搬砖|兼职|工时|加班|记工|小时工|家政"#, "recent"),
        ("社保公积金个税证件", #"社保|医保|养老|公积金|汇算|退税|个税|所得税|证件|证照|学历|发票|报销"#, "recent"),
        ("生活缴费记账", #"水电|电费|水费|燃气|话费|流量|扣费|续费|记账|账本|账单|租房"#, "recent"),
        ("健康习惯学习", #"健康|血压|血糖|血脂|视力|体重|减肥|运动|打卡|习惯|专注|自律|锁机|闹钟|学习|课堂|刷题|考点|口语|拼读|阅卷|面试"#, "recent"),
        ("AI创作与影音", #"AI|漫剧|短剧|视频|影视|动漫|播放器|音乐|铃声|K歌|唱|变声|数字人|直播|音频"#, "none"),
        ("购物二手商家", #"二手|闲置|购物|商城|生鲜|买菜|拼单|拼团|团购|电商|点餐|保养|养车|车险"#, "recent"),
        ("企业管理", #"管理系统|平台|办公|协同|项目管理|溯源|物流|巡查"#, "recent"),
        ("手机工具", #"扫码|扫一扫|二维码|清理|备份|互传|克隆|换机|连点|点击器|投屏|同屏|相机|水印|美颜|修图|改字|图标|网盘|云盘|浏览器|打印|翻译|定位|监控|看家|扩音|转盘|决定|吃什么|喝什么"#, "none"),
    ]
    let facts: [(String, String)] = [
        (#"违章|违法|违规|交规|罚款"#, "交通违法代码和记分"),
        (#"驾考|科目[一二三四]|驾驶交规"#, "驾考题目"),
        (#"社保|医保|养老"#, "社保医保缴费比例"),
        (#"公积金"#, "公积金缴存比例"),
        (#"个税|所得税|汇算|退税"#, "个税税率和扣除标准"),
        (#"火车|铁路|车次"#, "火车车次"),
        (#"油价"#, "油价"),
    ]
    let found = rules.first { Rx.test($0.1, text, "i") }
    return AppProfile(
        reason: found.map { "软件名里有「\($0.0)」相关的字样" } ?? "软件名里没有明显的类型字样",
        category: found?.0 ?? "其他", dateMode: found?.2 ?? "none",
        facts: facts.filter { Rx.test($0.0, text) }.map(\.1), source: "keywords"
    )
}

extension Pipeline {
    /// 项目的分档：已经判断过就复用，没有就判断一次并存下来。
    func appProfile(_ dir: String, _ state: JSON) async -> AppProfile {
        if let saved = AppProfile(state["appProfile"]) { return saved }
        let request = state["request"] ?? .emptyObject
        let name = softwareName(state)
        let fallbackText = [name, request["emphasis"].text, request["notes"].text].joined(separator: " ")
        var profile = keywordAppProfile(fallbackText)
        if await resolveLlm("classify") != nil {
            do {
                let result = try await callLlm("classify", dir, ChatJsonRequest(
                    system: CLASSIFY_SYSTEM, user: classifyUserPrompt(softwareName: name, emphasis: request["emphasis"].text, notes: request["notes"].text),
                    schema: CLASSIFY_SCHEMA, temperature: 0.1, maxTokens: 600
                ))
                profile = AppProfile(reason: result["reason"].text, category: result["category"].text, dateMode: result["dateMode"].text, facts: result["facts"].items.map(\.jsString), source: "llm")
            } catch {
                try? await log(dir, "自动分档没有成功（\(messageOf(error))），改按软件名关键词判断", "warn")
            }
        }
        let saved = profile
        _ = try? await update(dir) { draft in
            draft["appProfile"] = saved.json
            appendLog(&draft, "已判断：\(saved.summary)")
        }
        return profile
    }
}
