import StudioCore
import SwiftUI

extension EditorTab {
    var coverEditor: some View {
        SettingsGroup(title: "封面介绍（也会写进 TXT 的【软件的主要功能】）", trailing: data.readOnly ? nil : AnyView(HStack(spacing: Spacing.sm) {
            historyMenu("overview") { overview = $0 }
            Button("按原要求修改…") { rewrite = (["overview"], "封面介绍") }.disabled(!editable)
        })) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                TextEditor(text: $overview).textStyle(Typography.body).frame(minHeight: 80).scrollContentBackground(.hidden).disabled(!editable)
                HStack(spacing: Spacing.sm) {
                    Text("\(overview.jsTrimmed.jsLength) 字").textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
                    if Rx.test(#"图\s*[0-9]"#, overview) { warning("正文里不要写「图N」，图注会自动生成") }
                }
            }
            .padding(Spacing.md)
        }
    }

    var designEditor: some View {
        SettingsGroup(title: "设计说明") {
            ForEach(sections.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.sm) {
                        TextField("小节标题", text: Binding(get: { sections.indices.contains(index) ? sections[index].title : "" }, set: { if sections.indices.contains(index) { sections[index].title = $0 } }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .disabled(!editable)
                        Spacer()
                        if !data.readOnly { historyMenu("design-\(index + 1)") { value in if sections.indices.contains(index) { sections[index].text = value } } }
                    }
                    TextEditor(text: Binding(get: { sections.indices.contains(index) ? sections[index].text : "" }, set: { if sections.indices.contains(index) { sections[index].text = $0 } }))
                        .textStyle(Typography.body)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.xs)
                        .background(Palette.fill, in: Radius.shape(Radius.small))
                        .disabled(!editable)
                }
                .padding(Spacing.md)
            }
        }
    }

    // MARK: 历史和保存

    func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").textStyle(Typography.caption).foregroundStyle(Palette.warning)
    }

    /// 这一处以前的文字（自己改之前的、大模型重写之前的），点一下换回来（换回也会自动保存）
    func historyMenu(_ target: String, apply: @escaping (String) -> Void) -> some View {
        let versions = data.contentHistory.filter { $0["target"]?.string == target }
        return Menu {
            ForEach(Array(versions.prefix(30).enumerated()), id: \.offset) { _, version in
                Button("\(formatTime(version["at"]?.string)) · \(version["source"]?.jsString ?? "")：\(version["text"]?.jsString.jsTrimmed.jsSlice(0, 24) ?? "")…") {
                    apply(version["text"]?.jsString ?? "")
                }
            }
        } label: {
            Label(versions.isEmpty ? "历史" : "历史 \(versions.count)", systemImage: "clock.arrow.circlepath")
        }
        .menuStyle(.button)
        .buttonStyle(.textAction)
        .fixedSize()
        .disabled(versions.isEmpty || !editable)
        .help(versions.isEmpty ? "还没有以前的版本" : "换回以前的文字")
    }

}
