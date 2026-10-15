import Darwin

/// Runs `operation` over `inputs` with at most `limit` tasks in flight, delivering results
/// on the main actor as they complete. Stops scheduling new work when cancelled.
///
/// Pinned to `@MainActor` on purpose: with an `isolated (any Actor)? = #isolation` parameter the
/// task group body is not inferred as isolated, so `onResult` ran on the cooperative pool and
/// tripped the main-actor check when it touched model state.
@MainActor
func withLimitedConcurrency<Input: Sendable, Output: Sendable>(
    _ inputs: [Input],
    limit: Int,
    operation: @escaping @Sendable (Input) async -> Output,
    onResult: (Output) -> Void
) async {
    await withTaskGroup(of: Output.self) { group in
        var iterator = inputs.makeIterator()
        for _ in 0..<limit {
            guard let input = iterator.next() else { break }
            group.addTask { await operation(input) }
        }
        while let output = await group.next() {
            onResult(output)
            if !Task.isCancelled, let input = iterator.next() {
                group.addTask { await operation(input) }
            }
        }
    }
}

enum ResourceLimits {
    /// GUI apps start with a soft limit of 256 descriptors; scans keep hundreds of sockets open.
    static func raiseOpenFileLimit(to target: rlim_t = 4096) {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let desired = min(target, limit.rlim_max)
        guard limit.rlim_cur < desired else { return }
        limit.rlim_cur = desired
        setrlimit(RLIMIT_NOFILE, &limit)
    }
}
