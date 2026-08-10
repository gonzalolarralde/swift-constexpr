import ConstExpr
import ManifestValues

/// The library author vends this registry as a host-side provider product.
/// Applications depend on `ManifestValues`, not on this module.
public let manifestValuesConstExprRegistry = #constExprRegistry(
    makePort(_:),
    Segment.self,
    SegmentList.self,
    Route.self,
    Endpoint.self
)
