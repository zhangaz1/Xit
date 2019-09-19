import Cocoa

/// Data source for the sidebar, showing branches, remotes, tags, stashes,
/// and submodules.
class SideBarDataSource: NSObject
{
  enum Intervals
  {
    static let reloadDelay: TimeInterval = 1
  }
  
  private struct ExpansionCache
  {
    let localBranches, remoteBranches, tags: [String]
  }
  
  @IBOutlet weak var viewController: SidebarController!
  @IBOutlet weak var outline: NSOutlineView!
  
  weak var model: SidebarDataModel! = nil
  {
    didSet
    {
      guard let repo = model.repository
      else { return }
      
      stagingItem.selection = StagingSelection(repository: repo)
      
      observers.addObserver(forName: .XTRepositoryRefsChanged,
                            object: repo, queue: .main) {
        [weak self] (_) in
        self?.reload()
      }
      observers.addObserver(forName: .XTRepositoryStashChanged,
                            object: repo, queue: .main) {
        [weak self] (_) in
        self?.stashChanged()
      }
      observers.addObserver(forName: .XTRepositoryHeadChanged,
                            object: repo, queue: .main) {
        [weak self] (_) in
        guard let self = self
        else { return }
        self.outline.reloadItem(self.model.filteredItem(.branches),
                                reloadChildren: true)
      }
      observers.addObserver(forName: .XTRepositoryConfigChanged,
                            object: repo, queue: .main) {
        [weak self] (_) in
        self?.reload()
      }
      reload()
    }
  }
  var lastItemList: [SideBarGroupItem] = []
  var stagingItem: SidebarItem { return model.stagingItem }
  
  var reloadTimer: Timer?
  
  let observers = ObserverCollection()
  
  var repository: SidebarDataModel.Repository!
  { return model?.repository }
  
  deinit
  {
    stopTimers()
  }
  
  func setAmending(_ amending: Bool)
  {
    stagingItem.selection = amending ? AmendingSelection(repository: repository)
                                     : StagingSelection(repository: repository)
    outline.reloadItem(stagingItem)
  }
  
  private func expandedChildNames(of item: SidebarItem) -> [String]
  {
    var result: [String] = []
    
    for childItem in item.children {
      if outline.isItemExpanded(childItem) {
        result.append(path(for: childItem))
        result.append(contentsOf: expandedChildNames(of: childItem))
      }
    }
    return result
  }
  
  private func getExpansions() -> ExpansionCache
  {
    let localItem = model.filteredItem(.branches)
    let remotesItem = model.filteredItem(.remotes)
    let tagsItem = model.filteredItem(.tags)

    return ExpansionCache(localBranches: expandedChildNames(of: localItem),
                          remoteBranches: expandedChildNames(of: remotesItem),
                          tags: expandedChildNames(of: tagsItem))
  }
  
  func reload()
  {
    let expanded = getExpansions()
    
    repository?.queue.executeOffMainThread {
      [weak self] in
      guard let newRoots = Signpost.interval(.sidebarReload,
                                             call: { self?.model.loadRoots() })
      else { return }

      DispatchQueue.main.async {
        self?.afterReload(newRoots, expanded: expanded)
      }
    }
  }
  
  private func afterReload(_ newRoots: [SideBarGroupItem],
                           expanded: ExpansionCache)
  {
    if lastItemList.isEmpty {
      lastItemList = newRoots
      model.roots = newRoots
      outline.reloadData()
      for rootItem in model.roots {
        outline.expandItem(rootItem)
      }
      for remoteItem in model.rootItem(.remotes).children {
        outline.expandItem(remoteItem)
      }
      if let currentBranch = repository.currentBranch,
        currentBranch.contains("/") {
        showItem(branchName: currentBranch)
      }
    }
    else {
      applyChanges(newRoots: newRoots)
    }
    
    let selection = outline.item(atRow: outline.selectedRow)
                    as? SidebarItem
    
    if outline.numberOfSelectedRows == 0  &&
       !(selection.map({ select(item: $0) }) ?? false) {
      selectCurrentBranch()
    }
  }
  
  private func applyChanges(newRoots: [SideBarGroupItem])
  {
    let filteredRoots = model.filter(roots: newRoots)
    
    outline.beginUpdates()
    model.roots = newRoots
    // Skip the first items because Workspace won't change
    for (oldGroup, newGroup) in zip(lastItemList.dropFirst(),
                                    filteredRoots.dropFirst()) {
      applyNewContents(oldRoot: oldGroup, newRoot: newGroup)
    }
    outline.endUpdates()
    lastItemList = filteredRoots
  }
  
  private func applyNewContents(oldRoot: SidebarItem, newRoot: SidebarItem)
  {
    let oldItems = oldRoot.children
    let newItems = newRoot.children
    let removedIndices = oldItems.indices { !newItems.containsEqualObject($0) }
    let addedIndices = newItems.indices { !oldItems.containsEqualObject($0) }
    
    outline.removeItems(at: removedIndices, inParent: oldRoot,
                        withAnimation: .effectFade)
    outline.insertItems(at: addedIndices, inParent: oldRoot,
                        withAnimation: .effectFade)
    for oldItem in oldItems where oldItem.expandable &&
                                  outline.isItemExpanded(oldItem) {
      if let newItem = newItems.first(where: { $0 == oldItem }) {
        applyNewContents(oldRoot: oldItem, newRoot: newItem)
      }
    }
  }
  
