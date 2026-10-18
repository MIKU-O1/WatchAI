# 验证记录

## 2026-10-07：豆包AI 名称与极简首页

- 界面标题、安装显示名称和麦克风权限提示统一改为「豆包AI」，保留原 Bundle ID 和 Keychain，升级沿用已有配置。
- 初始首页仅保留语音图标、「说出问题，听见回答」一行描述、联网搜索启用 / 未启用状态与开始 / 配置按钮；移除多行说明和字幕演示按钮。设置仍位于第二屏，字幕演示保留 `--demo` 启动参数。
- watchOS 真机架构与模拟器构建均通过（关闭签名），构建产物的 CFBundleDisplayName 确认为「豆包AI」。独立 42 mm 模拟器已安装并检查未配置首页，截图位于 `Artifacts/Design/home-doubao-ai-search-off.png`。
- 没有安装到实体手表、读取用户凭据或调用云端服务；本次仅修改显示文案与首页布局。

## 2026-10-07：实时通话弱网自动恢复与静音省流量

- 上传默认尝试 12 kbps Opus，可选 8 kbps 试验档与 16 kbps 清晰档；优先检查系统可用码率，统计显示实际设置值，兼容模式仍可选，不自动切换到 PCM。
- 本地能量检测保留最多 240 ms 起始缓冲及约 800 ms 句尾余量，长静音通过服务端静音事件停止音频上传；说话后自动取消静音，一次只发一个 20 ms 包，开头缓冲不突发上传。检测可关闭；不是声纹识别。
- Ogg Opus 回复先缓冲约 0.5 秒，发生断粮时阈值增加至 1～2 秒，自动续播；结束事件释放不足阈值的短回答。打断、旧回调失效和 30 秒播放上限保留。
- 发送积压以字节数 / 最老回调等待时间判定，最多 100 个音频未完成请求，另预留 8 个控制请求，总量最多 128 KB；超过 2 秒未完成或达到容量上限进入恢复，不再以 25 个请求直接报带宽不足。
- 短暂网络等待可在原连接恢复；断线自动重连，首轮立即、连续失败退避约 1 / 2 / 4 / 8 秒，稳定 10 秒后重置。路径恢复会提前唤醒重试。停止通话、进入后台或不可恢复鉴权 / 参数错误会取消重试；限流延长等待。
- 保留字幕并复用服务端会话 ID 尝试接续上下文，暂停期间丢弃旧上传积压，不重复上传断线录音。接续上下文不能保证回答音频断点续传；恢复后自动监听。路径监测、传输、录音与播放均隔离旧回调。
- 设置页新增本次通话速率、累计字节、播放缓冲、发送积压、重连次数与编码码率。统计包含应用 JSON / Base64，不含 TLS / TCP / IP；上传按提交计算，不代表全部送达。播放状态去重，缓冲统计界面最多约每半秒更新。
- 单元测试 37 项通过，0 失败：包含静音省流量、起始保留 / 句中停顿 / 静音恢复、逐包节奏、短回复释放、断粮恢复、缓冲上限、退避 / 错误分类和旧配置升级。
- 本地传输脚本 18 项验证通过：800 ms 回调延迟下 50 包 / 秒、80 包完整且顺序正确；持续积压 / 无新音频的超时自动恢复、短等待原连接恢复、断线 / 服务端临时错误自动重连、会话 ID 复用、网络恢复唤醒、结束后取消重试及 Key 脱敏。
- 独立 libopus 分别解码三档系统编码器输出的 250 个包，均为完整 5 秒 / 440 Hz 音频。另一变化音调样本：8 / 12 / 16 kbps 的纯音频分别 4965 / 6609 / 8481 字节（5 秒），未计封装和网络开销，不能等同于真人识别率或真实网络流量。
- 最终 watchOS 真机架构与模拟器构建通过（关闭签名）；新建隔离的 42 mm 模拟器安装并启动，检查设置页与字幕演示。截图 / 本地协议及独立解码结果保存在 `Artifacts/WeakNetwork/`。没有安装到用户实体手表、没有使用真实 API Key 或调用云端计费服务。

尚待真机验证：轻声 / 噪声 / 外放回声的检测、三档识别与听感、Wi-Fi / 配对手机网络恢复、豆包服务的历史接续与实际上下行流量。回复服务端码率未修改，仅继续请求 Ogg Opus；此次不保证低于持续播放需求的网络能无等待播放。

## 2026-10-07：移除一句一答，仅保留实时通话

- 删除一句一答入口、方式选择、方舟 Key / 模型 ID / 单独朗读音色设置，以及录音文件上传、静音裁剪、AAC 封装、方舟回答和 HTTP 语音合成实现；移除对应测试、脚本与 Package target，重新生成纯手表工程。
- 实时通话、问答字幕、固定的静音 / 打断 / 结束按钮、联网搜索、Opus 省流量与 PCM 兼容模式保留；此次没有修改实时传输、编码参数或音频设备恢复逻辑。
- 钥匙串继续在后台加载，只读取语音和搜索 Key，不再读取或写入方舟 Key，也没有删除已保存的方舟凭据。旧配置中的对话方式、文字模型和朗读音色会被忽略；原实时音色、提示词和流量模式保留。
- 旧一句一答配置开启搜索却没有独立搜索 Key 时，迁移关闭搜索，避免阻止实时通话启动；已有独立搜索 Key 时保留搜索设置。
- `swift test`：29 项通过，0 失败，包含两种旧配置迁移与非阻塞配置读取测试；使用隔离的 UserDefaults 和虚拟凭据。
- `Scripts/test_transport.py`：本地 WebSocket、会话生命周期、备用连接、搜索配置和脱敏、断线处理及发送积压回归通过。
- watchOS 真机架构及模拟器编译均通过（关闭签名）。保留原 Signing Team 和红围巾图标；没有安装到用户实体手表，也未调用实际云端服务。

