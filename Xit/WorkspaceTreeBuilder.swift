import Cocoa

class WorkspaceTreeBuilder
{
  var changes: [String: DeltaStatus]
  
  init(changes: [String: DeltaStatus])
  {
    self.changes = changes
  }
  
  init(fileChanges: [FileChange])
  {
    var changes = [String: DeltaStatus]()
    
    for change in fileChanges {
      changes[change.path] = change.change
    }
    self.changes = changes
  }
  
  func treeAtURL(_ baseURL: URL, rootPath: NSString) -> NSTreeNode
  {
    let rootItem = CommitTreeItem(path: "/")
    let node = NSTreeNode(representedObject: rootItem)
    let enumerator = FileManager.default.enumerator(
          at: baseURL,
          includingPropertiesForKeys: [ URLResourceKey.isDirectoryKey ],
          options: .skipsSubdirectoryDescendants,
          errorHandler: nil)
    let rootPathLength = rootPath.length + 1
    
    while let url: URL = enumerator?.nextObject() as! URL? {
      let urlPath = url.path
      let path = (urlPath as NSString).substring(from: rootPathLength)
      
      if path == ".git" {
        continue
      }
      
      var childNode: NSTreeNode?
      var isDirectory: AnyObject?
      
      do {
        try (url as NSURL).getResourceValue(&isDirectory,
                                            forKey: URLResourceKey.isDirectoryKey)
      }
      catch {
        continue
      }
      if let isDirValue = isDirectory as? NSNumber {
        if isDirValue.boolValue {
          childNode = self.treeAtURL(url, rootPath: rootPath)
        }
        else {
          let item = CommitTreeItem(path: path)
          
          if let status = self.changes[path] {
            item.change = status
          }
          childNode = NSTreeNode(representedObject: item)
        }
      }
      childNode.map { node.mutableChildren.add($0) }
    }
    return node
  }
  
  func build(_ baseURL: URL) -> NSTreeNode
  {
    return self.treeAtURL(baseURL, rootPath: baseURL.path as NSString)
  }
}
