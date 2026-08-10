# SwiftPM ConstExpr profiling

After building the alternative loader, record release Time Profiler and
Allocations traces with:

```sh
Scripts/Performance/profile-swiftpm.sh \
  /path/to/swift-package-manager \
  100
```

The script launches the release XCTest bundle directly, so SwiftPM planning and
compilation are not mixed into the profile. It enables ConstExpr's aggregate
`os_signpost` intervals and counters with `SWIFTPM_CONSTEXPR_SIGNPOSTS=1`.
Artifacts go into a timestamped directory under
`swiftpm/.build/constexpr-profile` unless
`SWIFTPM_CONSTEXPR_PROFILE_OUTPUT` is set.

The benchmark prints cold latency and warmed mean, median, p90, and p99. Use
Time Profiler for CPU attribution and the Allocations trace for event counts;
Allocations instrumentation distorts latency substantially. Override its
default ten iterations with `SWIFTPM_CONSTEXPR_ALLOCATION_ITERATIONS`.
