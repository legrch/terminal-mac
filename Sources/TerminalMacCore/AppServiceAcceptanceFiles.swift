import Foundation

public extension AppServiceFiles {
    struct AcceptedInputs {
        public let policy: AppVerificationPolicy
        public let policyBytes: Data
        public let acceptedBytes: Data
    }

    /// The controller's separately retained acceptance hash is the binding;
    /// a policy supplied by the payload cannot declare itself trusted.
    static func acceptance(in stage: AppServiceDirectory, expectedDigest: String,
                           payload: AppServicePayload, manifestDigest: String) throws -> AcceptedInputs {
        guard AppServiceContract.hex(expectedDigest, count: 64),
              let acceptedBytes = try stage.read("accepted-application.json", limit: 65536),
              AppServiceDirectory.digest(acceptedBytes) == expectedDigest,
              let policyBytes = try stage.read("verification-policy.json", limit: 65536) else {
            throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY")
        }
        let accepted = try AcceptedApplication.decode(acceptedBytes)
        let policyDigest = AppServiceDirectory.digest(policyBytes)
        try accepted.validate(payload: payload, manifestDigest: manifestDigest, policyDigest: policyDigest)
        let policy = try AppVerificationPolicy.decode(policyBytes)
        try policy.validate(payload: payload)
        return AcceptedInputs(policy: policy, policyBytes: policyBytes, acceptedBytes: acceptedBytes)
    }
}
