# 豆包AI · WatchAI

独立的 Apple Watch 原生豆包实时语音助手：手表麦克风 ⇄ 豆包实时语音模型 ⇄ 手表音频播放，问答文字同步显示。无需手机应用、服务器或音频中转。

应用仅保留实时通话，升级后沿用原来的语音 Key、实时音色、流量模式和回答风格。旧的一句一答配置自动迁移，方舟 Key、模型 ID 和单独朗读的设置不再使用；只有缺少独立搜索 Key 的旧一句一答配置会关闭搜索，补齐搜索配置即可重新开启。

启动时先显示界面，再在后台读取钥匙串；配置未加载完时禁用开始及保存。

## 实时通话

- 横向两屏：第一屏对话，左滑进入第二屏设置、右滑返回。「豆包AI」按屏幕尺寸与系统时间对齐，顶部使用透明渐变遮罩淡出滚动字幕；用户识别字幕、豆包回答字幕分别显示。待机首页只显示语音图标、一行描述、联网搜索开关状态及开始/配置按钮。
- 豆包实时语音 3.0 / Seeduplex：WebSocket JSON 事件协议，固定模型 `1.2.6.1`。
- 默认省流量模式：麦克风重采样为 16 kHz 单声道，系统编码器默认尝试 12 kbps 的 `speech_opus`，每 20 ms 发送一个原始 Opus 包；会话建立后才开始编码上传。
- 回复使用 `ogg_opus`，逐页拆包、解码为 24 kHz PCM 后先缓冲约 0.5 秒再播放，处理跨 WebSocket 分片、跨页包、Ogg pre-skip / 末尾裁剪、连续回复与打断，无需等待完整回复下载。声音断粮时自动提高到 1～2 秒缓冲，显示「声音缓冲中」，积累足够后续播；短回答收到结束事件后立即释放，不因阈值而一直等待。
- 可在「网络与流量 → 音频模式」切换兼容模式：上传 16 kHz Int16 PCM（每 20 ms / 640 字节），回复 24 kHz `pcm_s16le`。已有配置升级默认开启省流量，保留 Key、音色和回答风格。
- 默认开启本地语音能量检测：长时间没说话时发送服务端静音事件并停止上传音频，继续在本地监听；检测到说话后自动取消静音，并将最多 240 ms 开头缓冲按 20 ms 节奏发出，不突发补发。句尾保留约 800 ms 静音供服务端自动判停，句中短暂停顿不裁掉。这不是声纹识别，噪音和外放回声仍需真机验证；轻声漏识别时可关闭「静音时减少上传」。
- 可选择 12 kbps（默认）、8 kbps（试验）或 16 kbps（清晰）；编码器不支持所选码率时使用设备可用码率，实际选用值可在通话统计查看。不会自动切换到流量更大的 PCM。
- 网络中断时保留字幕和通话界面，暂停上传，自动重连并继续监听；结束通话或进入后台取消所有重试。左滑设置页可以查看本次上传 / 下载速率、累计字节、发送积压、播放缓冲、自动重连次数与上传编码码率。
- 20 ms 音频事件省去可选 UUID 和不必要的斜杠转义，保留控制事件 ID；静音仍使用服务端静音 / 恢复事件，保持全双工的正常判停。
- 通话底部固定显示「静音／恢复」「打断」「结束」三个按钮，利用底部安全区减少留白并保留 12 点底部间距，字幕和状态变化仅调整上方内容，不移动按钮；静音仍可听见回答，打断后继续对话，结束则关闭通话。服务端识别到新问题时也会停止旧音频。
- 按 20 ms 节奏顺序提交音频，允许发送回调延迟并限制未完成发送数；连接超时、错误提示、音频中断处理、音频设备变化自动恢复、等待关闭确认及超时清理。
- 在手表填写语音 / 豆包搜索 API Key，分别保存到本机 Keychain，选择音色、调整回答风格。
- 可开启豆包内置联网搜索，支持 Custom / Global；搜索在服务端执行，语音和字幕仍流式返回，保留省流量模式。
- 默认音色为「Vivi · 实时女声」，使用官方全双工 Web 示例的 VV 女声 `zh_female_vv_jupiter_bigtts`；也可选择小何、小天。升级后首次启动会将现有配置切到 Vivi，保留 Key 和回答风格；之后手动切换的音色会保持。这是火山引擎公开的实时语音音色，尚未确认与用户所指的豆包 App 文字回答「经典朗读」为同一音色。
- 字幕自动滚动可暂停，方便用数码表冠回看；重新开始会创建一段新对话。
- 明确标注的字幕演示模式，无 API 请求、无录音、无声音生成。

