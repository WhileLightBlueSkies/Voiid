//
//  FXAssetStore.swift
//  Voiid
//
//  Loads .voiidfx packs and turns them into GPU-ready filters.
//
//  A pack is a STORED (uncompressed) zip of:
//      manifest.json   the filter definition
//      atlas.webp      the art, premultiplied alpha
//      <lut>.png       optional colour grade
//
//  Bundled filters are decoded and uploaded at init, before the user can reach
//  the filter rail. That is what makes selection instant: by the time a tap is
//  possible, the texture is already resident.
//

import Foundation
import Metal
import MetalKit
import UIKit

/// A filter that is resident on the GPU and ready to draw this frame.
struct LoadedFilter {
    let manifest: FXManifest
    let atlas: MTLTexture?
    let lut: MTLTexture?
}

final class FXAssetStore {

    private let device: MTLDevice
    private let loader: MTKTextureLoader
    private var loaded: [String: LoadedFilter] = [:]
    private let lock = NSLock()

    /// Only these three names may appear in a pack. Anything else is either a
    /// mistake or an attempt to write somewhere it should not.
    private static let allowedEntries: Set<String> = ["manifest.json", "atlas.webp"]
    private static let maxEntryBytes = 4 * 1024 * 1024

    init(device: MTLDevice) {
        self.device = device
        self.loader = MTKTextureLoader(device: device)
    }

    /// Every filter that is ready to use right now.
    var availableIds: [String] {
        lock.lock(); defer { lock.unlock() }
        return loaded.keys.sorted()
    }

    func filter(_ id: String) -> LoadedFilter? {
        lock.lock(); defer { lock.unlock() }
        return loaded[id]
    }

    /// Decodes and uploads every pack bundled with the app.
    ///
    /// Synchronous by design and called before the camera is presented: a
    /// filter rail that populates asynchronously produces tiles that cannot be
    /// tapped yet, which reads as the app being broken rather than busy.
    @discardableResult
    func loadBundled() -> [String] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "voiidfx", subdirectory: nil) ?? []
        var ok: [String] = []
        for url in urls {
            let id = url.deletingPathExtension().lastPathComponent
            do {
                let f = try load(packAt: url, id: id)
                lock.lock(); loaded[id] = f; lock.unlock()
                ok.append(id)
            } catch {
                // One bad pack must not take the rail down with it.
                NSLog("[FaceFX] skipping bundled filter '\(id)': \(error)")
            }
        }
        return ok.sorted()
    }

    /// Reads a pack, validates it, and uploads its textures.
    func load(packAt url: URL, id: String, expectedSHA256: String? = nil) throws -> LoadedFilter {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw FXAssetError.packUnreadable(id)
        }
        if let expected = expectedSHA256 {
            guard FXIntegrity.sha256Hex(data) == expected.lowercased() else {
                throw FXAssetError.integrityMismatch(id)
            }
        }

        let entries = try FXZip.entries(in: data)
        for name in entries.keys {
            // Path traversal guard: a pack may only contain the names we expect,
            // and never a path that could escape the cache directory.
            guard !name.contains(".."), !name.hasPrefix("/") else {
                throw FXAssetError.unsafeEntry(name)
            }
            guard Self.allowedEntries.contains(name) || name.hasSuffix(".png") else {
                throw FXAssetError.unsafeEntry(name)
            }
        }
        for (name, bytes) in entries where bytes.count > Self.maxEntryBytes {
            throw FXAssetError.tooLarge("\(id)/\(name)")
        }

        guard let manifestData = entries["manifest.json"] else {
            throw FXAssetError.manifestMissing(id)
        }
        let manifest = try FXManifest.decode(manifestData)

        var atlas: MTLTexture?
        if let atlasData = entries["atlas.webp"] {
            guard let image = UIImage(data: atlasData)?.cgImage else {
                throw FXAssetError.atlasDecodeFailed(id)
            }
            atlas = try loader.newTexture(cgImage: image, options: [
                .SRGB: false,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            ])
        }

        var lut: MTLTexture?
        if let lutName = manifest.colour?.lut, let lutData = entries[lutName],
           let image = UIImage(data: lutData)?.cgImage {
            lut = try loader.newTexture(cgImage: image, options: [
                .SRGB: false,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            ])
        }

        return LoadedFilter(manifest: manifest, atlas: atlas, lut: lut)
    }

    func insert(_ filter: LoadedFilter, for id: String) {
        lock.lock(); loaded[id] = filter; lock.unlock()
    }
}
