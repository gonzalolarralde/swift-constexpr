enum ConstExprRegistrationAvailability: Sendable, Equatable {
    case available
    case unavailable
    case unknown
}

extension ConstExprRegistration {
    func availabilityState(
        in context: ConstExprAvailabilityContext?
    ) -> ConstExprRegistrationAvailability {
        guard !availability.isEmpty else { return .available }

        for requirement in availability where requirement.domain == "*" {
            if requirement.isUnavailable || requirement.isDeprecated {
                return .unavailable
            }
        }
        let constrained = availability.filter { $0.domain != "*" }
        guard !constrained.isEmpty else { return .available }
        guard let context, !context.versions.isEmpty else { return .unknown }

        let applicable = constrained.compactMap { requirement -> (
            ConstExprAvailability,
            ConstExprAvailabilityVersion
        )? in
            context.versions[requirement.domain].map { (requirement, $0) }
        }
        // An availability domain not represented by the evaluation context is
        // another platform and therefore does not constrain this request.
        guard !applicable.isEmpty else { return .available }
        for (requirement, version) in applicable {
            if requirement.isUnavailable || requirement.isDeprecated {
                return .unavailable
            }
            if let introduced = requirement.introduced, version < introduced {
                return .unavailable
            }
            if let deprecated = requirement.deprecated, version >= deprecated {
                // Evaluation must not erase a compiler deprecation diagnostic.
                return .unavailable
            }
            if let obsoleted = requirement.obsoleted, version >= obsoleted {
                return .unavailable
            }
        }
        return .available
    }
}
