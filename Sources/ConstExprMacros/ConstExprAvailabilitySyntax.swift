import Foundation
import SwiftSyntax

struct ConstExprRegistrationMetadataSource {
    let availability: String
    let isDisfavoredOverload: Bool

    init(attributes: AttributeListSyntax) {
        var availabilityEntries: [String] = []
        var disfavored = false

        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self) else { continue }
            let name = attribute.attributeName.constExprSource
                .split(separator: ".").last.map(String.init) ?? ""
            if name == "_disfavoredOverload" {
                disfavored = true
                continue
            }
            guard name == "available" else { continue }
            availabilityEntries.append(contentsOf: Self.entries(for: attribute))
        }

        availability = "[\(availabilityEntries.joined(separator: ", "))]"
        isDisfavoredOverload = disfavored
    }

    var arguments: String {
        var result = ""
        if availability != "[]" {
            result += "\n    availability: \(availability),"
        }
        if isDisfavoredOverload {
            result += "\n    isDisfavoredOverload: true,"
        }
        return result
    }

    var isUnconditionallyUnavailable: Bool {
        availability.contains("domain: \"*\", isUnavailable: true")
    }

    var hasDeprecatedAvailability: Bool {
        availability.contains("deprecated:")
            || availability.contains("isDeprecated: true")
    }

    var hasObsoletedAvailability: Bool {
        availability.contains("obsoleted:")
    }

    private struct Domain {
        let name: String
        var introduced: String?
        var deprecated: String?
        var obsoleted: String?
        var unavailable = false
        var isDeprecated = false

        var source: String {
            let introduced = introduced.map { ", introduced: \($0)" } ?? ""
            let deprecated = deprecated.map { ", deprecated: \($0)" } ?? ""
            let obsoleted = obsoleted.map { ", obsoleted: \($0)" } ?? ""
            let unavailable = unavailable ? ", isUnavailable: true" : ""
            let isDeprecated = isDeprecated ? ", isDeprecated: true" : ""
            return "_ConstExprRuntime.Availability(domain: \(name.constExprStringLiteral)\(introduced)\(deprecated)\(obsoleted)\(unavailable)\(isDeprecated))"
        }
    }

    private static func entries(for attribute: AttributeSyntax) -> [String] {
        guard case .availability(let arguments) = attribute.arguments else {
            return [unparsedAvailability]
        }
        var domains: [Domain] = []
        var introduced: String?
        var deprecated: String?
        var obsoleted: String?
        var unavailable = false
        var isDeprecated = false

        for argument in arguments {
            switch argument.argument {
            case .availabilityVersionRestriction(let restriction):
                let name = restriction.platform.constExprIdentifier
                if name == "*" { continue }
                if let version = restriction.version.flatMap(versionSource) {
                    domains.append(Domain(
                        name: name,
                        introduced: version,
                        deprecated: nil,
                        obsoleted: nil
                    ))
                } else {
                    domains.append(Domain(
                        name: name,
                        introduced: nil,
                        deprecated: nil,
                        obsoleted: nil
                    ))
                }
            case .availabilityLabeledArgument(let labeled):
                guard case .version(let version) = labeled.value,
                      let source = versionSource(version)
                else { continue }
                switch labeled.label.text {
                case "introduced": introduced = source
                case "deprecated": deprecated = source
                case "obsoleted": obsoleted = source
                default: break
                }
            case .token(let token):
                if token.text == "unavailable" {
                    unavailable = true
                } else if token.text == "deprecated" {
                    isDeprecated = true
                } else if token.text != "*" {
                    domains.append(Domain(
                        name: token.constExprIdentifier,
                        introduced: nil,
                        deprecated: nil,
                        obsoleted: nil
                    ))
                }
            @unknown default:
                return [unparsedAvailability]
            }
        }

        guard !domains.isEmpty else {
            if unavailable {
                return ["_ConstExprRuntime.Availability(domain: \"*\", isUnavailable: true)"]
            }
            if isDeprecated {
                return ["_ConstExprRuntime.Availability(domain: \"*\", isDeprecated: true)"]
            }
            return []
        }
        return domains.map { domain in
            var domain = domain
            domain.introduced = domain.introduced ?? introduced
            domain.deprecated = domain.deprecated ?? deprecated
            domain.obsoleted = domain.obsoleted ?? obsoleted
            domain.unavailable = domain.unavailable || unavailable
            domain.isDeprecated = domain.isDeprecated || isDeprecated
            return domain.source
        }
    }

    private static func versionSource(_ version: VersionTupleSyntax) -> String? {
        let components = version.constExprSource
            .split(separator: ".")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !components.isEmpty, components.count <= 3 else { return nil }
        return "_ConstExprRuntime.AvailabilityVersion(major: \(components[0]), minor: \(components.count > 1 ? components[1] : 0), patch: \(components.count > 2 ? components[2] : 0))"
    }

    private static let unparsedAvailability =
        "_ConstExprRuntime.Availability(domain: \"__unparsed__\", isUnavailable: true)"
}
