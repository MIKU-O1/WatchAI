import SwiftUI

struct SettingsEditor: View {
    @ObservedObject var store: SettingsStore
    var isCallActive = false
    var diagnostics = ""
    var onSaved: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var searchKey = ""
    @State private var webSearchEnabled = false
    @State private var webSearchType: VoiceSettings.WebSearchType = .custom
    @State private var voice = VoiceSettings.defaultVoice
    @State private var bandwidthMode: VoiceSettings.BandwidthMode = .economy
    @State private var uploadRate: VoiceSettings.UploadRate = .balanced
    @State private var suppressSilence = true
    @State private var instructions = ""

    var body: some View {
        Form {
            if isCallActive {
                Section {
                    Text("通话中，结束后可修改设置。右滑返回对话。")
                        .font(.footnote).foregroundStyle(Theme.mint)
                }
            }
            if !diagnostics.isEmpty {
                Section("本次通话") {
                    Text(diagnostics).font(.footnote)
                    Text("应用数据统计包含 JSON，不包含 TLS 和网络协议开销；上传量按提交计算，不代表服务端全部收到。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Group {
                Section {
                    SecureField("豆包语音 API Key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("使用豆包语音控制台的 API Key，并开通全双工实时语音服务。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("连接豆包") }
                Section("联网搜索") {
                    Toggle("允许联网搜索", isOn: $webSearchEnabled)
                    if webSearchEnabled {
                        Picker("搜索版本", selection: $webSearchType) {
                            Text("Custom（较快）").tag(VoiceSettings.WebSearchType.custom)
                            Text("Global（全球搜索）").tag(VoiceSettings.WebSearchType.global)
                        }
                        SecureField("豆包搜索 API Key", text: $searchKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("需在「豆包搜索」控制台开通所选版本，创建对应搜索 Key。搜索会另行计费。可以直接说：帮我联网搜索……")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("网络与流量") {
                    Picker("音频模式", selection: $bandwidthMode) {
                        Text("省流量（默认）").tag(VoiceSettings.BandwidthMode.economy)
                        Text("兼容模式").tag(VoiceSettings.BandwidthMode.compatible)
                    }
                    if bandwidthMode == .economy {
                        Picker("上传码率", selection: $uploadRate) {
                            Text("12 kbps（默认）").tag(VoiceSettings.UploadRate.balanced)
                            Text("8 kbps（试验）").tag(VoiceSettings.UploadRate.low)
                            Text("16 kbps（清晰）").tag(VoiceSettings.UploadRate.clear)
                        }
                    }
                    Toggle("静音时减少上传", isOn: $suppressSilence)
                    Text("自动检测说话并保留开头与句尾，持续监听但不上传长时间静音。轻声漏识别时可关闭；设备不支持所选码率时使用可用码率。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("省流量模式压缩双方语音，保留实时字幕。网络波动会自动缓冲、重连；兼容模式流量较大。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("声音") {
                    Picker("音色", selection: $voice) {
                        Text("Vivi · 实时女声（默认）").tag(VoiceSettings.defaultVoice)
                        Text("小何 · 女声").tag("zh_female_xiaohe_jupiter_bigtts")
                        Text("小天 · 男声").tag("zh_male_xiaotian_jupiter_bigtts")
                    }
                    Text("这里是豆包开放接口的实时音色，与豆包 App 的朗读音色可能不同。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("回答风格") {
                    TextField("提示词", text: $instructions)
                }
                if let error = store.error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                Section {
                    Button("保存配置") {
                        var settings = VoiceSettings()
                        settings.voice = voice
                        settings.bandwidthMode = bandwidthMode
                        settings.uploadRate = uploadRate; settings.suppressSilence = suppressSilence
                        settings.webSearchEnabled = webSearchEnabled
                        settings.webSearchType = webSearchType
                        settings.instructions = instructions
                        if store.save(key: key, searchKey: searchKey, settings: settings) {
                            if let onSaved { onSaved() } else { dismiss() }
                        }
                    }
                    .foregroundStyle(Theme.mint)
                    .disabled(voice.isEmpty || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (webSearchEnabled && searchKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                } footer: {
                    Text("API Key 保存在系统钥匙串中。语音和字幕发送到豆包服务，API 调用会消耗试用额度或产生费用。")
                }
            }
            .disabled(isCallActive || store.isLoading)
        }
        .navigationTitle("豆包设置")
        .onAppear(perform: loadSettings)
        .onChange(of: store.isLoading) { _, loading in
            if !loading { loadSettings() }
        }
        .onChange(of: isCallActive) { _, active in
            if !active { loadSettings() }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.mint)
    }

    private func loadSettings() {
        key = store.apiKey
        searchKey = store.searchAPIKey
        webSearchEnabled = store.settings.webSearchEnabled
        webSearchType = store.settings.webSearchType
        voice = store.settings.voice
        bandwidthMode = store.settings.bandwidthMode
        uploadRate = store.settings.uploadRate; suppressSilence = store.settings.suppressSilence
        instructions = store.settings.instructions
    }
}
