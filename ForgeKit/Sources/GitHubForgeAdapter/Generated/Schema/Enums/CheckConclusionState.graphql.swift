// @generated
// This file was automatically generated and should not be edited.

@_spi(Internal) import ApolloAPI

extension GitHubAPI {
  nonisolated enum CheckConclusionState: String, EnumType {
    case actionRequired = "ACTION_REQUIRED"
    case cancelled = "CANCELLED"
    case failure = "FAILURE"
    case neutral = "NEUTRAL"
    case skipped = "SKIPPED"
    case stale = "STALE"
    case startupFailure = "STARTUP_FAILURE"
    case success = "SUCCESS"
    case timedOut = "TIMED_OUT"
  }

}