以下为此前版本的历史验证记录。

日期：2026-10-06。开发环境：Xcode 27.0。

- 工程仅保留 `WatchAI Watch App` 一个 target 和 scheme；手机端源码、资源、Info.plist 和 WatchConnectivity 同步逻辑已删除。
- 独立 Apple Watch 模拟器目标：编译通过，已安装并启动，主页显示手表配置入口。
- 独立 Apple Watch 真机架构目标：关闭签名后编译通过。未安装到物理设备。
- 独立 Apple Watch Release 归档：关闭签名后通过，归档内仅有一个 watchOS 应用。
- 构建产物确认 `WKWatchOnly = YES`，没有 `WKCompanionAppBundleIdentifier`；应用 target 的 `SKIP_INSTALL = NO`。
- 核心协议及音频恢复策略测试：9 项通过，0 失败。新增验证正常通知不会断开、运行中格式变化触发恢复，以及连续恢复次数限制。
- Network WebSocket 本地测试：通过。验证语音 API Key 请求头、客户端帧掩码、Ping/Pong、跨 UTF-8 字节分片以及关闭确认。
- 已检查更新后的手表主页截图；手表设置及字幕演示在此前版本已运行检查，本次保留其功能。
- 此前安装用于验证的 iPhone 模拟器应用已卸载，手机端截图已删除。
- 剩余 Xcode 提示仅为 AppIntents 元数据提取被跳过，应用没有使用 AppIntents。

截图为模拟器界面；字幕演示使用内置示例文字，不调用豆包、不录音。

尚未验证：有效豆包账号的实时语音调用、物理手表上的麦克风和扬声器、外放回声、AirPods 音频路由、独立 Wi-Fi / 蜂窝连接及云端计费。需要用户填入自己的语音 API Key 并在真机上运行。

## 实体手表音频配置变化修正

用户报告开始通话后出现「音频设备发生变化，请重新开始通话」。原逻辑收到任何 AVAudioEngine 配置变化通知就结束通话；现改为合并短时间通知，检查引擎和输入格式，正常时忽略，停止时重启，格式变化时重建转换器和录音管线。恢复期间保留音频会话、云端连接及静音状态，旧管线回调失效；持续不稳定或恢复失败才提示重连。

修改后 watchOS 真机架构、模拟器构建及 9 项测试通过。此前 Release 归档记录为修改前版本；本次没有替换用户正在使用的模拟器或实体手表应用，实体手表恢复效果需重新安装后验证。

## 实体手表连接超时诊断

用户随后报告「连接超时」，网络来自配对 iPhone。新增 NWConnection 状态处理：握手完成后再发送 session.create，分别计时网络连接和会话创建，网络等待时保留具体系统错误。页面显示连接阶段，并将失败提示放入可滚动区域，保留底部重新开始按钮。

watchOS 真机架构及模拟器构建通过。本地测试通过：原始传输测试、真实 RealtimeClient 的握手至创建 / 关闭流程，以及 HTTP 401 握手拒绝的错误路径。Mac 无鉴权访问官方接口获得 HTTP 400，这仅说明电脑能访问接口，不代表手表网络、用户 Key 或服务权限已经验证。未访问用户密钥，也未安装或启动用户的设备应用；实体手表超时原因仍待运行时具体错误确认。

随后只读检查正在运行的实体 Apple Watch S11 的 Xcode 调试控制台，看到多次：`Received response code 502 for openspeech.bytedance.com:443, unreachable through proxy, interface denied`，连接路径含 `utun4` 和 `proxy`。当前失败发生在网络通道阶段，尚未完成语音服务鉴权。这些信息不能证明代理来自用户 VPN；也可能涉及系统转发或调试通道。下一步应分别测试离开 Xcode 调试后从手表自行启动、直接 Wi-Fi 联网，以及存在 VPN 时关闭 VPN 的情况。没有更改用户的网络设置或中断调试进程。

## 独立 Wi-Fi 仍连接中断后的兼容处理

用户确认手表已连接 Wi-Fi，停止 Xcode 调试后仍失败，随后出现 POSIX 53（Software caused connection abort）。新增系统 URLSession WebSocket 备用方式：仅在 Network 握手失败或超时、尚未发送 session.create 时切换一次，继续使用相同的豆包端点和 API Key。两种方式都启用系统 TLS 验证；系统备用方式可显示响应中的 HTTP 状态码。补齐连接关闭时发送或接收失败也通知界面结束的路径。

本次 watchOS 真机架构和模拟器构建通过。本地五条测试路径通过：原始 Network 传输、Network 建会话及关闭、系统备用方式建会话及关闭、系统方式 HTTP 401 拒绝且 Key 不进入错误消息、Native 握手拒绝后自动切换系统方式成功建会话。未重复测试未修改的核心模块。仍没有验证实际手表与豆包的真实通话；备用方式也受系统网络许可限制，不能仅凭本地测试声称真机问题已解决。

