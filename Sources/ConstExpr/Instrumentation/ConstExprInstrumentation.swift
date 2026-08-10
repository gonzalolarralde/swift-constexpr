#if canImport(os)
import os
#endif

struct ConstExprSignpostInterval {
    let enabled: Bool
#if canImport(os)
    let name: StaticString
    let identifier: OSSignpostID?
#endif
}

enum ConstExprInstrumentation {
#if canImport(os)
    private static let log = OSLog(
        subsystem: "org.swift.constexpr",
        category: "Evaluation"
    )
#endif

    static func begin(
        _ name: StaticString,
        enabled: Bool
    ) -> ConstExprSignpostInterval {
#if canImport(os)
        guard enabled else {
            return ConstExprSignpostInterval(
                enabled: false,
                name: name,
                identifier: nil
            )
        }
        let identifier = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: identifier)
        return ConstExprSignpostInterval(
            enabled: true,
            name: name,
            identifier: identifier
        )
#else
        return ConstExprSignpostInterval(enabled: false)
#endif
    }

    static func end(_ interval: ConstExprSignpostInterval) {
#if canImport(os)
        guard interval.enabled, let identifier = interval.identifier else { return }
        os_signpost(
            .end,
            log: log,
            name: interval.name,
            signpostID: identifier
        )
#endif
    }

    static func evaluationMetrics(
        nodeCount: Int,
        candidateRegistrationCount: Int,
        renderedReplacementCount: Int,
        enabled: Bool
    ) {
#if canImport(os)
        guard enabled else { return }
        os_signpost(
            .event,
            log: log,
            name: "EvaluationMetrics",
            "nodes=%{public}d candidates=%{public}d replacements=%{public}d",
            nodeCount,
            candidateRegistrationCount,
            renderedReplacementCount
        )
#endif
    }

    /// Emits one aggregate event per evaluation. Type lookup is intentionally
    /// not signposted per expression because doing so would distort the hot
    /// path this instrumentation is intended to measure.
    static func typeResolutionMetrics(
        _ metrics: ConstExprTypeResolutionMetrics,
        enabled: Bool
    ) {
#if canImport(os)
        guard enabled else { return }
        os_signpost(
            .event,
            log: log,
            name: "TypeResolution",
            "lookups=%{public}d cacheHits=%{public}d cacheMisses=%{public}d ambiguous=%{public}d",
            metrics.lookups,
            metrics.cacheHits,
            metrics.cacheMisses,
            metrics.ambiguousLookups
        )
#endif
    }
}
