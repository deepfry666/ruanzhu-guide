/// ProjectStatus 的开放取值集合，未知值不会被替换或丢弃。
public struct ProjectStatus: RawRepresentable, Sendable, Hashable {
    /// 未经规范化的原始字符串。
    public var rawValue: String
    /// 接受所有字符串，兼容未来版本。
    public init(rawValue: String) { self.rawValue = rawValue }
    /// 现有取值 `idle`。
    public static let idle = Self(rawValue: "idle")
    /// 现有取值 `running`。
    public static let running = Self(rawValue: "running")
    /// 现有取值 `done`。
    public static let done = Self(rawValue: "done")
    /// 现有取值 `waiting`。
    public static let waiting = Self(rawValue: "waiting")
    /// 现有取值 `needs-attention`。
    public static let needsAttention = Self(rawValue: "needs-attention")
    /// 现有取值 `canceled`。
    public static let canceled = Self(rawValue: "canceled")
    /// 现有取值 `missing`。
    public static let missing = Self(rawValue: "missing")
    /// 现有取值 `readonly`。
    public static let readonly = Self(rawValue: "readonly")
    /// 现有取值 `submitted`。
    public static let submitted = Self(rawValue: "submitted")
}

/// StepStatus 的开放取值集合，未知值不会被替换或丢弃。
public struct StepStatus: RawRepresentable, Sendable, Hashable {
    /// 未经规范化的原始字符串。
    public var rawValue: String
    /// 接受所有字符串，兼容未来版本。
    public init(rawValue: String) { self.rawValue = rawValue }
    /// 现有取值 `pending`。
    public static let pending = Self(rawValue: "pending")
    /// 现有取值 `running`。
    public static let running = Self(rawValue: "running")
    /// 现有取值 `done`。
    public static let done = Self(rawValue: "done")
    /// 现有取值 `skipped`。
    public static let skipped = Self(rawValue: "skipped")
    /// 现有取值 `review`。
    public static let review = Self(rawValue: "review")
    /// 现有取值 `failed`。
    public static let failed = Self(rawValue: "failed")
}

/// PipelineStepName 的开放取值集合，未知值不会被替换或丢弃。
public struct PipelineStepName: RawRepresentable, Sendable, Hashable {
    /// 未经规范化的原始字符串。
    public var rawValue: String
    /// 接受所有字符串，兼容未来版本。
    public init(rawValue: String) { self.rawValue = rawValue }
    /// 现有取值 `plan`。
    public static let plan = Self(rawValue: "plan")
    /// 现有取值 `prompts`。
    public static let prompts = Self(rawValue: "prompts")
    /// 现有取值 `images`。
    public static let images = Self(rawValue: "images")
    /// 现有取值 `gate`。
    public static let gate = Self(rawValue: "gate")
    /// 现有取值 `content`。
    public static let content = Self(rawValue: "content")
    /// 现有取值 `design`。
    public static let design = Self(rawValue: "design")
    /// 现有取值 `receipt`。
    public static let receipt = Self(rawValue: "receipt")
    /// 现有取值 `build`。
    public static let build = Self(rawValue: "build")
}

/// QueueStatus 的开放取值集合，未知值不会被替换或丢弃。
public struct QueueStatus: RawRepresentable, Sendable, Hashable {
    /// 未经规范化的原始字符串。
    public var rawValue: String
    /// 接受所有字符串，兼容未来版本。
    public init(rawValue: String) { self.rawValue = rawValue }
    /// 现有取值 `queued`。
    public static let queued = Self(rawValue: "queued")
    /// 现有取值 `running`。
    public static let running = Self(rawValue: "running")
    /// 现有取值 `done`。
    public static let done = Self(rawValue: "done")
    /// 现有取值 `needs-attention`。
    public static let needsAttention = Self(rawValue: "needs-attention")
    /// 现有取值 `paused`。
    public static let paused = Self(rawValue: "paused")
    /// 现有取值 `failed`。
    public static let failed = Self(rawValue: "failed")
}
