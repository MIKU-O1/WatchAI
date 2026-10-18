import Foundation

public struct VoiceSettings: Codable, Equatable, Sendable {
    public static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/duplex/realtime/dialogue")!
    // Vivi / VV is the default voice in Doubao's official full-duplex Web demo.
    public static let defaultVoice = "zh_female_vv_jupiter_bigtts"
    public var voice = Self.defaultVoice
    public var instructions = "你是腕上的中文语音助手。回答自然、清晰、简短，通常用一到三句话回答。用户需要详细解释时再展开。不使用 Markdown 标记。不确定的事情如实说明。"
    public enum BandwidthMode: String, Codable, CaseIterable, Sendable {
        case economy, compatible
        public var inputFormat: String { self == .economy ? "speech_opus" : "pcm" }
        public var outputFormat: String { self == .economy ? "ogg_opus" : "pcm_s16le" }
    }
    public enum WebSearchType: String, Codable, CaseIterable, Sendable {
        case custom = "web_custom_api", global = "web_global_api"
    }
    public enum UploadRate: Int, Codable, CaseIterable, Sendable {
        case low = 8000, balanced = 12000, clear = 16000
    }
    public var uploadRate: UploadRate = .balanced
    public var suppressSilence = true
    public var webSearchEnabled = false
    public var webSearchType: WebSearchType = .custom
    public var bandwidthMode: BandwidthMode = .economy
    public init() {}
    private enum CodingKeys: String, CodingKey { case voice, instructions, bandwidthMode, webSearchEnabled, webSearchType, uploadRate, suppressSilence }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uploadRate = try values.decodeIfPresent(UploadRate.self, forKey: .uploadRate) ?? .balanced
        suppressSilence = try values.decodeIfPresent(Bool.self, forKey: .suppressSilence) ?? true
        voice = try values.decodeIfPresent(String.self, forKey: .voice) ?? Self.defaultVoice
        instructions = try values.decodeIfPresent(String.self, forKey: .instructions) ?? VoiceSettings().instructions
        bandwidthMode = try values.decodeIfPresent(BandwidthMode.self, forKey: .bandwidthMode) ?? .economy
        webSearchEnabled = try values.decodeIfPresent(Bool.self, forKey: .webSearchEnabled) ?? false
        webSearchType = try values.decodeIfPresent(WebSearchType.self, forKey: .webSearchType) ?? .custom
    }
    public func validate(searchAPIKey: String) throws {
        if webSearchEnabled && searchAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProtocolError.missingSearchKey
        }
    }
}

public enum DoubaoProtocol {
    public static func event(_ type: String, fields: [String: Any] = [:]) -> [String: Any] {
        var result = fields
        result["type"] = type
        result["event_id"] = UUID().uuidString
        return result
    }

    public static func createSession(settings: VoiceSettings, searchAPIKey: String = "",
                                     sessionID: String = UUID().uuidString) throws -> [String: Any] {
        try settings.validate(searchAPIKey: searchAPIKey)
        var extra: [String: Any] = ["enable_loudness_norm": true]
        var instructions = settings.instructions + "\n默认先用两句话直接回答重点，避免重复问题和冗长铺垫；用户要求详细解释时再展开。"
        if settings.webSearchEnabled {
            extra["enable_volc_websearch"] = true
            extra["volc_websearch_type"] = settings.webSearchType.rawValue
            extra["volc_websearch_api_key"] = searchAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            instructions += "\n用户明确要求联网搜索，或问题需要最新新闻、天气、价格等实时信息时，请先联网检索再回答。说明所查信息的时间和来源；如果查询失败或没有结果，请如实说明，不要将记忆中的内容声称为联网查到的结果。"
        }
        return event("session.create", fields: [
            "session": [
                "id": sessionID,
                "model": "1.2.6.1",
                "instructions": instructions,
                "audio": [
                    "input": ["format": ["type": settings.bandwidthMode.inputFormat, "rate": 16000]],
                    "output": [
                        "format": ["type": settings.bandwidthMode.outputFormat, "rate": 24000],
                        "voice": settings.voice
                    ]
                ]
            ],
            "extension": ["dialog": ["extra": extra]]
        ])
    }

    public static func audio(_ packet: Data) -> [String: Any] {
        // event_id is optional; omit a UUID on every 20 ms audio frame.
        ["type": "input_audio_buffer.append", "audio": packet.base64EncodedString()]
    }

    public static func encode(_ event: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

public struct ServerEvent: Sendable {
    public let type: String
    public let itemID: String?
    public let responseID: String?
    public let delta: String?
    public let text: String?
    public let sessionID: String?
    public let errorMessage: String?
    public let statusCode: String?

    public init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw ProtocolError.invalidEvent }
        self.type = type
        itemID = object["item_id"] as? String
        responseID = object["response_id"] as? String
        delta = object["delta"] as? String
        text = object["transcript"] as? String ?? object["text"] as? String
        sessionID = (object["session"] as? [String: Any])?["id"] as? String
        let error = object["error"] as? [String: Any]
        errorMessage = error?["message"] as? String ?? object["message"] as? String
            ?? object["error"] as? String
        let code = error?["code"] ?? object["status_code"] ?? object["code"]
        statusCode = code.map { String(describing: $0) }
    }

    public var audioData: Data? {
        guard type == "response.output_audio.delta", let delta else { return nil }
        return Data(base64Encoded: delta)
    }
}

public enum ProtocolError: LocalizedError {
    case invalidEvent, invalidAudio, slowConnection, playbackBacklog, microphoneBacklog, missingSearchKey
    public var errorDescription: String? {
        switch self {
        case .missingSearchKey: return "请在手表设置中填写豆包搜索 API Key，并选择已开通的搜索版本；也可以暂时关闭联网搜索。"
        case .invalidEvent: return "豆包返回了无法解析的数据。请结束后重新连接。"
        case .invalidAudio: return "收到的语音数据格式不正确。"
        case .playbackBacklog: return "语音播放缓冲已满。"
        case .slowConnection: return "网络传输跟不上实时语音，请换一个网络后重试。"
        case .microphoneBacklog: return "麦克风音频处理积压，请重新开始通话。"
        }
    }
}
