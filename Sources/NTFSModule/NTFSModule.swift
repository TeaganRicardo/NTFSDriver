// SPDX-License-Identifier: GPL-3.0-or-later
import FSKit
import NTFSFSKit

@main
struct NTFSModule: UnaryFileSystemExtension {
    let fileSystem = NTFSFileSystem()
}