## 实时音频发送积压修正

用户报告「网络传输跟不上实时语音」。代码中网络发送队列和麦克风 PCM 缓冲此前共用此错误，因此截图本身不能区分两种来源。发送方式此前逐包等待完成回调，若系统回调需 100 ms，即使底层已接受数据也无法保持每秒 50 包的提交速度。改为从 MainActor 按调用顺序持续提交回调式发送，保留最多 25 个未完成发送；异步回调只更新未完成数或报告错误。麦克风缓冲改为独立的 microphoneBacklog 错误提示。

真机架构及模拟器编译通过，9 项核心测试通过；全部本地连接路径继续通过。新增两个发送回归测试通过：100 ms 完成回调延迟下每秒 50 包、80 包内容及顺序完整；永久无完成回调时仍触发积压上限。实际手表的积压来源及修正后的真实语音效果仍需安装新版验证，没有将本地回调延迟测试视为真实硬件网络测量。

## 麦克风缓冲积压修正

用户最新截图明确显示 microphoneBacklog，定位到录音侧上限。检查发现录音 tap 在引擎启动时已能产生音频，但分包定时器在 engine.start 返回后才启动；定时器的合并触发此前也只消耗一包。原缓冲上限 16000 字节仅容纳 500 ms 音频，且 Apple 的 installTap 文档明确 `bufferSize` 是请求值，实际实现可以选择其他大小。因此较大的硬件批次也可触发原上限；尚未测得用户手表的实际回调长度，不能认定具体触发原因已得到真机证实。

调整启动顺序，分包器先于录音 tap 启动；PCM 输出改为单次分配并按字节写入 Int16 LE；缓冲上限设为 64000 字节（2 秒），仍限制内存。使用 DispatchSourceTimer.data 获取合并的触发次数，丢弃错过时段的旧包且每次只发送一包。主线程延迟超过 100 ms 的包不再事后批量提交。持续积压时的错误附加音频格式、批次时长、缓冲时长及上一次定时器间隔，方便继续定位；不包含 Key 或音频内容。长时间调度停顿可能短暂丢失音频，已写入 README。

13 项核心测试通过，新增 4 项覆盖超过旧上限的硬件批次、500 ms 合并定时器恢复、极长停顿下样本边界及 30 秒持续批次录音的顺序与有界缓冲。watchOS 真机架构和模拟器编译均通过。未改网络发送实现，不重复网络测试；未操作正在使用的手表或调试器，真实豆包通话尚待用户安装验证。

参考：https://developer.apple.com/documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:) 。Dispatch 定时器 data 语义亦核对了 Xcode SDK 的 dispatch/source.h（定时器已触发次数）。

## 最新真机响应 HTTP 403

用户安装后截图显示 WebSocket 握手 HTTP 403，并确认 Key 来自「豆包语音新版控制台 → API Key 管理」。检查两个传输实现均按官方 Python 示例传递 X-Api-Key，无证据表明需要增加其他必选鉴权头。403 表示已收到握手拒绝响应，截图未包含服务端错误正文，尚不能确认是具体的 Key 状态、项目资源权限或中间网络策略问题；也不能凭这次握手错误认定真实录音与播放已全部稳定。

核对新版控制台官方快速入门文档：Key 可启用/禁用；模型服务在「开通管理」中管理，可暂停/终止；资源按项目隔离，不可跨项目共享。下一步核对 Key 所属项目及全双工实时语音服务状态，必要时由用户提供不含 Key 的服务详情截图。本次未修改协议或读取真实 Key。

参考：https://docs.volcengine.com/docs/DoubaoVoice/QuickStartNewConsole?lang=zh 。

## 真实回复后断线与 ASR 中间字幕重复

用户截图已有豆包回复，同时出现 `Network.NWError error 57 - Socket is not connected`，并报告说话时字幕重复、翻看最终记录正常。这说明此次已建立过真实会话，不能继续按握手鉴权问题处理。只读查看 Xcode 确认实体 Apple Watch S11 正在运行，控制台仅见 `cannot add handler to 0 from 0 - dropping`，不足以推断断线根因；未停止调试或操作手表。

下载并阅读官方 Web Demo：`conversation.item.input_audio_transcription.delta` 使用 `setQuestion(extractEventText(event))`，替换当前识别结果；`response.output_text.delta` 使用 `appendAnswer`。此前两类均追加，ASR completed 又覆盖全文，能解释用户描述的中间重复及最终正常。修正 ASR 为按 item_id 替换（含 text/delta 字段），最终识别确认后忽略迟到中间结果，演示也改成逐次发送完整识别结果。保留助手追加及真实重复词。

中途发送失败此前立即取消接收，可能掩盖服务端最终 error。现在停止上传，最多等待 250 ms 接收并优先处理结构化错误；保留可获取的 WebSocket 关闭码和原因，错误仍脱敏。原生连接中途失败后，下次用户主动开始尝试系统连接，不自动重建会话。已验证旧发送回调不影响下一次通话、主动结束可取消延迟错误。尚不能认定真实断线原因或长期稳定性已解决。

