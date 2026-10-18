import SwiftUI

struct WatchHomeView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var model: ConversationModel
    @State private var selectedPage = 0
    @State private var followLatest = true

    var body: some View {
        TabView(selection: $selectedPage) {
            conversationPage.tag(0)
            settingsPage.tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Theme.background.ignoresSafeArea())
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--demo") { model.startDemo() }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--settings") { selectedPage = 1 }
            #endif
        }
    }

    private var conversationPage: some View {
        GeometryReader { geometry in
            // The system clock sits slightly lower on larger watch displays.
            let titleBottom = 30 + max(0, geometry.size.width - 187) * 0.15
            let topInset = titleBottom + 8
            let fadeHeight = topInset + 12
            VStack(spacing: 6) {
                conversationArea(topInset: topInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .mask(alignment: .top) {
                        VStack(spacing: 0) {
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.55),
                                .init(color: .white, location: 1)
                            ], startPoint: .top, endPoint: .bottom)
                            .frame(height: fadeHeight)
                            Color.white
                        }
                    }
                    .clipped()
                if model.isActive {
                    status.frame(height: 16).layoutPriority(1)
                        .padding(.horizontal, 10)
                }
                controls.frame(height: 52).layoutPriority(1)
                    .padding(.horizontal, 10)
            }
            .padding(.horizontal, 3)
            // Use part of the bottom safe area while keeping the controls above the curve.
            .padding(.bottom, 12)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
            .overlay(alignment: .top) {
                LinearGradient(stops: [
                    .init(color: Theme.background.opacity(0.92), location: 0),
                    .init(color: Theme.background.opacity(0.6), location: 0.55),
                    .init(color: Theme.background.opacity(0), location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: fadeHeight)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                Text("豆包AI")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .padding(.leading, max(geometry.safeAreaInsets.leading, 18))
                    .frame(height: titleBottom, alignment: .bottom)
                    .accessibilityAddTraits(.isHeader)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .background(Theme.background.ignoresSafeArea())
    }

    private var settingsPage: some View {
        NavigationStack {
            SettingsEditor(store: store, isCallActive: model.isActive, diagnostics: model.networkSummary) {
                withAnimation { selectedPage = 0 }
            }
            .toolbarTitleDisplayMode(.inline)
        }
    }

    private func conversationArea(topInset: CGFloat) -> some View {
        let contentInset = model.isDemo ? 0 : topInset
        return VStack(spacing: 6) {
            if model.isDemo {
                Text("字幕演示 · 无真实通话")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .padding(.top, topInset)
            }
            if model.messages.isEmpty {
                if model.error == nil {
                    if model.isActive {
                        VStack(spacing: 6) {
                            Text(model.state == .reconnecting ? "正在自动恢复" : model.state == .connecting ? "正在连接豆包" : "请说出你的问题").font(.headline)
                            Text(model.state == .reconnecting ? "网络恢复后自动继续监听" : "双方文字将在这里显示")
                                .font(.caption2).foregroundStyle(Theme.secondary)
                        }
                        .padding(.top, contentInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        welcome
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, contentInset)
                    }
                }
            } else {
                transcript
                    .contentMargins(.top, contentInset, for: .scrollContent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = model.error {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.messages.isEmpty { Text("连接未完成").font(.headline) }
                        Text(error).font(.caption2).foregroundStyle(.orange)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentMargins(.top, model.messages.isEmpty ? contentInset : 0, for: .scrollContent)
                .frame(maxHeight: model.messages.isEmpty ? .infinity : 62)
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 10) {
            VoiceOrb(compact: true)
            Text("说出问题，听见回答")
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Label(store.settings.webSearchEnabled ? "联网搜索已开启" : "联网搜索未开启", systemImage: "globe")
                .font(.system(size: 10))
                .foregroundStyle(store.settings.webSearchEnabled ? Theme.mint : Theme.secondary)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(model.messages) { message in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Image(systemName: message.role == .user ? "person.fill" : "waveform")
                                Text(message.role == .user ? "你" : "豆包")
                                if message.isInterrupted { Text("· 已打断") }
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(message.role == .assistant ? Theme.mint : Theme.secondary)
                            Text(message.text).font(.system(size: 14)).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(message.role == .assistant ? Theme.card : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                        .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }
            }
            .onChange(of: model.messages) { _, _ in
                if followLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    followLatest.toggle()
                    if followLatest { proxy.scrollTo("latest", anchor: .bottom) }
                } label: {
                    Image(systemName: followLatest ? "pause.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 21)).foregroundStyle(Theme.mint)
                        .background(Theme.background, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(followLatest ? "暂停字幕自动滚动" : "跟随最新字幕")
            }
        }
    }

    private var status: some View {
        HStack(spacing: 5) {
            Circle().fill(model.isMuted ? .orange : Theme.mint).frame(width: 5, height: 5)
            Text(model.isDemo ? "演示中" : model.state == .connecting || model.state == .reconnecting ? model.connectionStatus : model.isBuffering ? "声音缓冲中" : model.isMuted ? "麦克风已静音" : model.networkMetrics.oldestSendSeconds > 0.5 ? "网络较慢，正在缓冲" : model.state.label)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Text(String(format: "%02d:%02d", model.elapsed / 60, model.elapsed % 60)).monospacedDigit()
                .fixedSize()
        }
        .font(.system(size: 10)).foregroundStyle(Theme.secondary)
        .padding(.horizontal, 3)
    }

    private var controls: some View {
        Group {
            if model.isActive {
                HStack(spacing: 6) {
                    Button { model.toggleMute() } label: {
                        controlLabel(model.isMuted ? "mic.slash.fill" : "mic.fill", text: model.isMuted ? "恢复" : "静音")
                    }.disabled(!model.canControl).accessibilityLabel(model.isMuted ? "取消静音" : "静音麦克风")
                    Button { model.interrupt() } label: { controlLabel("hand.raised.fill", text: "打断") }
                        .disabled(!model.canInterrupt).accessibilityLabel("打断豆包回答")
                    Button { model.end() } label: { controlLabel("phone.down.fill", text: "结束").foregroundStyle(.red) }
                        .disabled(model.state == .closing).accessibilityLabel("结束通话")
                }
                .buttonStyle(.plain).foregroundStyle(Theme.mint)
            } else {
                Button {
                    followLatest = true
                    if store.isConfigured { model.start(store: store) }
                    else { withAnimation { selectedPage = 1 } }
                } label: {
                    Label(store.isLoading ? "读取配置中" : store.isConfigured ? "开始对话" : "配置豆包", systemImage: store.isConfigured ? "mic.fill" : "key.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(Theme.mint, in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.background)
                .disabled(store.isLoading)
            }
        }
    }
    private func controlLabel(_ symbol: String, text: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 18)).frame(height: 21)
            Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .frame(maxWidth: .infinity).frame(height: 52)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

}
