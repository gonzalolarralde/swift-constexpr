import LocalSupport
import ManifestValues

let segments: SegmentList = ["api", "v1", "users"]
let route = segments.route()
let endpoint = Endpoint(route: route, port: makePort(440))
let compileTimeURL = endpoint.url()

// `decorate` belongs to the consumer and is intentionally not registered.
// ConstExpr still rewrites its independently known argument.
let output = decorate(compileTimeURL)
print(output)
