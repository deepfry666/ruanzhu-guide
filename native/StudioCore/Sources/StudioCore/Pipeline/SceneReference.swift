import Foundation

// MARK: - 场景参考
//
// 做得多的几类软件，各写一小段：常见几屏怎么排、日期怎么处理、哪些数据必须真实、哪些页面要避开。
// 规划时只附上匹配的那一段（按软件名关键词，没有再按自动分档的方向），不再把十几个领域的清单全塞进去。

public struct SceneReference: Sendable {
    public let id: String
    public let match: String
    public let category: String
    public let text: String
}

public let SCENE_REFERENCES: [SceneReference] = [
    SceneReference(id: "traffic-violation", match: #"违章|违法|违规|交规|罚款"#, category: "交通出行", text: """
    常见几屏：首页（已添加车辆、待处理条数）→ 添加车辆 → 违章记录列表 → 违章详情（行为、记分、处理状态）→ 记分规则对照 → 处理指引（去哪里、带什么，只是说明）→ 我的与提醒。
    定位成个人记录和对照工具：不做在线缴罚款、不对接交管系统、不出现交警标志。记分只按现行规定写，违法代码只写确认过的；罚款不写具体金额。违章记录是用户自己登记的，日期用最近几天。
    """),
    SceneReference(id: "transit", match: #"公交|地铁|乘车|行程码|通行码|轨道"#, category: "交通出行", text: """
    常见几屏：首页（附近站点、常用线路）→ 线路查询 → 线路详情（站点列表、首末班时间）→ 换乘方案 → 乘车码展示 → 出行记录 → 我的与设置。
    不出现真实城市公交公司或地铁集团的名称和标志，线路号、站名用通用写法（如「12 路」「人民广场站」）。乘车码只是示意，不写「官方」。出行记录日期用最近几天，首末班时间写成「06:00 / 22:30」这类时刻。
    """),
    SceneReference(id: "freight", match: #"货车|货运|拉货|运货|司机|运满"#, category: "货运配送零工", text: """
    常见几屏：今日工作台（在途、待装货、本月收入）→ 货源大厅（起止城市、货物、运费）→ 货源详情 → 接单确认 → 在途运单（节点时间线）→ 收支账单 → 我的与车辆。
    运单节点按时间先后：接单 → 装货 → 在途 → 卸货 → 签收，时间都在最近几天。运费、里程前后各屏一致，本月收入要等于账单里本月几笔相加。
    """),
    SceneReference(id: "utility", match: #"水电|电费|水费|燃气|抄表"#, category: "生活缴费记账", text: """
    常见几屏：总览（本期用量和费用）→ 抄表录入 → 费用记录 → 本期账单详情 → 用量对比（只比本期和上期）→ 提醒设置 → 计价设置。
    定位成个人记录和计算工具，不做在线缴费。只做本期和上期，不做多个月的趋势。阶梯电价、单价让用户自己在计价设置里填，不写成某地官方价格。日期用最近几天，下次抄表写成「每月 17 日」。
    """),
    SceneReference(id: "social-tax", match: #"社保|医保|养老|公积金|个税|所得税|汇算|退税"#, category: "社保公积金个税证件", text: """
    常见几屏：首页（试算入口、我的参数）→ 参数录入（基数、比例、扣除项）→ 试算结果 → 计算明细 → 对照说明（规则和口径）→ 记录 → 我的与设置。
    定位成个人试算和记录工具：不写在线申报、提取、办理，不出现社保局、税务局、公积金中心。比例和税率只按现行全国口径写，各地不同的写「按当地标准」。试算结果要按页面上的参数算对。
    """),
    SceneReference(id: "secondhand", match: #"二手|闲置"#, category: "购物二手商家", text: """
    常见几屏：首页（推荐、分类）→ 搜索结果 → 商品详情（成色、价格、卖家）→ 发布闲置 → 聊一聊 → 我的订单 → 我的。
    同一件商品的价格、成色各屏一致；订单状态按「待付款 → 待发货 → 待收货 → 已完成」走，时间在最近几天。不出现真实电商平台的名称和标志。
    """),
    SceneReference(id: "drama", match: #"漫剧|短剧|看剧|剧场"#, category: "AI创作与影音", text: """
    常见几屏：首页推荐 → 分类与榜单 → 剧集详情（简介、集数）→ 播放页 → 追剧 / 历史 → 搜索 → 我的。
    剧名、角色名自己起，不用真实影视作品和演员。不显示日期，更新写成「更新至第 12 集」。不出现付费解锁、充值金额。
    """),
    SceneReference(id: "chat-backup", match: #"聊天|备份|复原|互传|换机|克隆"#, category: "手机工具", text: """
    常见几屏：首页（可备份的内容、上次备份）→ 选择内容 → 备份进行中（进度）→ 备份完成回执 → 备份包管理 → 恢复确认 → 我的与设置。
    不出现微信、QQ 等真实应用的名称和图标，写成「聊天记录」「图片视频」。大小、条数前后一致；时间用「刚刚」「今天 10:20」。
    """),
    SceneReference(id: "puzzle-game", match: #"脑|益智|消除|消一消|闯关|通关|解谜|拼图|方格"#, category: "游戏", text: """
    常见几屏：主菜单 → 关卡选择（已解锁、星级）→ 对局进行中（棋盘或题目、计时、步数）→ 本关结算（得分、星级）→ 排行榜 → 道具或成就 → 设置。
    不显示日期；分数、关卡号、星级前后一致。排行榜里的昵称自己起。
    """),
    SceneReference(id: "phone-tool", match: #"清理|连点|点击器|扫码|扫一扫|二维码|投屏|水印|扩音|铃声"#, category: "手机工具", text: """
    常见几屏：首页（主功能入口和状态）→ 主功能设置 → 执行中（进度或实时画面）→ 结果回执 → 记录或作品 → 方案 / 模板 → 设置。
    不出现系统设置界面截图和真实应用图标；大小、数量前后一致；时间用「刚刚」「今天」或时长，不写日期。
    """),
]

/// 只有关键词对不上时，按方向套用的通用参考（游戏、手机工具）；其他参考只按关键词用，免得套到不相干的软件上
private let GENERIC_SCENES: Set<String> = ["puzzle-game", "phone-tool"]

/// 这个项目匹配的场景参考：先按软件名和补充说明的关键词，没有再按自动分档的方向找通用参考；都没有就不加。
public func sceneReference(_ profile: AppProfile, text: String) -> SceneReference? {
    SCENE_REFERENCES.first { Rx.test($0.match, text) } ?? SCENE_REFERENCES.first { $0.category == profile.category && GENERIC_SCENES.contains($0.id) }
}

public func planSceneRule(_ profile: AppProfile, text: String) -> String {
    guard let scene = sceneReference(profile, text: text) else { return "" }
    return "\n\n这类软件的参考做法（按这个软件的实际功能调整，不必照搬）：\n\(scene.text)"
}