最低系统：watchOS 11。无第三方运行时依赖。

## 开始运行

1. 用 Xcode 打开 `WatchAI.xcodeproj`。
2. 选择唯一的 `WatchAI Watch App` scheme，运行目标选择 Apple Watch 或手表模拟器。
3. 真机运行前，在手表 target 的 Signing & Capabilities 中选择自己的 Team；按需修改 Bundle Identifier。工程只包含一个 watchOS target，使用 `WKWatchOnly = YES` 声明纯手表应用，没有手机端依赖。
4. 前往[豆包语音控制台](https://console.volcengine.com/speech/new/setting/apikeys?projectName=default)，获取语音 API Key，并确认已开通全双工端到端实时语音服务。
5. 手表左滑进入「豆包设置」，填写豆包语音 API Key 后保存。点击「开始对话」，允许麦克风权限，即可进行实时通话并查看字幕。

只看字幕界面时，可在模拟器启动参数中传入 `--demo` 自动演示。

**不要把真实 API Key 写入代码、截图、日志或版本库。** Key 存在手表的钥匙串中，配置文件不包含 Key；本项目不提供开发者共享密钥。API 调用由使用者的火山引擎账号计费，免费额度用完后的行为以控制台开通配置为准。

## 开启联网搜索

1. 前往[豆包搜索控制台](https://console.volcengine.com/search-infinity/web-search?projectName=default)，开通需要的 Web 搜索服务，获取对应的**搜索 API Key**。这是搜索服务的 Key，不是语音服务 Key。
2. 在手表「豆包设置 → 联网搜索」开启「允许联网搜索」，选择与服务 / Key 匹配的版本并填写搜索 Key。默认提供 Custom（官方描述延迟较低），也可选 Global（全球通用搜索）。不同版本及订阅 / 按量服务的 Key 权限须以控制台为准，不能混用。
3. 保存配置，然后开始一段新通话。可以说「帮我联网搜索今天的科技新闻，并告诉我来源」。普通闲聊由模型判断是否需要查询；开启开关不代表每一轮都已经搜索。

创建会话时通过 `extension.dialog.extra` 传入 `enable_volc_websearch`、`volc_websearch_type` 和 `volc_websearch_api_key`，由豆包语音服务调用搜索。只有搜索开启时才发送搜索 Key，Key 不进入 UserDefaults 或提示词；缺少搜索 Key 会在录音 / 连接前给出配置提示。切换备用连接会保留搜索配置，错误提示会隐藏语音与搜索 Key。搜索没有结果时通过提示词要求模型如实说明；本地 UI 不伪造搜索进度或来源。

搜索需要另行开通，并可能产生额外费用，详见[官方搜索计费](https://docs.volcengine.com/docs/87772/2272951)。本地测试验证参数、缺失 Key 校验和脱敏，尚未使用真实搜索 Key 验证检索结果、服务权限或计费。

## 编译与测试

如果当前 `xcode-select` 指向 CommandLineTools，可以只为当前命令指定 Xcode，不必改全局设置：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

xcodebuild -project WatchAI.xcodeproj -scheme 'WatchAI Watch App' \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath /tmp/watchai-derived CODE_SIGNING_ALLOWED=NO build

xcodebuild -project WatchAI.xcodeproj -scheme 'WatchAI Watch App' \
  -destination 'generic/platform=watchOS' \
  -derivedDataPath /tmp/watchai-device-derived CODE_SIGNING_ALLOWED=NO build

xcrun swift test --scratch-path /tmp/watchai-spm
python3 Scripts/test_transport.py
```

使用 `/tmp` 构建目录可以避免 iCloud 文件元数据导致测试包签名失败。核心与音频测试覆盖旧配置升级、两种音频模式、独立 libopus 生成的 Ogg 样本解码、分片/跨页边界、时长/音高、坏数据与有界缓冲、字幕归并、迟到的最终字幕、打断后丢弃旧回答以及 PCM 分包边界 / 缓冲上限。连接层使用 Network 框架，另有本地 WebSocket 测试验证鉴权请求头、上传掩码、Ping/Pong、跨 UTF-8 字节的分片与关闭响应；该测试只连接本机，使用虚拟 Key。

发送管线按采集的 20 ms 节奏提交，不逐包等待回调；积压判断使用未完成请求的字节数和最老请求的等待时间。音频最多 100 个未完成请求（控制事件另有 8 个预留），总量最多 128 KB，单个请求超过 2 秒未完成触发恢复。短暂回调迟到先容忍，不直接宣称带宽不足。已提交的音频不会再重复提交到旧连接；连接重建清空旧积压，不补发断线期间录音。本地回归验证 800 ms 回调延迟下每秒 50 包且内容顺序完整、永久无回调时的容量 / 时间上限与自动恢复。

麦克风分包定时器在安装录音 tap 前启动；PCM 转换一次分配输出内存。录音缓冲最多容纳 2 秒，兼容硬件回调的大批次数据（Apple 不保证实际批次等于请求的 `bufferSize`）。定时器发生合并时只发送当前一包，丢弃错过时段的旧音频；主线程阻塞超过 100 ms 的过期包也跳过，避免恢复后突发上传。系统长时间卡顿可能造成短暂声音缺失，持续超过缓冲上限仍结束通话并附带采样率、批次时长、缓冲时长和分包间隔供诊断，不包含 Key 或录音内容。新增测试验证 16384 帧录音批次、500 ms 定时器延迟、样本边界及 30 秒批次录音的内容与缓冲边界。

ASR 中间字幕按同一 `item_id` 替换当前识别结果，支持重复推送及识别修订；最终结果确认后不接受迟到的中间结果。助手回复的文本 delta 仍按 `response_id` 追加。这与官方 Web Demo 中 `setQuestion` 和 `appendAnswer` 的处理方式一致。

已建立通话后发生发送或网络失败，暂停上传，保留 250 ms 接收窗口，让迟到的服务端配置错误仍能阻止无效重试。短暂 `.waiting` 在窗口内恢复时继续使用原连接；真正断开则首次立即重连，连续失败后等待约 1、2、4、8 秒（上限 8 秒）。网络路径恢复会提前唤醒等待；网络路径不可用期间不开新连接。鉴权 / 参数等不可恢复错误停止重试，服务端临时错误重连，HTTP 429 采用更长等待。10 秒稳定连接后重置退避。

重连复用服务端 `session.created` 返回的会话 ID，接续历史上下文；本地字幕保留，未完成的旧回答标为打断。重新点击开始才清空记录、建立全新对话。接续上下文不等于未播完音频断点续传；断线期间没有上传的语音无法保证识别，应等「我在听」再继续说。自动重连可能再次产生 API 费用，只有前台的当前通话允许自动重连。

连接优先使用 Network 框架，首次握手未创建会话时可切换系统 URLSession；中途重连使用系统连接。连接及创建会话各有 15 秒超时，超时也进入自动恢复。保持系统 TLS 验证、密钥脱敏，不改动鉴权服务。

若手表通过配对手机联网却持续超时，先确认手机能联网，暂时关闭已开启的 VPN / 代理；也可以让手表直接连接可上网的 Wi-Fi，并在 iPhone 的「设置」中暂时关闭蓝牙后重试，以区分共享网络和手表独立网络。不要仅凭超时判断 Key 错误。备用方式也受 watchOS 实时语音网络许可限制，真机网络仍需验证。

`Scripts/generate_project.py` 可从当前源码重新生成不依赖 XcodeGen 的工程，会保留已选择的 Team；其他手动修改的工程设置会被覆盖。当前默认图标为 `AppIconScarf`：白色背景、棕色短发大眼睛女孩和红色围巾，1024 × 1024 不透明 PNG，根据用户提供的头像参考生成。原图与生成提示词保存在 `Artifacts/Design/`。工程生成器优先使用红围巾图标，保留之前的图标集；`Scripts/make_icon.swift` 仅生成旧版 `AppIcon` 图标集，不会替换当前选择。

## 实时通话省流量模式的验证与边界

省流量通过系统 AVAudioConverter 完成，应用没有新增第三方运行时依赖。上传默认为 12 kbps，支持 8 / 16 kbps 选项；服务端回复的 Opus 码率由服务端决定，接口未提供可确认的回复码率控制参数。API 仍要求 16 kHz 输入、24 kHz 输出与实时发送节奏，不能通过随意降采样或批量突发上传节省带宽。

本地 5 秒变化音调样本计入 Base64 和 JSON 后，Opus 上传约为 PCM 的十分之一；这是合成样本测量，不是用户真机通话测量，未计 TLS/TCP/IP 开销。独立 libopus 还验证了系统编码的 250 个包可解码为完整 5 秒、正确音高的音频（8 / 12 / 16 kbps 三档）。可选复现命令 `python3 Scripts/test_opus_reference.py` 需要本机安装 libopus，仅用于参考验证，不影响应用运行和主要测试。

音频设备恢复期间保留当前 Ogg 解码状态；新回复、主动打断或结束会重置相关状态。压缩模式解码错误时会给出提示，可手动选择兼容模式后重试，不会为编解码错误自动切换 PCM 或反复重连。省流量降低吞吐需求；网络故障会等待恢复并自动重连。系统编解码在 macOS 上已执行验证，watchOS 真机/模拟器已编译；真实手表的编解码可用性、耗电、听感及云端 `speech_opus` 接入仍须安装验证。

音色选择依然是公开实时音色，尚未确认用户所指豆包 App「经典朗读」与公开 speaker ID 的映射。压缩并不会把 Vivi 变成另一种音色，也没有将未确认的音色标为 App 同款。

## 运行边界与待验证

- 已验证的模拟器编译和字幕演示不等于真实云端通话验证。没有填入有效 API Key 前，无法验证服务权限、实际识别、延迟、音色及计费。
- Apple Watch 的 WebSocket 属于低层网络；系统只在特定音频 / 通话场景允许使用。本应用使用 Network 框架的 WebSocket，在创建连接前异步启用 `.playAndRecord` / `.voiceChat` 音频会话和语音处理，并声明音频能力。仍必须用真机分别验证配对手机可用、Wi-Fi 独立联网、蜂窝联网等环境，模拟器不会复现该限制。
- 首版在应用进入后台时结束通话。抬腕使用期间可对话，不提供熄屏常驻录音；后台连续通话需要后续专门验证系统运行许可。
- 声音路由由系统选择，受手表型号、系统和耳机连接影响。音频配置变化后，应用先检查引擎运行状态和输入格式；正常时继续通话，停止时尝试恢复，格式变化时重建录音转换器。10 秒内最多恢复 3 次，失败或持续变化时提示重连。系统通话中断仍会结束当前对话。真机需检查扬声器、AirPods、外放回声与插话识别。
- 聊天文字仅留在当前内存，不持久化；重新开始通话或重启应用会清除文字。
- 联网搜索需手动开启，并使用独立搜索 Key。唱歌、声音克隆当前未开启。

## 官方协议参考

- [豆包全双工接口](https://docs.volcengine.com/docs/DoubaoVoice/endtoend-realtime-voice-full-duplex-version?lang=zh&redirect=1)
- [接入必读](https://docs.volcengine.com/docs/DoubaoVoice/access-mustread?lang=zh)
- [Apple watchOS 网络限制](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)
- [Apple 纯手表应用标识 WKWatchOnly](https://developer.apple.com/documentation/bundleresources/information-property-list/wkwatchonly)

协议依据 2026-10-06 查阅的官方文档及官方 Python 示例。接口：`wss://openspeech.bytedance.com/api/v3/duplex/realtime/dialogue`；鉴权：`X-Api-Key`。
