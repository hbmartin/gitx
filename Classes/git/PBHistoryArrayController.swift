import Cocoa

/// Keeps the mutable Working State row pinned above the arranged commit list.
@objc(PBHistoryArrayController)
final class PBHistoryArrayController: NSArrayController {
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
