// 各步骤给大模型的系统提示词与 JSON Schema，直接在此维护。

import Foundation

public let GATE_SYSTEM = #"""
你是严格的移动 App 截图验收员。逐字查看截图，回答：
- singleScreen：是否只有一个完整的手机界面（不是拼图、不是多屏、不是设计稿合集）。
- portraitApp：是否是竖屏 App 界面本身（不是带实体手机外壳/边框的效果图、不是海报）。
- brandFound：界面里是否出现了下面列出的任何禁词，或者明显表示这些禁词的 logo / wordmark / 艺术字。只看图上真实可见的内容，看不清的不要猜。
- brandEvidence：如果 brandFound 为 true，写出看到的文字和位置。
- screenTitle：界面顶部标题。
- visibleText：图上所有清晰可读的文字，逐条原样抄录（最多 80 条）。
- inventory：用中文详细描述这个界面上可见的区域、控件、数据和状态（谁在哪、显示了什么数值），供后续写说明文字用，200–500 字。
- warnings：非阻断的问题，例如中文乱码或错字、文字重叠截断、出现安卓导航栏（要求 iPhone 时）、实体手机外壳、内容过于稀疏、和其他屏风格明显不一致、日期过旧等。没有就给空数组。
"""#

public let CONTENT_SYSTEM = #"""
你是中文软件用户手册撰写专家，为手机 App 的《用户手册》写正文。
规则：
1. 封面介绍 overview：180–300 个字符，说明软件定位、目标用户、核心模块和整体使用流程，领域专属；禁止「进入软件、查看首页、执行核心操作、整理记录、查看统计到管理个人设置」这类通用骨架句。
2. 每屏功能说明 text：至少 {floor} 个字符（按普通字符串长度计，不是只数汉字），建议 330–450 个字符；描述该屏可见的数据、控件、操作步骤、反馈与校验、异常处理、与下一界面或返回的衔接。必须与截图实际内容一致（以「截图实际内容」为准，计划里有但截图没有的不要写）。
3. 各屏正文独立，不要套话复用，不要写同样的结尾。
4. 任何地方都不要出现「图1」「图2」这类「图+数字」字样。
5. 不要说这是虚构、示例或假想的软件；不要提到截图、AI、生成。
6. 简体中文，可分 1–3 段（用换行分隔）。title 用计划里的界面标题，除非截图标题明显不同。
"""#

public let DESIGN_SYSTEM = #"""
你为中文软件用户手册撰写「软件设计说明」章节，内容要和给出的规划一致、领域专属，不臆造厂商或实现细节。
按顺序输出五节：
1. 软件基本处理流程：入口、校验、核心操作、持久化、反馈、退出或恢复。
2. 程序系统组织结构：表现层、应用/服务层、领域层、数据访问层、集成职责。
3. 功能模块划分：把功能规划划分为内聚模块，说明职责和交互。
4. 接口设计：只写领域或用户要求支持的内部/外部接口，说明用途、输入、输出、错误。
5. 数据结构设计：核心实体、标识、关系、状态字段、时间戳、保留策略。
每节 250–600 字，可用换行分段；不要出现「图N」字样，不要说软件是虚构的。
"""#

public let PROMPT_EDIT_SYSTEM = #"""
你负责按修改要求改写一份手机 App 截图的生图提示词（英文为主，界面上的中文原样保留）。
规则：
1. 只改修改要求涉及的部分，其余描述（尺寸、状态栏、配色、导航、示例数据等）保持原样，输出完整的新提示词。
2. 修改要求是中文的，改写进提示词时用英文描述，界面上要出现的中文文字原样写。
3. 原提示词里说明「不能在界面上显示软件名」的句子必须保留；不要在别处新增软件名、App 名、版本号、logo。
"""#

public let PLAN_SCHEMA: JSON = try! JSON.parse(#"""
{
  "type": "object",
  "required": [
    "profile",
    "coverageReason",
    "features",
    "uiContract",
    "screens"
  ],
  "properties": {
    "profile": {
      "type": "object",
      "required": [
        "domain",
        "targetUser",
        "coreFlow"
      ],
      "properties": {
        "domain": {
          "type": "string",
          "minLength": 2
        },
        "targetUser": {
          "type": "string",
          "minLength": 2
        },
        "coreFlow": {
          "type": "string",
          "minLength": 2
        }
      }
    },
    "coverageReason": {
      "type": "string",
      "minLength": 4
    },
    "features": {
      "type": "array",
      "minItems": 1,
      "items": {
        "type": "object",
        "required": [
          "name",
          "screenId"
        ],
        "properties": {
          "name": {
            "type": "string"
          },
          "screenId": {
            "type": "string"
          },
          "tier": {
            "type": "string"
          }
        }
      }
    },
    "uiContract": {
      "type": "object",
      "required": [
        "visualStyle",
        "palette",
        "typography",
        "navigation"
      ],
      "properties": {
        "visualStyle": {
          "type": "string"
        },
        "palette": {
          "type": "object",
          "required": [
            "primary",
            "background",
            "surface",
            "text"
          ]
        },
        "typography": {
          "type": "string"
        },
        "radius": {
          "type": "string"
        },
        "shadow": {
          "type": "string"
        },
        "density": {
          "type": "string"
        },
        "navigation": {
          "type": "object",
          "required": [
            "type",
            "labels"
          ],
          "properties": {
            "type": {
              "type": "string"
            },
            "labels": {
              "type": "array",
              "items": {
                "type": "string"
              }
            },
            "iconSemantics": {
              "type": "array",
              "items": {
                "type": "string"
              }
            }
          }
        }
      }
    },
    "screens": {
      "type": "array",
      "minItems": 1,
      "items": {
        "type": "object",
        "required": [
          "id",
          "title",
          "pageType",
          "mustShow",
          "sampleData",
          "textContract",
          "visualBrief"
        ],
        "properties": {
          "id": {
            "type": "string",
            "pattern": "^screen-\\d{2}$"
          },
          "title": {
            "type": "string",
            "minLength": 2,
            "maxLength": 20
          },
          "pageType": {
            "type": "string"
          },
          "activeTab": {
            "type": [
              "string",
              "null"
            ]
          },
          "mustShow": {
            "type": "array",
            "minItems": 3,
            "items": {
              "type": "string"
            }
          },
          "sampleData": {
            "type": "array",
            "minItems": 2,
            "items": {
              "type": "string"
            }
          },
          "textContract": {
            "type": "object",
            "required": [
              "entry",
              "action",
              "feedback",
              "exception",
              "exit"
            ],
            "properties": {
              "entry": {
                "type": "string"
              },
              "action": {
                "type": "string"
              },
              "feedback": {
                "type": "string"
              },
              "exception": {
                "type": "string"
              },
              "exit": {
                "type": "string"
              }
            }
          },
          "visualBrief": {
            "type": "string",
            "minLength": 120
          }
        }
      }
    }
  }
}
"""#)

public let GATE_SCHEMA: JSON = try! JSON.parse(#"""
{
  "type": "object",
  "required": [
    "singleScreen",
    "portraitApp",
    "brandFound",
    "visibleText",
    "inventory",
    "warnings"
  ],
  "properties": {
    "singleScreen": {
      "type": "boolean"
    },
    "portraitApp": {
      "type": "boolean"
    },
    "brandFound": {
      "type": "boolean"
    },
    "brandEvidence": {
      "type": "string"
    },
    "screenTitle": {
      "type": "string"
    },
    "visibleText": {
      "type": "array",
      "items": {
        "type": "string"
      }
    },
    "inventory": {
      "type": "string",
      "minLength": 20
    },
    "warnings": {
      "type": "array",
      "items": {
        "type": "string"
      }
    }
  }
}
"""#)

public let CONTENT_SCHEMA: JSON = try! JSON.parse(#"""
{
  "type": "object",
  "required": [
    "screens"
  ],
  "properties": {
    "overview": {
      "type": "string"
    },
    "screens": {
      "type": "array",
      "items": {
        "type": "object",
        "required": [
          "id",
          "title",
          "text"
        ],
        "properties": {
          "id": {
            "type": "string"
          },
          "title": {
            "type": "string"
          },
          "text": {
            "type": "string"
          }
        }
      }
    }
  }
}
"""#)

public let DESIGN_SCHEMA: JSON = try! JSON.parse(#"""
{
  "type": "object",
  "required": [
    "sections"
  ],
  "properties": {
    "sections": {
      "type": "array",
      "minItems": 3,
      "items": {
        "type": "object",
        "required": [
          "title",
          "text"
        ],
        "properties": {
          "title": {
            "type": "string"
          },
          "text": {
            "type": "string",
            "minLength": 120
          }
        }
      }
    }
  }
}
"""#)

public let PROMPT_EDIT_SCHEMA: JSON = try! JSON.parse(#"""
{
  "type": "object",
  "required": [
    "prompt"
  ],
  "properties": {
    "prompt": {
      "type": "string",
      "minLength": 200
    }
  }
}
"""#)
