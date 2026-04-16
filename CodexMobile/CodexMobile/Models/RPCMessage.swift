// FILE: RPCMessage.swift
// Purpose: Models inbound/outbound JSON-RPC 2.0 envelopes for Codex App Server.
// Layer: Model
// Exports: RPCMessage, RPCError, RPCObject
// Depends on: JSONValue

import Foundation

typealias RPCObject = [String: JSONValue]

struct RPCMessage: Codable, Sendable {
    let jsonrpc: String?
    let id: JSONValue?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: RPCError?

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
        case result
        case error
    }

    // --- Convenience initializers ---------------------------------------------

    // Builds an RPC request/notification payload to send over WebSocket.
    init(id: JSONValue? = nil, method: String, params: JSONValue? = nil, includeJSONRPC: Bool = true) {
        self.jsonrpc = includeJSONRPC ? "2.0" : nil
        self.id = id
        self.method = method
        self.params = params
        self.result = nil
        self.error = nil
    }

    // Builds an RPC successful response payload.
    init(id: JSONValue?, result: JSONValue, includeJSONRPC: Bool = true) {
        self.jsonrpc = includeJSONRPC ? "2.0" : nil
        self.id = id
        self.method = nil
        self.params = nil
        self.result = result
        self.error = nil
    }

    // Builds an RPC error response payload.
    init(id: JSONValue?, error: RPCError, includeJSONRPC: Bool = true) {
        self.jsonrpc = includeJSONRPC ? "2.0" : nil
        self.id = id
        self.method = nil
        self.params = nil
        self.result = nil
        self.error = error
    }

    // Allows decoding messages that already include all JSON-RPC fields.
    init(
        jsonrpc: String? = "2.0",
        id: JSONValue? = nil,
        method: String? = nil,
        params: JSONValue? = nil,
        result: JSONValue? = nil,
        error: RPCError? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc)
        id = try container.decodeIfPresent(JSONValue.self, forKey: .id)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try container.decodeIfPresent(RPCError.self, forKey: .error)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(jsonrpc, forKey: .jsonrpc)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

extension RPCMessage {
    // --- Message kind helpers -------------------------------------------------

    nonisolated var isRequest: Bool {
        method != nil
    }

    nonisolated var isResponse: Bool {
        result != nil || error != nil
    }

    nonisolated var isErrorResponse: Bool {
        error != nil
    }
}

struct RPCError: Codable, Error, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?

    init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case data
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        data = try container.decodeIfPresent(JSONValue.self, forKey: .data)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(data, forKey: .data)
    }
}
