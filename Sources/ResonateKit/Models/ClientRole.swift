// ABOUTME: Defines the possible roles a Resonate client can assume
// ABOUTME: Clients can have multiple roles simultaneously (e.g., player + controller)

/// Roles that a Resonate client can assume
public enum ClientRole: String, Codable, Sendable, Hashable {
    /// Outputs synchronized audio
    case player
    /// Controls the Resonate group
    case controller
    /// Displays text metadata
    case metadata
    /// Displays artwork images
    case artwork
    /// Visualizes audio
    case visualizer
}
