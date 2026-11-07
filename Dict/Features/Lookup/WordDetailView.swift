import SwiftUI

struct WordDetailView: View {
    let result: WordLookupResult
    let onPlay: (String, Int) -> Void
    let onLookup: (String) -> Void
    @State private var examplesExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            phoneticRow
                .padding(.top, 8)
                .padding(.bottom, 18)

            sectionDivider

            detailContent
                .padding(.top, 18)
                .padding(.bottom, 20)
        }
    }

    private var phoneticRow: some View {
        HStack(spacing: 24) {
            if result.word.containsCJK, !result.usPhonetic.isEmpty {
                pronunciation(
                    region: "拼音",
                    phonetic: result.usPhonetic,
                    type: 2
                )
            } else if !result.ukPhonetic.isEmpty {
                pronunciation(
                    region: "英",
                    phonetic: result.ukPhonetic,
                    type: 1
                )
            }

            if !result.word.containsCJK, !result.usPhonetic.isEmpty {
                pronunciation(
                    region: "美",
                    phonetic: result.usPhonetic,
                    type: 2
                )
            }

            Spacer(minLength: 0)
        }
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if result.word.containsCJK, !result.translations.isEmpty {
                translationsSection
            } else {
                definitionsSection
            }

            if !result.wordForms.isEmpty {
                sectionDivider
                    .padding(.vertical, 16)
                wordFormsSection
            }

            if !result.phrases.isEmpty {
                sectionDivider
                    .padding(.vertical, 16)
                phrasesSection
            }

            sectionDivider
                .padding(.vertical, 16)

            examplesSection
        }
    }

    private func pronunciation(region: String, phonetic: String, type: Int) -> some View {
        HStack(spacing: 7) {
            Text(region)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text("/\(phonetic.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/")
                .font(.system(size: 16, design: .serif))
                .textSelection(.enabled)

            Button {
                onPlay(result.word, type)
            } label: {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(region == "拼音" ? "播放中文发音" : "播放\(region)式发音")
        }
    }

    private var translationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(result.translations) { translation in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            onLookup(translation.term)
                        } label: {
                            Text(translation.term)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("查询 \(translation.term)")

                        Button {
                            onPlay(translation.term, 2)
                        } label: {
                            Image(systemName: "speaker.wave.2")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("播放 \(translation.term) 的发音")

                        Spacer()
                    }

                    if !translation.definition.isEmpty {
                        Text(translation.definition)
                            .font(.system(size: 15))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 13)

                if translation.id != result.translations.last?.id {
                    sectionDivider
                }
            }
        }
    }

    private var definitionsSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            if result.definitions.isEmpty {
                Text("暂无释义")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(result.definitions.enumerated()), id: \.offset) { _, definition in
                        Text(definition)
                            .font(.system(size: 15))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                    }
                }
            }

            if !result.examTags.isEmpty {
                HStack(spacing: 7) {
                    ForEach(Array(result.examTags.enumerated()), id: \.offset) { index, tag in
                        if index > 0 {
                            Text("/")
                                .foregroundStyle(.tertiary)
                        }
                        Text(tag)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var wordFormsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("词形变化")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                alignment: .leading,
                spacing: 9
            ) {
                ForEach(Array(result.wordForms.enumerated()), id: \.offset) { _, form in
                    HStack(spacing: 6) {
                        Text(form.name)
                            .foregroundStyle(.secondary)
                        Text(form.value)
                    }
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                }
            }
        }
    }

    private var phrasesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("常见词组")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(result.phrases.prefix(5).enumerated()), id: \.offset) { _, phrase in
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        Text(phrase.headword)
                            .font(.system(size: 14, weight: .medium))
                            .frame(minWidth: 150, alignment: .leading)
                            .textSelection(.enabled)

                        Text(phrase.translation)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    examplesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text("例句")
                        .font(.system(size: 15, weight: .semibold))

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(examplesExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if examplesExpanded {
                if result.examples.isEmpty {
                    Text("暂无例句")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(result.examples) { example in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(example.source)
                                    .font(.system(size: 15))
                                    .lineSpacing(3)
                                    .textSelection(.enabled)

                                Text(example.translation)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)

                            if example.id != result.examples.last?.id {
                                sectionDivider
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(height: 1)
    }
}
