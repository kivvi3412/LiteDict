import SwiftUI

struct SettingsView: View {
    @AppStorage(PreferenceKey.openAIBaseURL)
    private var baseURL = "https://api.deepseek.com"
    @AppStorage(PreferenceKey.openAIAPIKey)
    private var apiKey = ""
    @AppStorage(PreferenceKey.openAIModel)
    private var model = "deepseek-flash"
    @AppStorage(PreferenceKey.autoPlayAudio)
    private var autoPlayAudio = false
    @AppStorage(PreferenceKey.reasoningEffort)
    private var reasoningEffort = "low"
    @AppStorage(PreferenceKey.customReasoningEffort)
    private var customReasoningEffort = ""
    @AppStorage(PreferenceKey.glassOpacity)
    private var glassOpacity = 0.86
    @AppStorage(PreferenceKey.highlightOpacity)
    private var highlightOpacity = 0.2
    @AppStorage(PreferenceKey.translationInstructions)
    private var translationInstructions = PromptDefaults.translationInstructions
    @AppStorage(PreferenceKey.contextPromptTemplate)
    private var contextPromptTemplate = PromptDefaults.contextPromptTemplate

    @State private var revealsAPIKey = false
    @State private var showsAdvancedPrompts = false

    var body: some View {
        Form {
                Section("句子翻译服务") {
                    LabeledContent("Base URL") {
                        TextField("", text: $baseURL)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 340, alignment: .trailing)
                    }

                    LabeledContent("API Key") {
                        HStack(spacing: 7) {
                            Group {
                                if revealsAPIKey {
                                    TextField("", text: $apiKey)
                                } else {
                                    SecureField("", text: $apiKey)
                                }
                            }
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: 320, alignment: .trailing)

                            Button {
                                revealsAPIKey.toggle()
                            } label: {
                                Image(systemName: revealsAPIKey ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(revealsAPIKey ? "隐藏 API Key" : "显示 API Key")
                        }
                        .frame(maxWidth: 350, alignment: .trailing)
                    }

                    LabeledContent("模型") {
                        TextField("", text: $model)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 300, alignment: .trailing)
                    }

                    LabeledContent("思考强度") {
                        HStack(spacing: 8) {
                            Picker("", selection: $reasoningEffort) {
                                Text("Low").tag("low")
                                Text("High").tag("high")
                                Text("Max").tag("max")
                                Text("自定义").tag("custom")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 250)

                            if reasoningEffort == "custom" {
                                TextField("自定义强度", text: $customReasoningEffort)
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 120)
                            }
                        }
                    }

                    Text("应用会请求 Base URL 下的 Responses 接口；若服务只支持 Chat Completions，会自动使用兼容回退。API Key 仅保存在本机应用偏好设置中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("查词") {
                    Toggle("查词成功后自动播放美式发音", isOn: $autoPlayAudio)
                }

                Section("外观") {
                    LabeledContent("磨砂玻璃不透明度") {
                        HStack(spacing: 10) {
                            Slider(value: $glassOpacity, in: 0.0...1.0)
                                .frame(width: 220)
                            Text("\(Int((glassOpacity * 100).rounded()))%")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                        }
                    }

                    LabeledContent("黄色高亮强度") {
                        HStack(spacing: 10) {
                            Slider(value: $highlightOpacity, in: 0.05...0.45)
                                .frame(width: 220)
                            Text("\(Int((highlightOpacity * 100).rounded()))%")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }

                Section("高级") {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showsAdvancedPrompts.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(showsAdvancedPrompts ? 90 : 0))
                            Text("默认提示词")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showsAdvancedPrompts ? "已展开" : "已折叠")

                    if showsAdvancedPrompts {
                        VStack(alignment: .leading, spacing: 18) {
                            promptEditor(
                                title: "全文逐句翻译指令",
                                detail: "作为 Responses API 的 instructions 发送，要求模型严格输出双语对齐 JSON。",
                                text: $translationInstructions,
                                defaultText: PromptDefaults.translationInstructions,
                                minHeight: 115
                            )

                            promptEditor(
                                title: "划词上下文解析模板",
                                detail: "使用 {input_select} 表示选中文本，使用 {all_input} 表示全文。",
                                text: $contextPromptTemplate,
                                defaultText: PromptDefaults.contextPromptTemplate,
                                minHeight: 250
                            )
                        }
                        .padding(.vertical, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private func promptEditor(
        title: String,
        detail: String,
        text: Binding<String>,
        defaultText: String,
        minHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("恢复默认") {
                    text.wrappedValue = defaultText
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: minHeight)
                .background(
                    Color(nsColor: .textBackgroundColor).opacity(0.74),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                }
        }
    }
}