  private func restoreExpandedItems(_ expanded: ExpansionCache)
  {
    let localItem = model.filteredItem(.branches)
    let remotesItem = model.filteredItem(.remotes)
    let tagsItem = model.filteredItem(.tags)

    for localBranch in expanded.localBranches {
      if let branchItem = localItem.child(atPath: localBranch) {
        outline.expandItem(branchItem)
      }
    }
    for remoteBranch in expanded.remoteBranches {
      if let remoteItem = remotesItem.child(atPath: remoteBranch) {
        outline.expandItem(remoteItem)
      }
    }
    for tag in expanded.tags {
      if let tagItem = tagsItem.child(atPath: tag) {
        outline.expandItem(tagItem)
      }
    }
  }
  
  func showItem(branchName: String)
  {
    let parts = branchName.components(separatedBy: "/")
    var parent: SidebarItem = model.filteredItem(.branches)
    
    for part in parts {
      guard let child = parent.child(matching: part)
        else { break }
      
      outline.expandItem(child)
      parent = child
    }
  }
  
  func select(item: SidebarItem?) -> Bool
  {
    guard let item = item
    else { return false }
    let rowIndex = outline.row(forItem: item)
    
    if rowIndex != -1 {
      outline.selectRowIndexes(IndexSet(integer: rowIndex),
                               byExtendingSelection: false)
      return true
    }
    switch item {
      case is StagingSidebarItem:
        outline.selectRowIndexes(
            IndexSet(integer: outline.row(forItem: self.stagingItem)),
            byExtendingSelection: false)
        return true
      case let localItem as LocalBranchSidebarItem:
        if let item = model.item(forBranchName: localItem.title) {
          outline.selectRowIndexes(
              IndexSet(integer: outline.row(forItem: item)),
              byExtendingSelection: false)
          return true
        }
        return false
      default:
        return false
    }
  }
  
  func stashChanged()
  {
    let stashesGroup = model.filteredItem(.stashes)

    stashesGroup.children = model.makeStashItems()
    outline.reloadItem(stashesGroup, reloadChildren: true)
    if outline.selectedRow == -1 {
      let stagingRow = outline.row(forItem: stagingItem)
      
      outline.selectRowIndexes(IndexSet(integer: stagingRow),
                               byExtendingSelection: false)
    }
  }
  
  func path(for item: SidebarItem) -> String
  {
    let title = item.displayTitle.rawValue
    
    if let parent = outline.parent(forItem: item) as? SidebarItem,
       !(parent is SideBarGroupItem) {
      return path(for: parent).appending(pathComponent: title)
    }
    else {
      return title
    }
  }
  
  func selectCurrentBranch()
  {
    _ = selectCurrentBranch(in: model.filteredItem(.branches))
  }
  
  private func selectCurrentBranch(in parent: SidebarItem) -> Bool
  {
    for item in parent.children {
      if item.current {
        viewController?.selectedItem = item
        return true
      }
      if selectCurrentBranch(in: item) {
        return true
      }
    }
    return false
  }
  
  func stopTimers()
  {
    reloadTimer?.invalidate()
  }
  
  func scheduleReload()
  {
    if let timer = reloadTimer, timer.isValid {
      timer.fireDate = Date(timeIntervalSinceNow: Intervals.reloadDelay)
    }
    else {
      reloadTimer = Timer.scheduledTimer(withTimeInterval: Intervals.reloadDelay,
                                         repeats: false) {
        [weak self] _ in
        DispatchQueue.main.async {
          guard let self = self,
                let outline = self.outline
          else { return }
          let savedSelection = self.viewController.selectedItem
          
          outline.reloadData()
          if savedSelection != nil {
            self.viewController.selectedItem = savedSelection
          }
        }
        self?.reloadTimer = nil
      }
    }
  }
}

extension SideBarDataSource: NSOutlineViewDataSource
{
  public func outlineView(_ outlineView: NSOutlineView,
                          numberOfChildrenOfItem item: Any?) -> Int
  {
    switch item {
      case nil:
        return model?.filteredRoots.count ?? 0
      case let sidebarItem as SidebarItem:
        return sidebarItem.children.count
      default:
        return 0
    }
  }
  
  public func outlineView(_ outlineView: NSOutlineView,
                          isItemExpandable item: Any) -> Bool
  {
    return (item as? SidebarItem)?.expandable ?? false
  }
  
  public func outlineView(_ outlineView: NSOutlineView,
                          child index: Int,
                          ofItem item: Any?) -> Any
  {
    if item == nil {
      return model.filteredRoots[index]
    }
    
    guard let sidebarItem = item as? SidebarItem,
          sidebarItem.children.count > index
    else { return SidebarItem(title: "") }
    
    return sidebarItem.children[index]
  }
}
