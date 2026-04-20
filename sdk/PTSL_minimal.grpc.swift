// Hand-written Swift gRPC client matching what protoc-gen-grpc-swift generates for
// sdk/PTSL_minimal.proto (package ptsl, service PTSL).
//
// Uses grpc-swift 1.x GRPCClient protocol — performAsyncUnaryCall is public on it.

import GRPC
import NIOCore
import SwiftProtobuf

// MARK: - Async/Await client (grpc-swift 1.x)

struct Ptsl_PTSLAsyncClient: GRPCClient {
    var channel: GRPCChannel
    var defaultCallOptions: CallOptions
    var interceptors: ClientInterceptorFactoryProtocol? = nil

    init(channel: GRPCChannel, defaultCallOptions: CallOptions = CallOptions()) {
        self.channel = channel
        self.defaultCallOptions = defaultCallOptions
    }

    func sendGrpcRequest(
        _ request: Ptsl_Request,
        callOptions: CallOptions? = nil
    ) async throws -> Ptsl_Response {
        return try await performAsyncUnaryCall(
            path: "/ptsl.PTSL/SendGrpcRequest",
            request: request,
            callOptions: callOptions ?? defaultCallOptions,
            interceptors: []
        )
    }
}
