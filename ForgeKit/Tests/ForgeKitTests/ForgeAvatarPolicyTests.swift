@testable import ForgeKit
import Foundation
import XCTest

final class ForgeAvatarPolicyTests: XCTestCase {
    func testAllowlistAcceptsOnlyExactCredentialFreeGitHubAvatarOrigin() throws {
        XCTAssertEqual(
            ForgeAvatarSecurityConstants.exactGitHubHosts,
            ["avatars.githubusercontent.com"]
        )
        XCTAssertEqual(
            try ForgeAvatarURL("HTTPS://AVATARS.GITHUBUSERCONTENT.COM:443/u/1?v=4").url.absoluteString,
            "https://avatars.githubusercontent.com/u/1?v=4"
        )
        XCTAssertNoThrow(
            try ForgeAvatarURL("https://avatars.githubusercontent.com/u/%2f%AF%bc")
        )

        for destination in [
            "http://avatars.githubusercontent.com/u/1",
            "https://token@avatars.githubusercontent.com/u/1",
            "https://avatars.githubusercontent.com:444/u/1",
            "https://avatars.githubusercontent.com.evil.example/u/1",
            "https://sub.avatars.githubusercontent.com/u/1",
            "https://github.com/u/1",
            "https://127.0.0.1/u/1",
            "https://avatars.githubusercontent.com/u/1#fragment",
            "https://avatars.githubusercontent.com/%ZZ",
            "not a URL",
        ] {
            XCTAssertThrowsError(try ForgeAvatarURL(destination), destination) { error in
                XCTAssertEqual(error as? ForgeAvatarPolicyError, .disallowedURL)
            }
        }
    }

    func testAvatarURLCodableRoundTripRevalidatesInput() throws {
        let value = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/2?size=64")
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(ForgeAvatarURL.self, from: encoded), value)

        let invalid = Data(#""https://evil.example/avatar.png""#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeAvatarURL.self, from: invalid))
    }

    func testMediaTypesAreExactAndParametersAreIgnoredSafely() {
        XCTAssertEqual(ForgeAvatarMediaType(httpContentType: "image/png"), .png)
        XCTAssertEqual(ForgeAvatarMediaType(httpContentType: " IMAGE/JPEG ; charset=binary"), .jpeg)
        XCTAssertEqual(ForgeAvatarMediaType(httpContentType: "image/gif"), .gif)
        XCTAssertEqual(ForgeAvatarMediaType(httpContentType: "image/webp"), .webP)
        XCTAssertNil(ForgeAvatarMediaType(httpContentType: nil))
        XCTAssertNil(ForgeAvatarMediaType(httpContentType: ""))
        XCTAssertNil(ForgeAvatarMediaType(httpContentType: "image/svg+xml"))
        XCTAssertNil(ForgeAvatarMediaType(httpContentType: "text/html"))
        XCTAssertEqual(
            ForgeAvatarMediaType.acceptHeader,
            "image/png, image/jpeg, image/gif, image/webp"
        )
    }

    func testResponseMetadataRevalidatesStatusFinalURLMediaTypeAndLength() throws {
        let accepted = try ForgeAvatarResponseMetadata(
            finalURL: XCTUnwrap(URL(string: "https://avatars.githubusercontent.com/u/1")),
            statusCode: 200,
            contentType: "image/png",
            expectedByteCount: 128,
            maximumResponseBytes: 256
        )
        XCTAssertEqual(accepted.mediaType, .png)
        XCTAssertEqual(accepted.expectedByteCount, 128)

        let unknownLength = try ForgeAvatarResponseMetadata(
            finalURL: accepted.finalURL.url,
            statusCode: 200,
            contentType: "image/webp",
            expectedByteCount: -1,
            maximumResponseBytes: 256
        )
        XCTAssertNil(unknownLength.expectedByteCount)

        XCTAssertThrowsError(try metadata(status: 302)) {
            XCTAssertEqual($0 as? ForgeAvatarPolicyError, .unsuccessfulResponse)
        }
        XCTAssertThrowsError(try metadata(url: "https://evil.example/u/1")) {
            XCTAssertEqual($0 as? ForgeAvatarPolicyError, .disallowedURL)
        }
        XCTAssertThrowsError(try metadata(contentType: "image/svg+xml")) {
            XCTAssertEqual($0 as? ForgeAvatarPolicyError, .unsupportedMediaType)
        }
        XCTAssertThrowsError(try metadata(expectedByteCount: 257)) {
            XCTAssertEqual($0 as? ForgeAvatarPolicyError, .responseTooLarge)
        }
        XCTAssertThrowsError(try ForgeAvatarResponseMetadata(
            finalURL: accepted.finalURL.url,
            statusCode: 200,
            contentType: "image/png",
            expectedByteCount: -1,
            maximumResponseBytes: -1
        )) {
            XCTAssertEqual($0 as? ForgeAvatarPolicyError, .responseTooLarge)
        }
    }