16 项核心测试通过（新增 ASR 重复快照/修订、真重复词、助手增量、迟到快照、无 ID 识别事件回归）。11 条本地连接/生命周期检查通过：原有 7 条，加上发送错误后仍读取服务端错误、socket 断线后用户重试、waiting 断线后用户重试、主动结束取消延迟错误；重试测试同时覆盖旧回调隔离。watchOS 真机架构及模拟器编译通过。未连接用户 Key 进行云端测试。

官方 Web Demo：https://portal.volccdn.com/obj/volcfe/cloud-universal-doc/upload_40e78e155a0960f1fa2cdafc098a4254.zip ，核对 static/app.js 的 handleUpstream、setQuestion、appendAnswer。

## 将官方 Vivi / VV 音色设为默认

用户要求增加豆包音色并设为默认。核对官方音色列表及全双工 Web Demo：Vivi / VV 的 Jupiter ID 为 zh_female_vv_jupiter_bigtts，官方 Web Demo 的内置列表首项及服务端缺省值均使用此 ID。新增「豆包 · Vivi（默认）」选项，通过 VoiceSettings.defaultVoice 统一设置页、新配置及 session.create 的默认值。首次升级启动一次性迁移已保存的音色到 Vivi，保留 API Key 与回答风格；之后不会覆盖用户手动选择。

16 项核心测试及 watchOS 真机架构编译通过，现有会话请求测试增加默认 voice 字段断言。没有使用用户 Key 请求试音，未验证听感或与豆包 App 任意版本的逐字逐句相同。

参考：https://docs.volcengine.com/docs/DoubaoVoice/Tonelist-1 ，以及上述官方 Web Demo 的 static/index.html 和 server.py。

## 用户澄清目标为豆包 App 文字回答的经典朗读

用户反馈 Vivi 听感不符，并明确目标是文字回答的朗读声音。之前将官方 Vivi 直接冠以「豆包」容易暗示与 App 经典朗读同款，此对应关系没有得到验证。将选项改为准确的「Vivi · 实时女声（默认）」，同步 README；保留已选音色，不再盲目替换成另一个 ID。

已查阅官方音色表及豆包官方功能介绍，确认公开音色及 App 多音色功能，但尚未找到用户当前经典朗读选项与公开 API speaker ID 的明确映射。目标音色接入仍待 App 声音选择页名称/截图等信息确认，不能将改名视为经典朗读接入完成。

参考：https://docs.volcengine.com/docs/DoubaoVoice/Tonelist-1 ；https://www.doubao.com/legal/feature_intro 。

## 默认启用 Opus 省流量模式（2026-10-06）

用户希望尽可能降低带宽，同时再次确认目标是豆包 App 的朗读声音。核对官方全双工协议：输入支持 pcm / speech_opus，固定 16 kHz；输出支持 pcm / pcm_s16le / ogg_opus，固定 24 kHz；建议每 20 ms 按实时节奏发送。音频事件 event_id 可选。官方 Web Demo 默认使用 ogg_opus，并包含跨分片 Ogg 拆包与 Opus 流式解码。

实现默认 economy：系统 AVAudioConverter 将每 320 个 16 kHz 单声道样本编码为一个约 16 kbps 原始 Opus 包；服务端回复指定 Ogg Opus。回复逐页验 CRC、检查序号与延续标志、组装跨页包、解码并处理 OpusHead、pre-skip、输出增益及 EOS granule 裁剪。当前 API 没有可确认的回复码率控制参数。省去每帧可选 UUID 和 Base64 的无必要斜杠转义。维持 20 ms 节奏及静音控制事件，没有通过批量上传或降低 API 要求的采样率省流量。

会话创建成功后才开始编码上传，避免把连接前的编码状态丢给服务器。新回复 / 主动打断重置解码状态；音频设备恢复保留当前流状态。设置页增加省流量 / 兼容模式，兼容模式沿用 PCM。旧配置没有 bandwidthMode 时默认使用 economy，保留 Key、音色、提示词，没有再次强制迁移音色。没有新增生产运行时依赖。

本地测量：5 秒变化音调测试，上传 Base64 + JSON 为 23290 字节，PCM 为 225750 字节，减少约 89.7%；未包含 TLS/TCP/IP 开销，也不是用户语音或云端通话实测。20 项核心测试、4 项音频测试通过。独立 FFmpeg/libopus 生成的 2 秒 440 Hz Ogg 样本逐字节喂入后恢复为 48000 个 24 kHz 帧，音高 / 能量正确；验证连续流、打断重置、跨页组包、损坏校验和、序号缺失、包时长及缓冲上限。独立 libopus 解码系统编码器生成的 250 个包，恢复完整 5 秒 16 kHz 音频，440 Hz、RMS 0.141。参考库仅用于本机测试，未打包进应用。

11 条本地连接 / 生命周期检查通过。watchOS 真机架构和模拟器编译通过；没有运行或停止用户的手表 / 调试器。没有读取用户真实 Key 或发起计费云端调用。真实 Watch 编解码、speech_opus 接入、耗电、弱网听感仍须用户安装验证。压缩不能修复不可达网络或服务端拒绝连接。

音色目标尚未解决：公开音色表未给出用户所指 App 经典朗读与 speaker ID 的确定映射。保留现有选择并在设置页说明是公开实时音色；没有将另一个相近声音再次宣称为 App 同款。需要实际 App 朗读样本或对应音色选择页进一步核对。

