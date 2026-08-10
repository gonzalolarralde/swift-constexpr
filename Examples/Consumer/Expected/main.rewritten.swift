import LocalSupport
import ManifestValues

let segments: SegmentList = ["api", "v1", "users"]
let route = segments.route()
let endpoint = Endpoint(route: route, port: 443)
let compileTimeURL = "https://example.test/api/v1/users:443"

// `decorate` belongs to the consumer and is intentionally not registered.
// ConstExpr still rewrites its independently known argument.
let output = decorate("https://example.test/api/v1/users:443")
print(output)
