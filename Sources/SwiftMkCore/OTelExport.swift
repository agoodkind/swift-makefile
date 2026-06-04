//
//  OTelExport.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import GRPC
import NIO
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
import OpenTelemetryProtocolExporterGrpc
import OpenTelemetrySdk

// MARK: - OTelExport

/// Exports the run's span over OTLP gRPC when a collector endpoint is set, so a
/// collector sees the same trace id the run prints in its header.
///
/// Export is opt-in: with `OTEL_EXPORTER_OTLP_ENDPOINT` unset, this does nothing
/// and no telemetry leaves the machine. When the endpoint is set, the run starts
/// one span whose trace id is the run's correlation trace id (carried through a
/// W3C parent span context), and flushes it to the collector at process exit.
public enum OTelExport {
    private static let serviceName = "swift-mk"
    private static let defaultPort = 4_317
    private static let flushTimeout: TimeInterval = 10
    private static let hostPortPartCount = 2

    nonisolated(unsafe) private static var provider: TracerProviderSdk?
    nonisolated(unsafe) private static var span: Span?
    nonisolated(unsafe) private static var group: EventLoopGroup?

    /// Start the export span for `correlation` when a collector endpoint is set.
    /// A missing or empty endpoint is a no-op, so a run without a collector
    /// produces ids and logs but ships nothing.
    public static func start(_ correlation: Correlation) {
        let endpoint = Env.get("OTEL_EXPORTER_OTLP_ENDPOINT")
        guard !endpoint.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        let (host, port) = parseEndpoint(endpoint)
        let loopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        group = loopGroup
        let channel = ClientConnection(
            configuration: ClientConnection.Configuration.default(
                target: .hostAndPort(host, port),
                eventLoopGroup: loopGroup))
        let exporter = OtlpTraceExporter(
            channel: channel,
            config: OtlpConfiguration(timeout: flushTimeout))
        let resource = Resource(attributes: [
            "service.name": AttributeValue.string(serviceName)
        ])
        let built = TracerProviderBuilder()
            .add(spanProcessor: SimpleSpanProcessor(spanExporter: exporter))
            .with(resource: resource)
            .build()
        provider = built
        OpenTelemetry.registerTracerProvider(tracerProvider: built)

        let parent = SpanContext.create(
            traceId: TraceId(fromHexString: correlation.traceID),
            spanId: SpanId(fromHexString: correlation.spanID),
            traceFlags: TraceFlags().settingIsSampled(true),
            traceState: TraceState())
        span = built.get(instrumentationName: serviceName)
            .spanBuilder(spanName: serviceName)
            .setParent(parent)
            .startSpan()
    }

    /// End the span and flush it to the collector. Safe to call when start was a
    /// no-op. Called at process exit so a short-lived run still exports.
    public static func shutdown() {
        span?.end()
        span = nil
        _ = provider?.forceFlush(timeout: flushTimeout)
        provider?.shutdown()
        provider = nil
        do {
            try group?.syncShutdownGracefully()
        } catch {
            Output.error("otel: could not shut down the export event loop: \(error)")
        }
        group = nil
    }

    /// Split `host:port` into its parts, defaulting the port and stripping a
    /// scheme prefix, which the gRPC target must not carry.
    private static func parseEndpoint(_ endpoint: String) -> (host: String, port: Int) {
        var value = endpoint.trimmingCharacters(in: .whitespaces)
        for scheme in ["http://", "https://"] where value.hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
        }
        let parts = value.split(separator: ":", maxSplits: 1)
        let host = parts.first.map(String.init) ?? "localhost"
        if parts.count == hostPortPartCount, let parsed = Int(parts[1]) {
            return (host, parsed)
        }
        return (host, defaultPort)
    }
}
