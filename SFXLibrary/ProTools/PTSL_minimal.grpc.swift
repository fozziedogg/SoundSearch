// DO NOT EDIT.
// Hand-written Swift gRPC client matching what protoc-gen-grpc-swift would generate for
// sdk/PTSL_minimal.proto (package ptsl, service PTSL).
//
// Requires grpc-swift 1.x (GRPCChannel / ClientConnection API).

import GRPC
import NIOCore
import SwiftProtobuf

// MARK: - Async/Await client (grpc-swift 1.x)

struct Ptsl_PTSLAsyncClient {
    var channel: GRPCChannel
    var defaultCallOptions: CallOptions

    init(channel: GRPCChannel, defaultCallOptions: CallOptions = CallOptions()) {
        self.channel = channel
        self.defaultCallOptions = defaultCallOptions
    }

    /// Unary RPC: SendGrpcRequest
    func sendGrpcRequest(
        _ request: Ptsl_Request,
        callOptions: CallOptions? = nil
    ) async throws -> Ptsl_Response {
        let options = callOptions ?? defaultCallOptions
        let call: GRPCAsyncUnaryCall<Ptsl_Request, Ptsl_Response> = channel.makeAsyncUnaryCall(
            path: "/ptsl.PTSL/SendGrpcRequest",
            request: request,
            callOptions: options,
            interceptors: []
        )
        return try await call.response
    }
}
