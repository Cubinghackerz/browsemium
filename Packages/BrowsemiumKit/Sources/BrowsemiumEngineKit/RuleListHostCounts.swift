/// List-size metadata, never a request metric. Additional user hosts exclude
/// overlaps with the starter list and other installed user lists. Exception
/// rules can name hosts too; these counts make no claim about effectiveness.
public struct RuleListHostCounts: Sendable, Equatable {
    public let bundledHostCount: Int
    public let additionalUserHostCount: Int
    public let userListCount: Int

    public init(bundledHostCount: Int, additionalUserHostCount: Int, userListCount: Int) {
        self.bundledHostCount = bundledHostCount
        self.additionalUserHostCount = additionalUserHostCount
        self.userListCount = userListCount
    }
}
