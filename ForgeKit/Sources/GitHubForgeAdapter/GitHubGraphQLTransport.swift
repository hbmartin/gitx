import Apollo
import Foundation

// swift6-safety-justification: NSLock serializes every access to the mutable
// response metadata captured across Apollo interceptor tasks.
final class GitHubResponseMetadataBox: @unchecked Sendable {
    private let lock = NSLock()
    private let installationConfigurationURL: URL?
    private var value: GitHubResponseMetadata?

    init(installationConfigurationURL: URL? = nil) {
        self.installationConfigurationURL = installationConfigurationURL
    }

    func record(_ response: HTTPURLResponse, body: Data = Data()) {
        let parsed = GitHubHTTPMetadataParser.metadata(
            from: response,
            body: body,
            installationConfigurationURL: installationConfigurationURL,
            receivedAt: Date()
        )
        lock.withLock {
            value = GitHubResponseMetadata(
                statusCode: parsed.statusCode,
                requestID: parsed.requestID,
                rateLimit: parsed.rateLimit,
                saml: parsed.saml ?? value?.saml,
                installation: parsed.installation ?? value?.installation
            )
        }
    }

    func take() -> GitHubResponseMetadata? {
        lock.withLock { value }
    }
}

private struct GitHubMetadataInterceptor: HTTPInterceptor {
    let box: GitHubResponseMetadataBox

    func intercept(
        request: URLRequest,
        next: NextHTTPInterceptorFunction
    ) async throws -> HTTPResponse {
        let response = try await next(request)
        box.record(response.response)
        return await response.mapChunks { response, chunk in
            box.record(response, body: chunk)
            return chunk
        }
    }
}

private struct GitHubInterceptorProvider: InterceptorProvider {
    let box: GitHubResponseMetadataBox

    func httpInterceptors<Operation>(for _: Operation) -> [any HTTPInterceptor] {
        [ResponseCodeInterceptor(), GitHubMetadataInterceptor(box: box)]
    }
}

enum GitHubGraphQLTransportFactory {
    static func makeClient(
        accessToken: GitHubSecret,
        sessionConfiguration: URLSessionConfiguration,
        metadataBox: GitHubResponseMetadataBox,
        store: ApolloStore
    ) -> ApolloClient {
        let session = URLSession(configuration: sessionConfiguration)
        var headers = [
            "Accept": "application/vnd.github+json",
            "User-Agent": "GitX-ForgeKit",
            "X-GitHub-Api-Version": "2022-11-28",
        ]
        headers["Authorization"] = accessToken.withUnsafeUTF8Bytes {
            "Bearer \(String(decoding: $0, as: UTF8.self))"
        }
        let transport = RequestChainNetworkTransport(
            urlSession: session,
            interceptorProvider: GitHubInterceptorProvider(box: metadataBox),
            store: store,
            endpointURL: URL(string: "https://api.github.com/graphql")!,
            additionalHeaders: headers
        )
        return ApolloClient(networkTransport: transport, store: store)
    }
}

enum GitHubHTTPMetadataParser {
    static func metadata(
        from response: HTTPURLResponse,
        body: Data = Data(),
        installationConfigurationURL: URL? = nil,
        receivedAt: Date
    ) -> GitHubResponseMetadata {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let name = entry.key as? String, let value = entry.value as? String else { return }
            result[name] = value
        }
        let rateLimit = GitHubRateLimitParser.parse(
            statusCode: response.statusCode,
            headers: headers,
            receivedAt: receivedAt
        )
        let authorization = GitHubRESTAuthorizationParser.responseMetadata(
            statusCode: response.statusCode,
            headers: headers,
            body: body,
            installationConfigurationURL: installationConfigurationURL
        )
        return GitHubResponseMetadata(
            statusCode: response.statusCode,
            requestID: nonempty(response.value(forHTTPHeaderField: "X-GitHub-Request-Id")),
            rateLimit: rateLimit,
            saml: authorization.saml,
            installation: authorization.installation
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