    func testByteAccumulatorRejectsInvalidLimitsOverflowAndChunkedExcess() throws {
        XCTAssertThrowsError(try ForgeAvatarByteAccumulator(maximumByteCount: -1))
        XCTAssertThrowsError(try ForgeAvatarByteAccumulator(maximumByteCount: 4, expectedByteCount: -1))
        XCTAssertThrowsError(try ForgeAvatarByteAccumulator(maximumByteCount: 4, expectedByteCount: 5))

        var accumulator = try ForgeAvatarByteAccumulator(maximumByteCount: 4, expectedByteCount: 3)
        try accumulator.append(Data([1, 2]))
        try accumulator.append(Data([3, 4]))
        XCTAssertEqual(accumulator.data, Data([1, 2, 3, 4]))
        XCTAssertThrowsError(try accumulator.append(Data([5]))) {
            XCTAssertEqual($0 as? ForgeAvatarPolicyError, .responseTooLarge)
        }

        var empty = try ForgeAvatarByteAccumulator(maximumByteCount: Int.max)
        XCTAssertNoThrow(try empty.append(Data()))
    }

    func testDecodedDimensionsRejectInvalidOverflowAndExcessivePixels() throws {
        let accepted = try ForgeAvatarDecodedDimensions(width: 20, height: 10, maximumPixels: 200)
        XCTAssertEqual(accepted.width, 20)
        XCTAssertEqual(accepted.height, 10)
        XCTAssertEqual(accepted.pixelCount, 200)
        for dimensions in [(0, 1, 1), (1, 0, 1), (1, 1, -1)] {
            XCTAssertThrowsError(try ForgeAvatarDecodedDimensions(
                width: dimensions.0,
                height: dimensions.1,
                maximumPixels: dimensions.2
            )) {
                XCTAssertEqual($0 as? ForgeAvatarPolicyError, .invalidDimensions)
            }
        }
        XCTAssertThrowsError(try ForgeAvatarDecodedDimensions(width: Int.max, height: 2)) {
            XCTAssertEqual($0 as? ForgeAvatarPolicyError, .decodedImageTooLarge)
        }
        XCTAssertThrowsError(try ForgeAvatarDecodedDimensions(width: 11, height: 10, maximumPixels: 100)) {
            XCTAssertEqual($0 as? ForgeAvatarPolicyError, .decodedImageTooLarge)
        }
    }

    func testErrorsAreStableAndContainNoURLOrPayload() {
        for error in [
            ForgeAvatarPolicyError.disallowedURL,
            .unsuccessfulResponse,
            .unsupportedMediaType,
            .responseTooLarge,
            .invalidDimensions,
            .decodedImageTooLarge,
            .mediaTypeMismatch,
        ] {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription?.contains("https://") ?? true)
        }
    }

    private func metadata(
        url: String = "https://avatars.githubusercontent.com/u/1",
        status: Int = 200,
        contentType: String = "image/png",
        expectedByteCount: Int64 = 1
    ) throws -> ForgeAvatarResponseMetadata {
        try ForgeAvatarResponseMetadata(
            finalURL: XCTUnwrap(URL(string: url)),
            statusCode: status,
            contentType: contentType,
            expectedByteCount: expectedByteCount,
            maximumResponseBytes: 256
        )
    }
}
