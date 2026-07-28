import ModelIO
import Foundation

let src = URL(fileURLWithPath: CommandLine.arguments[1])
let dst = URL(fileURLWithPath: CommandLine.arguments[2])
let asset = MDLAsset(url: src)
asset.loadTextures()
print("meshes:", asset.count)
do {
    try asset.export(to: dst)
    print("exported to", dst.path)
} catch {
    print("export failed:", error)
    exit(1)
}
