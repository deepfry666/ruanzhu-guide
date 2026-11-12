import Foundation

// MARK: - 规划提示词（1.7.0 起）
//
// 和 Electron 版原样生成的 PLAN_SYSTEM 相比：去掉十几个领域的清单（改由自动分档决定方向），
// 先写数据底账 ledger 再写各屏，各屏示例数据只能取自底账；画面描述缩短，界面文字放进示例数据。
// 日期、真实数据的规定按自动分档只加载需要的那一段。

public let PLAN_SYSTEM_V3 = """
你是资深移动产品经理兼 UI 设计师，为中文《软件用户手册》规划手机 App 界面截图。
1. 界面必须是这个领域专属的，不要做成能套到别的产品上的通用模板，也不要几屏都是仪表盘变体。
2. 屏数优先按用户指定；未指定时 7 屏，按功能覆盖增减（5–10 屏），在 coverageReason 说明理由。顺序参考：入口/引导 → 主页总览 → 核心输入或设置 → 核心操作或查询 → 记录或列表 → 详情/结果/回执 → 我的/设置。
3. 先写 ledger（数据底账）：整个 App 共用的一小组数据（记录、条目、关卡、作品、订单等），每条一行，写清名称、数值、状态，有日期的写日期。各屏 sampleData 里的数据只能取自 ledger，同一条数据在各屏一致；条数、合计、「本月」「近 7 天」这类汇总必须由 ledger 算出来，范围内有几条就写几条。没有这类数据的软件 ledger 可以只写几项分数、设置值。
4. 每屏有独立的状态、操作、反馈和目的，顺序可导航。界面标签简短。
5. 界面里不能出现软件名、App 名、版本号、名称型 logo；设置页、我的页不要「关于本软件」「当前版本」「检查更新」。
6. title：界面中文名，2–12 个字，各屏不重复。
7. visualBrief：英文，60–120 个单词，只写这一屏的布局、组件和状态；界面上要出现的中文文字放进 sampleData 和 mustShow，不要在 visualBrief 里重复成段的中文。
8. uiContract 是所有屏共享的视觉约束：visualStyle（英文短语）、palette（primary/background/surface/text 必填，可加 muted/warning/success/danger，均为 #RRGGBB）、typography、radius、shadow、density、navigation（type 取 bottom-tabs / stack / none，labels 为底部导航中文标签，iconSemantics 为英文图标含义）。
9. textContract 用中文，每项一句话：entry 从哪里进入、action 主要操作、feedback 成功反馈、exception 异常处理、exit 下一步/返回。
"""

public let PLAN_SCHEMA_V3: JSON = {
    var schema = PLAN_SCHEMA
    schema["required"] = .array(schema["required"].items + ["ledger"])
    schema["properties"]?["ledger"] = .obj(["type": "array", "minItems": 1, "items": .obj(["type": "string"])])
    return schema
}()

public func planUserPromptV3(softwareName: String, screenCount: Int?, emphasis: String, notes: String, platform: String, profile: AppProfile) -> String {
    [
        "软件名（仅作上下文，界面里不能显示）：\(softwareName)",
        "类型：\(profile.category)",
        "平台：\(platform)",
        screenCount.map { "截图屏数：必须正好 \($0) 屏" } ?? "截图屏数：未指定，按功能覆盖决定（默认 7 屏）",
        emphasis.isEmpty ? "" : "用户强调的功能：\(emphasis)",
        notes.isEmpty ? "" : "补充说明：\(notes)",
        "",
        "输出 JSON 结构（按这个顺序写，先写 ledger 再写 screens）：",
        ##"{"profile":{"domain":"","targetUser":"","coreFlow":"A—B—C"},"coverageReason":"","features":[{"name":"","screenId":"screen-01","tier":"core"}],"uiContract":{"visualStyle":"","palette":{"primary":"#2563EB","background":"#F5F7FB","surface":"#FFFFFF","text":"#172033"},"typography":"","radius":"","shadow":"","density":"","navigation":{"type":"bottom-tabs","labels":[],"iconSemantics":[]}},"ledger":[""],"screens":[{"id":"screen-01","title":"","pageType":"","activeTab":null,"mustShow":[],"sampleData":[],"textContract":{"entry":"","action":"","feedback":"","exception":"","exit":""},"visualBrief":""}]}"##,
    ].filter { !$0.isEmpty }.joined(separator: "\n")
}