来源：
- https://docs.volcengine.com/docs/DoubaoVoice/endtoend-realtime-voice-full-duplex-version?lang=zh
- 官方 Web Demo static/app.js 的 OggOpusDemuxer / WebCodecsOggOpusPlayer
- 原始 Opus 包的上行用法还参照公开客户端作者实现：https://github.com/GizClaw/gizclaw-go/blob/main/pkgs/genx/transformers/doubaorealtime/realtime_audio.go （PrepareFrames / encodeOpusSamples），这不替代云端兼容性测试。
- Ogg / Opus 规范：https://www.rfc-editor.org/rfc/rfc7845 、https://www.rfc-editor.org/rfc/rfc6716

## 接入豆包内置联网搜索（2026-10-06）

用户要求联网搜索功能。核对当前全双工 API 文档：extension.dialog.extra 支持 enable_volc_websearch、volc_websearch_type（web_custom_api / web_global_api）及 volc_websearch_api_key。开启搜索需额外配置融合信息 / 豆包搜索服务的 API Key。官方 Web Demo 的 _build_dialog_extra 也验证了两个服务类型必须有搜索 Key。本项目使用当前文档列出的类型，没有依赖 Demo 中未在当前文档列出的旧版 web_2.0 默认值。

新增手表「联网搜索」设置：开关、Custom / Global 选择及搜索 SecureField。搜索版本默认 Custom，匹配用户关注响应延迟的使用场景；需用户匹配其实际开通服务与 Key 权限。旧配置缺少搜索字段时保持关闭，保留现有语音 Key / 音色 / 提示词 / 压缩配置。搜索 Key 使用独立 Keychain account，不进入 VoiceSettings / UserDefaults。只有开启时在 session.create 的扩展参数传入。创建通话前校验缺失 Key，保存配置亦校验；两个 Key 都会在服务端错误中脱敏，握手备用连接保留搜索 Key。开启时附加提示词，要求涉及最新信息或明确搜索请求时检索、说明信息时间与来源、查询失败如实说明；没有假设服务端返回未记载的搜索状态事件，也未伪造已经搜索的逐轮状态。

26 项核心 / 音频测试通过（22 + 4）。新增协议测试覆盖 Custom / Global、扩展参数与响度参数共存、搜索关闭时不发送已保存 Key、缺少 Key 拒绝、不将 Key 放入提示词、配置往返和旧配置默认值。12 条本地传输 / 生命周期检查通过，新增检查证明缺少搜索 Key 不创建 socket、原生握手失败后的备用会话保留搜索参数、两个 Key 均脱敏且不自动重连。watchOS 真机架构及模拟器编译通过。

没有读取用户真实 Key、开通或购买账号服务、停止用户手表调试，也没有发起真实云端搜索请求。实际权限、检索结果 / 来源内容与计费须用户开通豆包搜索、在手表填写搜索 Key 后验证。搜索在豆包服务端执行，保留手表的 Opus 省流量模式；不声称这一配置可以保证每轮都会进行搜索。

来源：
- https://docs.volcengine.com/docs/DoubaoVoice/endtoend-realtime-voice-full-duplex-version?lang=zh
- 官方 Web Demo server.py 的 _build_dialog_extra
- https://docs.volcengine.com/docs/87772/2272951 （不同搜索版本及订阅 / 按量服务的 Key 权限 / 计费）
- https://console.volcengine.com/search-infinity/web-search?projectName=default （官方接口文档所链接的搜索控制台）

## 固定通话控制按钮并增加文字说明（2026-10-06）

用户反馈底部三个图标随字幕变化移动，且含义不明确。WatchHomeView 以 GeometryReader 固定整体可用高度，只让字幕 / 欢迎 / 错误内容占用可变空间；状态条固定 16 点、按钮区域固定 52 点，长状态单行截断。三个等宽按钮分别增加「静音／恢复」「打断」「结束」标签，保留原有操作与禁用条件；未通话的大按钮也保持相同高度与底部位置。字幕自动滚动的暂停按钮仍位于字幕区域，只控制滚动。

watchOS 真机架构及模拟器构建均通过。新建隔离的 42 mm watchOS 27 模拟器，在无需 Key / 网络 / 录音的已有字幕演示中检查短回复、长回复及结束状态，底部按钮区域位置一致，文字和按钮均可见。对应截图：controls-42mm-short-answer.png、controls-42mm-long-answer.png、controls-42mm-ended.png。演示中麦克风 / 打断按钮按原逻辑禁用，截图中的较暗颜色不是实际通话的可操作状态。没有新增与布局实现重复的单元测试。未停止或运行用户的真机 / 原有模拟器调试会话；完成后清理本次创建的隔离模拟器。真实手表效果需重新安装本次构建后确认。

## 紧凑标题与左滑设置第二屏（2026-10-06）

用户要求「腕上 AI」与时间同排、缩短顶部遮罩，并把设置放到左滑第二屏。WatchHomeView 改为原生横向分页 TabView：第一屏对话，第二屏设置，取消齿轮与设置弹窗。对话页移除占两行的导航栏，顶部保留系统时钟，自绘左侧标题及 35 点紧凑标题区；字幕区域向上扩展，底部 52 点控制按钮维持固定位置。配置豆包按钮跳转第二屏。SettingsEditor 保存成功调用页面回调返回对话；通话中仍可翻页查看设置，编辑与保存禁用，通话结束后重新加载已保存配置。翻页没有触发结束通话或创建新会话。

