import XCTest
@testable import FileSwitch

final class HardeningTests: XCTestCase {
    private var vectors: [String: Any] {
        get throws {
            // shared with the Go and Dart tests
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../client/test/e2e_vectors.json").standardizedFileURL
            return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        }
    }

    func testNamesCannotLeaveTheDownloadFolder() {
        XCTAssertEqual(Transfers.safeName(".."), "_")
        XCTAssertEqual(Transfers.safeName("."), "_")
        XCTAssertEqual(Transfers.safeName("../x"), ".._x")
        let root = URL(fileURLWithPath: "/tmp/dl/项目")
        let u = "项目/../../.ssh/authorized_keys".split(separator: "/").dropFirst()
            .reduce(root) { $0.appendingPathComponent(Transfers.safeName(String($1))) }
        XCTAssertTrue(u.standardizedFileURL.path.hasPrefix(root.path + "/"), u.standardizedFileURL.path)
    }

    func testPlainHTTPIsRefused() async {
        do {
            _ = try await DirectBackend.probe("http://127.0.0.1:1")
            XCTFail("http:// was accepted")
        } catch let e as FSError {
            XCTAssertEqual(e.code, "input")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testSnapshotFromGoStillOpens() throws {
        let v = try vectors
        let sk = Data(hex: v["space_key"] as! String)!
        let (version, json) = try E2E.openSnapshot(Data(base64Encoded: v["snapshot"] as! String)!,
                                                   spaceID: v["space"] as! String, ring: [5: sk])
        XCTAssertEqual(version, 77)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: json) as? [String: Any])?["hello"] as? String, "世界")
    }

    func testDecompressionBombIsRefused() throws {
        // 64 MiB of zeros, gzip-compressed by the system tool
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("z")
        try Data(count: 64 << 20).write(to: raw)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-n", raw.path]
        try p.run()
        p.waitUntilExit()
        let gz = try Data(contentsOf: raw.appendingPathExtension("gz"))
        XCTAssertLessThan(gz.count, 1 << 20)
        XCTAssertEqual(try E2E.gunzip(gz).count, 64 << 20)
        XCTAssertThrowsError(try E2E.gunzip(gz, limit: 1 << 20))
    }

    // The pin has to be checked even when the system would trust the certificate.
    func testPinAppliesToCATrustedCertificates() async throws {
        let site = URL(string: "https://www.apple.com")!
        let open = HTTP(base: site, fingerprint: nil)
        defer { open.invalidate() }
        guard (try? await open.raw(open.request("GET", "/"))) != nil else { throw XCTSkip("no network") }

        let pinned = HTTP(base: site, fingerprint: String(repeating: "00:", count: 31) + "00")
        defer { pinned.invalidate() }
        do {
            _ = try await pinned.raw(pinned.request("GET", "/"))
            XCTFail("connected although the certificate doesn't match the pin")
        } catch {}
    }
}
