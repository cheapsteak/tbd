import Foundation

/// Canonical AWS regions where Bedrock currently hosts Claude foundation
/// models, per AWS published docs (https://docs.aws.amazon.com/bedrock/latest/userguide/models-regions.html).
/// Grouped roughly by geography. Surface in the add-bedrock-profile form as
/// typeahead suggestions; the field still accepts any string so new regions
/// or GovCloud/China entries aren't blocked.
enum BedrockRegions {
    static let suggestions: [String] = [
        // US
        "us-east-1",
        "us-east-2",
        "us-west-2",
        // EU
        "eu-central-1",
        "eu-west-1",
        "eu-west-3",
        "eu-north-1",
        // APAC
        "ap-northeast-1",
        "ap-southeast-1",
        "ap-southeast-2",
        "ap-south-1",
        // Canada
        "ca-central-1",
    ]
}