watchOS 真机架构与模拟器构建通过。新建隔离的 42 mm watchOS 27 模拟器，查看最终标题与时间对齐、演示通话固定按钮、结束 / 欢迎状态、设置通话中提示与结束后表单恢复。通过 Device Hub 中的模拟器横向拖动确认左滑进入设置；最终标题另上调 4 点后再次构建和检查截图。SettingsEditor 保存回调与配置按钮页选择已检查代码并编译，未在模拟器实际输入 / 保存 Key。期间原生窗口自动化部分重试返回 noWindowsAvailable / frontmostApplicationChanged，因此没有声称已自动化验收完整保存交互。

截图：pages-42mm-conversation.png、pages-42mm-ended.png、pages-42mm-welcome.png、pages-42mm-settings-active.png、pages-42mm-settings.png。只使用已有无网络字幕演示及 DEBUG 设置页启动参数；未读取真实 Key 或发起云端请求，未停止真机或已有模拟器调试。检查结束后清理此次新建模拟器。真实手表同排显示及横向滑动体验需重新安装后确认。

## 标题高度、透明渐变遮罩与降低按钮位置（2026-10-06）

用户反馈标题虽与时间同排但高度仍有差异，希望透明渐变遮罩、按钮进一步靠下。在新建隔离的 46 mm 模拟器复现：旧标题约比时钟高 3 点，42 mm 原位置接近。改为随屏幕宽度调整标题底边，保留系统时钟。对话内容延伸至顶部，滚动内容以 alpha 渐变在标题后淡出，顶部背景从 92% 不透明渐变至透明；遮罩和标题不拦截触摸。欢迎与无字幕错误内容仍有顶部滚动留白。演示提示单独占据标题下方空间，避免与滚动字幕相互覆盖。

对话页延伸到完整底部区域，按钮保留 12 点底部间距及额外 10 点左右内缩；52 点高度不变，状态条和按钮仍固定。42 mm 按钮约下移 19.5 点，46 mm 约下移 24.5 点，圆角边缘内的文字 / 图标完整可见，三个按钮的宽度仍超过 44 点。设置第二屏与实际语音操作逻辑未变。

真机架构及模拟器构建均通过。使用此次新建的 42 / 46 mm watchOS 27 模拟器执行已有无网络字幕演示，检查最终标题与系统时间的视觉高度、短 / 长字幕以及结束状态的按钮位置和可见性；42 mm 欢迎页也检查通过。截图为 gradient-42mm-conversation.png、gradient-42mm-ended.png、gradient-42mm-welcome.png、gradient-46mm-conversation.png、gradient-46mm-ended.png。真实通话的顶部滚动区域与演示共用渐变遮罩；未进行真实云端通话或真机触控测试。没有新增与布局实现重复的单元测试，未读取真实 Key、修改账号权限或停止用户真机 / 已有模拟器调试；完成后清理此次新建的两个模拟器。真实设备上的时钟高度、不同系统 / 更大字体与按钮边缘点击体验需重新安装验证。

## 新应用图标：薄荷语音气泡（2026-10-06）

用户请求设计好看的图标。使用内置 image_gen 生成深色青绿背景上的薄荷绿立体语音气泡与白色五段声波，图形居中、主体留在圆形裁切安全范围内。原始 1254 × 1254 PNG 与完整提示词保存到 Artifacts/Design；sips 等比例转换为 1024 × 1024 不透明 PNG，接入新的 AppIconMint.appiconset，保留原 AppIcon 图标集。工程 Debug / Release 默认选用 AppIconMint；工程生成脚本在新图标集存在时选用它，避免重新生成工程后恢复旧图标。

检查尺寸为 1024 × 1024、无 alpha，并查看 48 像素缩略图的辨识度。watchOS 构建成功、actool 无资源错误或警告，产物 CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName 为 AppIconMint。Python 工程生成脚本语法检查通过，没有为此重写整个工程。未重新运行用户真实手表或发起云端语音调用。安装到手表后的系统圆形裁切与图标缓存需通过重新 Run 确认。

## 图标改为浅色人物头像（2026-10-06）

用户要求取消黑底，希望类似豆包的头像图标。参考豆包官方 App Store 页面的人物头像风格，通过内置 image_gen 重新生成浅蓝白背景、短发微笑女孩头像与薄荷色上衣，未下载其图标。原图与完整提示词保存于 Artifacts/Design/WatchAI-Icon-Avatar-v3*，等比例缩放为 1024 × 1024 不透明 PNG，加入 AppIconAvatar 图标集并设为 Debug / Release 默认，保留原图标集。工程生成器按 Avatar / Mint / 原 AppIcon 的顺序选择存在的图标集。

检查尺寸与无 alpha，查看 48 像素缩略图的头像辨识度；watchOS 编译通过、actool 无错误或警告，构建产物的 CFBundleIconName 确认为 AppIconAvatar。生成器语法检查通过。没有运行或停止用户真实手表，安装后的系统圆形裁切与缓存仍需重新 Run 确认。

