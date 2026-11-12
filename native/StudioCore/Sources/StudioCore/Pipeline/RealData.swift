import Foundation

// MARK: - 内置真实数据
//
// 截图里会出现、现实中有标准答案的数据。规划时自动分档命中这些领域，就把这份数据给大模型，只能从里面选；
// 没有内置数据的领域（火车车次、油价、驾考题目等）按「拿不准的不写具体值」处理。
// 每份数据写明出处；规定变了要更新这里。

public struct RealDataSet: Sendable {
    public let id: String
    /// 分档 facts 或软件名里出现这些字样时用这一份
    public let match: String
    public let title: String
    public let lines: [String]
    public let source: String
    /// 额外规定（写进规划）
    public let rule: String
}

public let REAL_DATA: [RealDataSet] = [
    RealDataSet(
        id: "traffic-points", match: #"违法|违章|违规|记分|交规|罚款"#, title: "交通违法记分（现行）",
        lines: [
            "记12分：饮酒后驾驶机动车；在高速公路或城市快速路上倒车、逆行、穿越中央分隔带掉头；使用伪造、变造或其他车辆的号牌、行驶证、驾驶证",
            "记9分：在高速公路或城市快速路上违法停车；未悬挂号牌或故意遮挡、污损号牌；驾驶与准驾车型不符的机动车",
            "记6分：不按交通信号灯指示通行（闯红灯）；驾驶证被暂扣、扣留期间驾驶机动车；在高速公路或城市快速路上违法占用应急车道行驶",
            "记3分：在高速公路或城市快速路上不按规定车道行驶；不按规定超车、让行；驾驶时拨打、接听手持电话；经过人行横道不按规定减速、停车、避让行人；在高速公路上低于规定最低时速行驶",
            "记1分：不按规定使用灯光；违反禁令标志、禁止标线指示；行驶中未按规定系安全带；驾驶摩托车不戴安全头盔；不按规定会车",
            "不记分：违反规定停放、临时停车（未妨碍通行时）",
            "违法代码只确认：1625 不按交通信号灯指示通行（闯红灯），记6分",
        ],
        source: "《道路交通安全违法行为记分管理办法》（公安部令第163号，2022年4月1日起施行）",
        rule: "违法代码只能写上面确认过的；其他违法行为不写代码，只写行为名称和记分。罚款各地标准不同，不写具体金额，写「按当地标准」或不写。"
    ),
    RealDataSet(
        id: "iit", match: #"个税|所得税|汇算|退税|专项附加"#, title: "个人所得税（综合所得，现行）",
        lines: [
            "基本减除费用：每年 60000 元（每月 5000 元）",
            "年度税率：不超过 36000 元 3%（速算扣除数 0）；36000–144000 元 10%（2520）；144000–300000 元 20%（16920）；300000–420000 元 25%（31920）；420000–660000 元 30%（52920）；660000–960000 元 35%（85920）；超过 960000 元 45%（181920）",
            "专项附加扣除（每月）：子女教育每个子女 2000 元；3 岁以下婴幼儿照护每个婴幼儿 2000 元；赡养老人 3000 元（非独生子女分摊，每人不超过 1500 元）；住房贷款利息 1000 元；住房租金按城市 1500 / 1100 / 800 元",
            "继续教育：学历（学位）每月 400 元；职业资格取得证书当年 3600 元",
            "大病医疗：一年内自付超过 15000 元的部分，每年最多 80000 元",
        ],
        source: "《中华人民共和国个人所得税法》；《国务院关于提高个人所得税有关专项附加扣除标准的通知》（国发〔2023〕13号）",
        rule: "计算结果要按上面的税率和扣除标准算对。"
    ),
    RealDataSet(
        id: "social-insurance", match: #"社保|医保|养老|公积金"#, title: "社保和公积金（全国通用口径）",
        lines: [
            "基本养老保险：单位 16%，个人 8%",
            "职工基本医疗保险：个人一般 2%",
            "住房公积金：单位和个人缴存比例各 5%–12%，两者相同",
            "缴费基数、失业保险个人比例、医保单位比例各地不同",
        ],
        source: "国务院办公厅《降低社会保险费率综合方案》（国办发〔2019〕13号）；《住房公积金管理条例》及住房城乡建设部等部门关于缴存比例的规定",
        rule: "各地不同的数（缴费基数上下限、失业保险比例、医保单位比例、当地平均工资）不写具体值，写「按当地标准」或让用户自己填。"
    ),
]

/// 这个项目要用的内置数据：分档 facts 或软件名、补充说明里命中的。
public func realDataSets(_ profile: AppProfile, text: String) -> [RealDataSet] {
    let haystack = (profile.facts + [text]).joined(separator: "\n")
    return REAL_DATA.filter { Rx.test($0.match, haystack) }
}

/// 写进规划的真实数据规定：有内置数据的给出数据，只能从里面选；没有的拿不准就不写具体值。
public func planRealDataRule(_ profile: AppProfile, text: String) -> String {
    let sets = realDataSets(profile, text: text)
    guard !profile.facts.isEmpty || !sets.isEmpty else { return "" }
    var lines = ["\n\n真实数据（现实中有标准答案，不能编）："]
    for set in sets {
        lines.append("【\(set.title)】出处：\(set.source)")
        lines.append(contentsOf: set.lines.map { "- \($0)" })
        lines.append(set.rule)
    }
    lines.append(sets.isEmpty
        ? "涉及\(profile.facts.joined(separator: "、"))时，只写你确定无误的常见条目；拿不准的不写具体编号、金额、比例，用名称或「详情」代替。"
        : "界面上用到这些数据时只能从上面选，不要另编条目、代码或数值；上面没有的，不写具体编号、金额、比例。")
    return lines.joined(separator: "\n")
}

/// 交通违法代码：文字里「代码」「违法代码」后面跟的 4–5 位数字，不在确认过的清单里就算编的。
public let KNOWN_TRAFFIC_CODES: Set<String> = ["1625", "16250"]

public func unknownTrafficCodes(_ texts: [String]) -> [String] {
    var found: [String] = []
    for text in texts {
        for match in Rx.matches(#"(?:违法代码|违章代码|代码)[:：\s]*([0-9]{4,5})(?![0-9])"#, text) {
            if let code = match.count > 1 ? match[1] : nil, !KNOWN_TRAFFIC_CODES.contains(code) { found.append(code) }
        }
        // 列表里常见的「1345 违反禁止标线」写法：4–5 位数字后面紧跟违法行为
        for match in Rx.matches(#"(?<![0-9¥￥.])([1-6][0-9]{3}0?)\s+(?:驾驶|不按|违反|未按|未|机动车|超速|逆行|闯|占用|违规|违法)"#, text) {
            if let code = match.count > 1 ? match[1] : nil, !KNOWN_TRAFFIC_CODES.contains(code) { found.append(code) }
        }
    }
    return uniqued(found)
}

/// 程序复核：涉及交通违法的项目，规划或截图里出现没确认过的违法代码。
public func trafficCodeProblems(_ profile: AppProfile?, _ label: String, _ texts: [String]) -> [String] {
    guard let profile, realDataSets(profile, text: "").contains(where: { $0.id == "traffic-points" }) else { return [] }
    let codes = unknownTrafficCodes(texts)
    return codes.isEmpty ? [] : ["\(label)里有没确认过的违法代码：\(codes.prefix(6).joined(separator: "、"))。违法代码只能写 1625（闯红灯）；其他违法行为不写代码，只写行为名称和记分"]
}
