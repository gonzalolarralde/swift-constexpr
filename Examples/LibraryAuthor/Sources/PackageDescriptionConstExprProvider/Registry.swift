import ConstExpr
import PackageDescriptionModel

/// A registry for the intentionally bounded PackageDescription facade.
/// Keeping this separate from the real manifest runtime avoids its process-exit
/// serialization behavior and special toolchain-only linkage requirements.
public let packageDescriptionConstExprRegistry = #constExprRegistry(
    Package.self,
    Package.Dependency.self,
    Product.self,
    SupportedPlatform.self,
    SupportedPlatform.MacOSVersion.self,
    Trait.self,
    Target.self,
    Target.Dependency.self
)