风格参考：https://apps.apple.com/cn/app/id6459478672 。

## 按用户参考改为白底红围巾头像（2026-10-06）

用户提供人物头像截图，明确要求相似形象、白色背景、红色围巾。使用内置 image_gen 引用该截图，生成棕色偏分短发、大眼睛、红色针织围巾的 3D 女孩头像；不包含截图 UI、账号名或字幕。原图、完整提示词及 48 像素检查图保存于 Artifacts/Design/WatchAI-Icon-Scarf-v4*。等比例缩放为 1024 × 1024 不透明 PNG，新增 AppIconScarf 图标集并设为 Debug / Release 默认，保留此前版本，工程生成器也优先选择它。

检查尺寸与无 alpha，查看 48 像素下的人脸及围巾辨识度；watchOS 构建成功，无资源警告或错误，产物 CFBundleIconName 为 AppIconScarf。工程生成器语法检查通过。没有运行或停止用户真实手表；安装后圆形裁切及图标刷新仍需重新 Run 确认。

## 修正安装后图标不更新的资源用途（2026-10-06）

用户反馈安装后图标没有更新。重新构建并用 assetutil 检查 Assets.car，发现 AppIconScarf 只有 marketing idiom 的图像；原 Contents.json 使用 watch-marketing，仅配置 App Store 展示用途，此前只检查构建成功与 CFBundleIconName 不足以验证桌面图标。改为 Xcode 的单尺寸 watchOS 图标配置：idiom 为 universal、platform 为 watchos、size 为 1024x1024，继续使用同一白底红围巾 PNG。

真机架构与模拟器构建通过，修正后 Assets.car 的 AppIconScarf 图像和 MultiSized Image 均为 watch idiom，而非 marketing；Debug / Release 均选用 AppIconScarf。新建隔离的 Watch Series 11 46 mm 模拟器并成功安装；Device Hub 的 Home 操作未进入应用列表，之后坐标操作返回 windowNotFoundAtPosition，因此未宣称已验证桌面实际显示。只清理本次新建的模拟器，未停止用户正在运行的实体手表或操作其应用 / Key。真机上的更新结果需用户重新 Run 后确认。

## 默认改为低带宽一句一答，无服务器（2026-10-07）

用户选择无需服务器的一句一答。新增 turn / realtime 方式，旧配置缺少方式时升级为 turn；保留原语音 Key、实时音色、搜索 Key 与提示词。方舟 Key 独立存入 Keychain，不写入 UserDefaults。新方式在本机以 AAC / M4A 16 kHz 单声道、目标 16 kbps 录音，30 秒上限或点击发送后上传一次；取消后删除临时录音。用录音文件元数据计算时长，避免 AVAudioRecorder 自动停止后 currentTime 无定义导致自动发送失败。

方舟 Responses API 的音频理解模型一次返回转写、完整回答、最多 120 字朗读重点。默认 doubao-seed-2-0-lite-260428，关闭深度思考，store=false；上下文只包含最近 6 条、每条最多 1500 字的文字，不再次上传历史录音。搜索开启时传 web_search、max_keyword=1、limit=3、max_tool_calls=1，改用方舟联网内容插件；不传原搜索 Key，仅显示返回 annotations 中有效 HTTP(S) 引用。TTS 请求独立使用语音 Key、seed-tts-2.0、公开朗读音色 zh_female_vv_uranus_bigtts；audio_params 的 MP3 / 16 kHz / 16 kbps 与 req_params.additions 的 disable_default_bit_rate=true 按官方层级传递。

先展示问答，再下载 newline JSON / Base64 音频，确认合成结束码后交给 AVAudioPlayer 整段播放；网络等待期间关闭录音音频会话，播放启用 playback / spokenAudio。没有待机连接或静音上传，不自动重试计费请求；取消 / 打断 / 后台结束会取消 HTTP 任务和音频，UUID 隔离迟到结果。音频失败保留文字。正文响应上限 1 MiB、音频上限 2 MiB、音频 HTTP 编码传输上限 4 MiB，坏编码、服务错误、未完成下载均拒绝播放。

35 项本地测试通过：28 核心、4 原 Opus 音频、3 HTTP 服务。新增核心测试覆盖旧配置升级、文字历史有界、录音内联、低码率附加参数层级、结构化响应与真实引用、逐字节音频分片、无末尾换行、截断、服务错误脱敏、坏 Base64 及缓冲上限。URLProtocol 模拟 HTTP 测试实际通过 URLSession AsyncBytes 路径验证独立鉴权、先文字后声音、403 不重试和取消中止传输；只用虚拟 Key，无外部网络请求。

watchOS 真机架构 / 模拟器最终构建通过，仅有系统 AppIntents 元数据跳过提示。新建隔离的 42 mm watchOS 27 模拟器安装并检查默认一句一答设置与欢迎页：turn-42mm-settings.png、turn-42mm-welcome.png。未声称真实录音、云端音频理解、搜索授权、16 kbps 服务输出、扬声器 / 耳机路由或音色听感已验证；这些需要用户补填方舟 Key、开通合成服务后真机验收。未使用用户 Key、安装到实体手表、停止已有设备调试或增加手机端；检查后删除本次模拟器。工程生成器保留原 Team 和修正后的 AppIconScarf。

