// MixpanelVapor
// Copyright (c) 2024 Petr Pavlik

import Foundation
import UAParserSwift
import Vapor

public struct AnyContent: Content {
    private let _encode: (Encoder) throws -> Void
    public init(_ wrapped: some Encodable) {
        self._encode = wrapped.encode
    }

    public func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }

    public init(from _: Decoder) throws {
        fatalError("we don't need this")
    }
}

public struct Event: Content {
    public var event: String
    public var properties: [String: AnyContent]?

    public init(name: String, properties: [String: any Content]? = nil) {
        self.event = name
        self.properties = properties?.mapValues { value in
            AnyContent(value)
        }
    }
}

/// Auth params to configure your Mixpanel instance with
public struct MixpanelConfiguration {
    /// The project id you with to be logging events to.
    public var projectId: String

    /// Username and password of the service account you with to use to authenticate.
    public var authorization: BasicAuthorization

    /// Initializer
    /// - Parameters:
    ///   - projectId: The project id you with to be logging events to.
    ///   - authorization: Username and password of the service account you with to use to authenticate.
    public init(projectId: String, authorization: BasicAuthorization) {
        self.projectId = projectId
        self.authorization = authorization
    }
}

final class Mixpanel {
    private let client: Client
    private let logger: Logger
    private let apiUrl = "https://api.mixpanel.com"
    private let configuration: MixpanelConfiguration

    init(client: Client, logger: Logger, configuration: MixpanelConfiguration) {
        self.client = client
        self.logger = logger
        self.configuration = configuration
    }

    /// Track an event to mixpanel
    /// - Parameters:
    ///   - name: The name of the event
    ///   - request: You can optionally pass request to automatically parse the ip address and user-agent header
    ///   - params: Optional custom params assigned to the event
    func track(events: [Event], request: Request? = nil) async {
        let improvedEvents = events.map { event in
            var properties: [String: any Content] = _addDefaultParams(to: event.properties ?? [:])

            if let request {
                // https://docs.mixpanel.com/docs/tracking/how-tos/effective-server-side-tracking

                if let ip = request.peerAddress?.ipAddress {
                    properties["ip"] = ip
                }

                if let userAgentHeader = request.headers[.userAgent].first {
                    let parser = UAParser(agent: userAgentHeader)

                    if let browser = parser.browser?.name {
                        properties["$browser"] = browser
                    }

                    if let device = parser.device?.vendor {
                        properties["$device"] = device
                    }

                    if let os = parser.os?.name {
                        properties["$os"] = os
                    }
                }
            }

            return Event(name: event.event, properties: properties)
        }

        do {
            let response = try await client.post(URI(string: apiUrl + "/import?strict=1&project_id=\(configuration.projectId)")) { req in

                req.headers.basicAuthorization = configuration.authorization

                req.headers.contentType = .json

                try req.content.encode(improvedEvents)
            }

            if response.status.code >= 400 {
                logger.error("Failed to post an event to Mixpanel", metadata: ["response": "\(response)"])
            }
        } catch {
            logger.report(error: error)
        }
    }

    func time(event: Event) async {
        let event = Event(name: event.event, properties: _addDefaultParams(to: event.properties ?? [:]))

        do {
            let response = try await client.post(URI(string: apiUrl + "/import?strict=1&project_id=\(configuration.projectId)")) { req in

                req.headers.basicAuthorization = configuration.authorization

                req.headers.contentType = .json

                try req.content.encode([event])
            }

            if response.status.code >= 400 {
                logger.error("Failed to post an event to Mixpanel", metadata: ["response": "\(response)"])
            }
        } catch {
            logger.report(error: error)
        }
    }

    private func _addDefaultParams(to params: [String: any Content]) -> [String: any Content] {
        var properties: [String: any Content] = [
            "time": Int(Date().timeIntervalSince1970 * 1000),
            "$insert_id": UUID().uuidString,
            "distinct_id": "",
        ]

        properties.merge(params) { current, _ in
            current
        }

        return properties
    }
}

public extension Application {
    /// Access mixpanel
    ///
    /// You can also use `request.mixpanel` when logging within a route handler.
    var mixpanel: MixpanelClient {
        .init(application: self, request: nil)
    }

    struct MixpanelClient {
        let application: Application
        let request: Request?

        struct ConfigurationKey: StorageKey {
            typealias Value = MixpanelConfiguration
        }

        public var configuration: MixpanelConfiguration? {
            get {
                application.storage[ConfigurationKey.self]
            }
            nonmutating set {
                self.application.storage[ConfigurationKey.self] = newValue
            }
        }

        private var client: Mixpanel? {
            guard let configuration else {
                (request?.logger ?? application.logger).error("MixpanelVapor not configured. Use app.mixpanel.configuration = ...")
                return nil
            }

            // This should not be necessary.
            return .init(
                client: request?.client ?? application.client,
                logger: request?.logger ?? application.logger,
                configuration: configuration
            )
        }

        /// Track an event to mixpanel
        /// - Parameters:
        ///   - name: The name of the event
        ///   - request: You can optionally pass request to automatically parse the ip address and user-agent header
        ///   - params: Optional custom params assigned to the event
        public func track(events: [Event], request: Request? = nil) async {
            await client?.track(events: events, request: request)
        }
    }
}

public extension Request {
    /// Access mixpanel
    var mixpanel: Application.MixpanelClient {
        .init(application: application, request: self)
    }
}
