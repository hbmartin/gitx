// NSArrayController is resolved through the Objective-C runtime when the nib loads.
import Cocoa // swiftlint:disable:this unused_import

/// Keeps the mutable Working State row pinned above the arranged commit list.
@objc(PBHistoryArrayController)
final nonisolated class PBHistoryArrayController: NSArrayController { // swiftlint:disable:this unused_declaration
    private var storedPinnedObject: Any?

    @objc dynamic var pinnedObject: Any? {
        get { storedPinnedObject }
        set {
            let currentObject = storedPinnedObject as AnyObject?
            let newObject = newValue as AnyObject?
            guard currentObject !== newObject else { return }
            storedPinnedObject = newValue
            rearrangeObjects()
        }
    }

    override func arrange(_ objects: [Any]) -> [Any] {
        let arranged = super.arrange(objects)
        guard let pinnedObject else { return arranged }
        var result: [Any] = [pinnedObject]
        result.append(contentsOf: arranged)
        return result
    }

    override var sortDescriptors: [NSSortDescriptor] {
        get { super.sortDescriptors }
        set {
            super.sortDescriptors = PBGitDefaults.historyColumnSortingEnabled() ? newValue : []
        }
    }
}