参考：
- https://docs.volcengine.com/docs/ark/audio-understanding?lang=zh
- https://docs.volcengine.com/docs/ark/create-model-responses-api?lang=zh
- https://docs.volcengine.com/docs/ark/web-search?lang=zh
- https://docs.volcengine.com/docs/DoubaoVoice/unidirectional-streaming-text-to-speech-http?lang=zh
- https://docs.volcengine.com/docs/DoubaoVoice/WebSocketBidirectionalStreaming-V3?lang=zh （req_params.additions 层级）
- https://github.com/bytedance/agentkit-samples/blob/main/skills/byted-text-to-speech/scripts/text_to_speech.py （资源 ID、默认朗读音色、成功及结束码）
# 启动、自动续录与本地静音裁剪（2026-10-07）

- 两种对话方式继续保留：设置中的「一句一答」与「实时通话」。实时通话的 Opus / PCM、联网搜索及已有密钥和音色配置保持原实现。
- 一句一答：播放完成后进入下一轮录音，仍由用户点击发送（30 秒上限到达时尝试发送）；点击结束、打断、进入后台或失败时停止，迟到的播放 / 网络回调不再开启录音。全静音直接在本地跳过请求、继续录音，不自动重试云端计费请求。
- 录音改为本地 16 kHz / 单声道 / 16-bit PCM CAF，最长 30 秒约 960 KB；后台读入、检测首尾低能量静音、保留 200 ms 前余量和 300 ms 后余量，保留所有句中停顿。能量检测不识别具体说话人，噪声或其他人声音不保证过滤。
- `AVAudioFile` 写 AAC 的实验样本超过目标码率（2.5 秒约 26 KB），修正为 `AVAudioConverter` 显式设置 CBR 16000 bit/s，并封装 AAC-LC M4A，含采样表和编码器 priming 的编辑表。本地播放器解码验证短词及 30 秒上限，避免把录音器专用的设置误当作实际压缩码率。临时录音由后台工作者拥有，取消时清理，避免边读取边删除。
- 合成样本：9 秒录音中只有 2 秒 220 Hz 声音；裁剪后解码时长约 2.556 秒，M4A 6104 字节。同码率 9 秒连续声音为 19454 字节，减少约 68.6%。仅为本地合成测试，不是真机语音或整轮 HTTP 流量测量。
- 初始界面不等待同步 Keychain 读取：配置从后台加载，加载期间禁用开始 / 修改 / 保存；HTTP 会话懒加载到发送阶段；首次录音避免初始化 AAC 编码器，已授权时不重复调用授权申请。权限弹窗、系统音频设备激活、调试启动、云端处理仍可能耗时；未声称真机启动时长改善了某个数值。
- 45 个 SwiftPM 测试通过：原协议 / 传输 / Opus 回归，加上首尾裁剪、内部停顿、安静声音、噪声、全静音 / 单次点击、实际 AAC 码率 / 解码、最长录音、短词、取消，以及模拟慢钥匙串不阻塞主线程测试。所有凭据来自虚拟测试值，没有读取用户真实密钥或调用云端。
- `Scripts/test_turn_lifecycle.py` 通过：使用真实 `ConversationModel` 的状态代码和本地音频 / HTTP / 设备替身，验证自动续录、历史保留、重复发送拦截、全静音零请求、压缩 / 下载中取消、结束后的迟到回调、失败停止和实时模式仍可进入。只替换 macOS 不支持的 WatchKit import，不替换状态逻辑。
- watchOS 真机目标及模拟器目标均以 `CODE_SIGNING_ALLOWED=NO` 编译通过。真机录音启动速度、静音阈值对实际声音的影响、服务端对新 M4A 的解析及完整带宽仍需用户安装后验证；未安装到实体手表，也未修改用户设备的蓝牙、配对或开发者设置。
- 新建专用 42 mm 模拟器核对欢迎页与设置页，后台配置加载后正常显示，设置说明没有截断。截图为 `Artifacts/silence-42mm-welcome.png`、`Artifacts/silence-42mm-settings.png`。验证后删除专用模拟器，未停止用户的模拟器或实体手表。
# 配置检查与请求错误诊断（2026-10-07）

- 通过用户已登录的 Safari 控制台只读核对：Seed 2.1 Lite 已开通；方舟 WatchAI Key 生效中、权限为全部；豆包语音 Key 启用，端到端实时语音已开通，但语音合成 2.0 未开通。因此确认一句一答的朗读存在服务权限缺项；还未读取实体手表的模式 / 模型字段和实际错误，不能断言这是所有失败的唯一原因。
- 未调用真实密钥、发送云端测试请求、点击开通 / 购买、接受协议、修改权限或停用密钥。Key 页面保持掩码，输出过滤长密钥标识。浏览器留在语音开通管理页方便用户自行处理。
- 改进 HTTP 失败诊断：最大 16 KB 错误体，仅解析已知错误类别和白名单参数，不显示服务端原始 message，防止回显凭据、提示词或音频。区分模型未开通 / 不存在、Key 鉴权、模型权限、参数兼容、额度和限流；无可安全识别的类别则继续只显示 HTTP 状态。
- 49 个 SwiftPM 测试通过：新增真实 URLSession AsyncBytes 的模型未开通错误、单次请求无重试、超大错误响应有界和字段脱敏测试；watchOS 真机目标无签名编译通过。
