import Foundation
import Testing

@testable import KppxKit

struct PluginManifestParserTests {

    @Test func parsesValidManifestData() throws {
        let parser = PluginManifestParser()
        let manifestData = Data(
            """
            {
              "name": "Test Plugin",
              "version": "1.0.0",
              "browser_specific_settings": {
                "kiririn": {
                  "id": "com.example.test",
                  "views": {
                    "overlay": {
                      "page": "overlay.html"
                    }
                  }
                }
              },
              "permissions": ["storage"]
            }
            """.utf8)

        let manifest = try parser.parse(
            manifestData: manifestData,
            resourceExists: { _ in true }
        )

        #expect(manifest.manifestID == "com.example.test")
        #expect(manifest.displayName == "Test Plugin")
        #expect(manifest.version == "1.0.0")
        #expect(manifest.overlayPage == "overlay.html")
        #expect(manifest.displayAreas == [.overlay])
    }

    @Test func rejectsManifestMissingRequiredFields() {
        let parser = PluginManifestParser()
        let manifestData = Data("{}".utf8)

        do {
            _ = try parser.parse(
                manifestData: manifestData,
                resourceExists: { _ in true }
            )
            #expect(Bool(false))
        } catch let error as PluginManifestValidationError {
            #expect(error.messages.contains { $0.contains("name") })
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func rejectsInvalidUpdateURL() {
        let parser = PluginManifestParser()
        let manifestData = Data(
            """
            {
              "name": "Test",
              "version": "1.0.0",
              "browser_specific_settings": {
                "kiririn": {
                  "id": "com.example.test",
                  "update_url": "ftp://invalid",
                  "views": {
                    "overlay": {
                      "page": "overlay.html"
                    }
                  }
                }
              }
            }
            """.utf8)

        do {
            _ = try parser.parse(
                manifestData: manifestData,
                resourceExists: { _ in true }
            )
            #expect(Bool(false))
        } catch let error as PluginManifestValidationError {
            #expect(error.messages.contains { $0.contains("http(s)") })
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func rejectsDirectoryTraversal() {
        let parser = PluginManifestParser()
        let manifestData = Data(
            """
            {
              "name": "Test",
              "version": "1.0.0",
              "browser_specific_settings": {
                "kiririn": {
                  "id": "com.example.test",
                  "views": {
                    "overlay": {
                      "page": "../etc/passwd"
                    }
                  }
                }
              }
            }
            """.utf8)

        do {
            _ = try parser.parse(
                manifestData: manifestData,
                resourceExists: { _ in true }
            )
            #expect(Bool(false))
        } catch let error as PluginManifestValidationError {
            #expect(error.messages.contains { $0.contains("相対パス") })
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func requiresAtLeastOneDisplayArea() {
        let parser = PluginManifestParser()
        let manifestData = Data(
            """
            {
              "name": "Test",
              "version": "1.0.0",
              "browser_specific_settings": {
                "kiririn": {
                  "id": "com.example.test"
                }
              }
            }
            """.utf8)

        do {
            _ = try parser.parse(
                manifestData: manifestData,
                resourceExists: { _ in true }
            )
            #expect(Bool(false))
        } catch let error as PluginManifestValidationError {
            #expect(error.messages.contains { $0.contains("オーバーレイ") })
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func parsesAllDisplayAreas() throws {
        let parser = PluginManifestParser()
        let manifestData = Data(
            """
            {
              "name": "Test",
              "version": "1.0.0",
              "browser_specific_settings": {
                "kiririn": {
                  "id": "com.example.test",
                  "views": {
                    "overlay": { "page": "overlay.html" },
                    "panel": { "page": "panel.html" },
                    "options": { "page": "options.html" }
                  }
                }
              },
              "options_ui": { "page": "options2.html" }
            }
            """.utf8)

        let manifest = try parser.parse(
            manifestData: manifestData,
            resourceExists: { _ in true }
        )

        #expect(manifest.displayAreas.contains(.overlay))
        #expect(manifest.displayAreas.contains(.panel))
        #expect(manifest.displayAreas.contains(.options))
    }

    @Test func trimmedNonEmptyReturnsNilForEmpty() {
        #expect(PluginManifestParser.trimmedNonEmpty("") == nil)
        #expect(PluginManifestParser.trimmedNonEmpty("   ") == nil)
        #expect(PluginManifestParser.trimmedNonEmpty(nil) == nil)
        #expect(PluginManifestParser.trimmedNonEmpty("hello") == "hello")
    }

    @Test func archiveFileNameSanitizes() {
        #expect(PluginManifestParser.archiveFileName(for: "com.example") == "com.example.kppx")
        #expect(PluginManifestParser.archiveFileName(for: "weird/id") == "weird_id.kppx")
    }
}
