import Foundation

/// The four progress-promotion conditions, hand-written.
///
/// `manifest.json` expresses each condition as a **JavaScript string** (e.g.
/// `request.withProgress === true && ['ingest', ...].includes(request.operation)`),
/// which a Swift generator cannot evaluate. So the predicates live here as
/// code, and `manifestConditions` carries the exact upstream strings — a test
/// asserts they still match the vendored manifest verbatim, so a contract
/// update that changes a condition fails loudly instead of silently skewing
/// call shapes.
public enum ProgressPredicates {

    /// The verbatim `progress.condition` strings from `manifest.json`.
    public static let manifestConditions: [String: String] = [
        "downloadAsset": "request.withProgress === true",
        "finetune": "request.withProgress === true && ['start', 'resume', undefined].includes(request.operation)",
        "loadModel": "request.withProgress === true",
        "rag": "request.withProgress === true && ['ingest', 'saveEmbeddings', 'reindex'].includes(request.operation)"
    ]

    /// Whether a request promotes the reply from unary to a progress stream.
    public static func promotes(method: String, withProgress: Bool?, operation: String?) -> Bool {
        guard withProgress == true else { return false }
        switch method {
        case "downloadAsset", "loadModel":
            return true
        case "finetune":
            // `undefined` in the JS condition: an absent operation counts.
            return operation == nil || operation == "start" || operation == "resume"
        case "rag":
            return operation == "ingest" || operation == "saveEmbeddings" || operation == "reindex"
        default:
            return false
        }
    }
}
