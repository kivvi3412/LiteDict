# LiteDict

**LiteDict** 是一款专为 macOS 原生打造的轻量级词典与 AI 沉浸式双语翻译工具。基于 **SwiftUI + AppKit** 构建，兼具原生毛玻璃视觉美学、毫秒级词典检索体验与流式大模型长文逐句对齐能力。

---

## 核心功能

### 1. 智能聚合查词（查词模式）
- **多源聚合词典**：优先整合有道词典（英美音标、在线真人发音、词性分组释义、考纲标签如 CET4/CET6/考研/IELTS/TOEFL、词形变化如过去式/复数/比较级），并支持回退至 macOS 原生系统词典（`CoreServices.DCSCopyTextDefinition`）。
- **实时前缀联想**：输入时自动防抖触发候选词联想，支持键盘 `↑` / `↓` 方向键无缝切换候选词、`Enter` 确认查询、`Esc` 收起联想列表。
- **零闪烁双层缓存**：内置 **内存 + 磁盘（`UserDefaults`）** 双层词条结果缓存，历史词条切换、窗口关闭重开均在首帧直接渲染上次查询结果，告别重复加载闪烁。
- **发音自动播放**：支持英音/美音一键朗读，可在设置中开启「查词成功后自动播放美式发音」。

### 2. AI 双栏长文翻译与划词精读（翻译模式）
- **中英双向自动识别**：自动检测输入文本语种（中译英 / 英译中），无需手动切换源语言与目标语言。
- **流式逐句对齐（SSE Streaming）**：
  - 实时展示模型思考过程（Reasoning / Thinking Delta）与增量译文预览；
  - 翻译完成后自动通过归一化文本索引将原文与译文进行逐句精准对齐。
- **左定右跳联动定位**：
  - 鼠标悬停或光标移动至左侧原文任意句子时，左右两侧对应句子同步高亮；
  - 右侧译文面板自动平滑滚动并将目标译句居中展示。
- **自由选择与中文输入法兼容**：
  - 右侧译文采用统一只读富文本视图，支持跨句自由拖拽选词与 `Cmd + A` 全选复制；
  - 左侧输入框完整适配 macOS 原生中文输入法（IME Marked Text 保护）。
- **划词上下文深度解析**：
  - 在左侧原文中划选任意词汇、短语或长难句（占全文比例 ≤ 90%），右侧自动切换为 **AI 语境精读模式**；
  - 结合所选片段所在的原句位置、出现频次与全文语境，流式输出定制化 Markdown 解析（语境义、语法结构、地道搭配等）。
- **跨标签状态与滚动位置保持**：在「查词」与「翻译」标签页之间来回切换时，完整保留原文、译文及左右两侧的滚动条位置。

### 3. 个性化与高阶配置
- **OpenAI / DeepSeek 兼容接口**：支持自定义 `Base URL`、`API Key`、模型名称（如 `deepseek-flash`、`gpt-4.1-mini` 等）以及思考强度（`None` / `Low` / `High` / `Max`）。
- **自动协议适配**：优先调用 OpenAI `v1/responses` 接口（支持 JSON Schema 结构化输出与 Reasoning Summary），并对不支持 Responses API 的服务端自动降级至 `v1/chat/completions`。
- **视觉与提示词定制**：支持无级调节窗口磨砂玻璃不透明度、句子黄色高亮强度，以及自定义「全文逐句翻译指令」与「划词上下文解析模板」。

---

## 项目架构

项目采用 **Feature-based Modular Architecture（按特性分层的模块化架构）**，严格遵循单一职责原则（SRP），将 UI 声明、响应式状态机、复杂文本算法、AppKit 桥接控件与底层网络服务彻底解耦：

```text
Dict/
├── App/                                    # 应用入口与窗口基础设施层
│   ├── LiteDictApp.swift                   # App 生命周期、主窗口/设置窗口路由与工具栏切换
│   └── WindowComponents.swift              # NSVisualEffectView 磨砂玻璃、透明标题栏与全局 Esc 监听
├── Models/                                 # 领域模型与常量定义层
│   ├── AppModels.swift                     # 全局枚举 (FeatureTab)、偏好设置 Key、默认 Prompt 模板
│   ├── LookupModels.swift                  # 查词领域模型、有道 API DTO、系统原生词典文本解析器
│   └── TranslationModels.swift             # 翻译领域模型、OpenAI 流式/非流式 DTO、语向检测逻辑
├── Services/                               # 数据与网络服务层
│   ├── Services.swift                      # 统一服务门面 (Facade) 与 AVPlayer 在线发音播放器
│   ├── NativeDictionaryService.swift       # macOS CoreServices 原生词典查询服务
│   ├── YoudaoDictionaryService.swift       # 有道词典联想、JSON 结构化解析与 HTML 抓取兜底服务
│   └── AITranslationService.swift          # OpenAI/DeepSeek SSE 流式通信、增量 JSON 译文提取服务
└── Features/                               # 业务功能特性层
    ├── Lookup/                             # 【查词模块】
    │   ├── LookupHistoryStore.swift        # 查词历史记录、内存 + 磁盘双层词条缓存管理
    │   ├── WordLookupView.swift            # 查词主视图、防抖搜索、候选联想下拉交互
    │   └── WordDetailView.swift            # 音标栏、释义卡片、词形变化、考试标签与中英混排视图
    ├── Translate/                          # 【翻译模块】
    │   ├── SentenceTranslateStore.swift    # 翻译模块状态中心、流式任务编排、滚动偏移量保持
    │   ├── SentenceTranslateView.swift     # 纯声明式双栏翻译主视图
    │   ├── SentenceAlignmentEngine.swift   # 文本归一化索引 (NormalizedTextIndex) 与双语句子对齐算法
    │   └── SentenceTextViews.swift         # AppKit NSTextView 桥接、IME 保护、句子高亮绘制与平滑居中滚动
    └── Settings/                           # 【设置模块】
        └── SettingsView.swift              # 偏好设置面板与高级 Prompt 模板编辑器
```

### 架构设计亮点

1. **单向数据流与状态隔离**：
   - 查词状态由 `LookupHistoryStore` 管理，翻译状态由 `SentenceTranslateStore` 管理；
   - 视图层（`WordLookupView`、`SentenceTranslateView`）仅负责声明式 UI 绑定与事件转发，不包含网络请求或复杂文本切分逻辑。
2. **纯算法引擎独立封装**：
   - `SentenceAlignmentEngine` 与 `NormalizedTextIndex` 独立封装了去标点/忽略大小写/跨行空白的双向字符映射索引，即使大模型返回的原句存在细微标点或引号差异，也能精确反查出原文中的 `NSRange`。
3. **SwiftUI 与 AppKit 深度协同**：
   - 针对 SwiftUI 原生 `TextEditor` / `Text` 在精细字符坐标命中、IME 输入法标记态控制、局部矩形高亮及平滑居中滚动上的局限，`SentenceTextViews.swift` 封装了高性能的 `SentenceHighlightingTextView`（继承自 `NSTextView`），在保持 SwiftUI 声明式接口的同时实现原生级文本交互。

---

## 编译与运行

### 环境要求
- macOS 14.0+
- Xcode 16.0+

### 命令行构建 Release 版本
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Dict.xcodeproj \
  -target Dict \
  -configuration Release \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  build
```

编译产物位于 `build/Release/LiteDict.app`，可直接复制至 `/Applications/LiteDict.app` 使用。
