// Hand-written Swift gRPC client matching what protoc-gen-grpc-swift generates for
// sdk/PTSL_minimal.proto (package ptsl, service PTSL).
//
// GRPCClient protocol (grpc-swift 1.x) exposes performAsyncUnaryCall publicly.
// The protocol only requires `channel` and `defaultCallOptions` — no interceptors.

import GRPC
import NIOCore
import SwiftProtobuf

struct Ptsl_PTSLAsyncClient: GRPCClient {
    var channel: GRPCChannel
    var defaultCallOptions: CallOptions

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
