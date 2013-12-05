#import "XTFileViewController.h"

#import <CoreServices/CoreServices.h>

#import "XTCommitHeaderViewController.h"
#import "XTFileChangesDataSource.h"
#import "XTFileDiffController.h"
#import "XTFileListDataSourceBase.h"
#import "XTFileListDataSource.h"
#import "XTPreviewItem.h"
#import "XTRepository.h"
#import "XTTextPreviewController.h"
#import <RBSplitView.h>

const CGFloat kChangeImagePadding = 8;
NSString* const XTContentTabIDDiff = @"diff";
NSString* const XTContentTabIDText = @"text";
NSString* const XTContentTabIDPreview = @"preview";

@interface NSSplitView (Animating)

- (void)animatePosition:(CGFloat)position ofDividerAtIndex:(NSInteger)index;

@end


@implementation XTFileViewController

+ (BOOL)fileNameIsText:(NSString*)name
{
  if (name == nil)
    return NO;

  NSArray *extensionlessNames = @[
      @"AUTHORS", @"CONTRIBUTING", @"COPYING", @"LICENSE", @"Makefile",
      @"README", ];

  for (NSString *extensionless in extensionlessNames)
    if ([name isCaseInsensitiveLike:extensionless])
      return YES;

  NSString *extension = [name pathExtension];
  const CFStringRef utType = UTTypeCreatePreferredIdentifierForTag(
      kUTTagClassFilenameExtension, (__bridge CFStringRef)extension, NULL);
  const Boolean result = UTTypeConformsTo(utType, kUTTypeText);
  
  CFRelease(utType);
  return result;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setRepo:(XTRepository *)newRepo
{
  _repo = newRepo;
  _fileChangeDS.repository = newRepo;
  _fileListDS.repository = newRepo;
  _headerController.repository = newRepo;
  ((XTPreviewItem*)_filePreview.previewItem).repo = newRepo;
}

- (void)awakeFromNib
{
  // -[NSOutlineView makeViewWithIdentifier:owner:] causes this to get called
  // again after the initial load.
  if ([[_splitView subviews] count] == 2)
    return;

  _changeImages = @{
      @( XitChangeAdded ) : [NSImage imageNamed:@"added"],
      @( XitChangeCopied ) : [NSImage imageNamed:@"copied"],
      @( XitChangeDeleted ) : [NSImage imageNamed:@"deleted"],
      @( XitChangeModified ) : [NSImage imageNamed:@"modified"],
      @( XitChangeRenamed ) : [NSImage imageNamed:@"renamed"],
      @( XitChangeMixed ) : [NSImage imageNamed:@"mixed"],
      };

  // For some reason the splitview comes with preexisting subviews.
  NSArray *subviews = [[_splitView subviews] copy];

  for (NSView *sub in subviews)
    [sub removeFromSuperview];
  [_splitView addSubview:_leftPane];
  [_splitView addSubview:_rightPane];
  [_splitView setDivider:[NSImage imageNamed:@"splitter"]];
  [_splitView setDividerThickness:1.0];

  [_fileListOutline sizeToFit];

  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(fileSelectionChanged:)
             name:NSOutlineViewSelectionDidChangeNotification
           object:_fileListOutline];
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(headerResized:)
             name:XTHeaderResizedNotificaiton
           object:_headerController];
}

- (IBAction)changeFileListView:(id)sender
{
  XTFileListDataSourceBase *newDS = _fileChangeDS;

  if (self.viewSelector.selectedSegment == 1)
    newDS = _fileListDS;
  if (newDS.isHierarchical)
    [_fileListOutline setOutlineTableColumn:
        [_fileListOutline tableColumnWithIdentifier:@"main"]];
  else
    [_fileListOutline setOutlineTableColumn:
        [_fileListOutline tableColumnWithIdentifier:@"hidden"]];
  [_fileListOutline setDelegate:nil];
  [_fileListOutline setDataSource:newDS];
  [_fileListOutline setDelegate:newDS];
  [_fileListOutline reloadData];
}

- (IBAction)changeContentView:(id)sender
{
  const NSInteger selection = [sender selectedSegment];
  NSString *tabIDs[] =
      { XTContentTabIDDiff, XTContentTabIDText, XTContentTabIDPreview };

  NSParameterAssert((selection >= 0) && (selection < 3));
  [self.previewTabView selectTabViewItemWithIdentifier:tabIDs[selection]];
  [self loadSelectedPreview];
}

- (void)clearPreviews
{
  // tell all controllers to clear their previews
  [self.diffController clear];
  [_textController clear];
  _filePreview.previewItem = nil;
}

- (void)loadSelectedPreview
{
  NSIndexSet *selection = [_fileListOutline selectedRowIndexes];
  XTFileListDataSourceBase *dataSource = (XTFileListDataSourceBase*)
      [_fileListOutline dataSource];
  XTFileChange *selectedItem = (XTFileChange*)
      [dataSource fileChangeAtRow:[selection firstIndex]];
  NSString *contentTabID =
      [[self.previewTabView selectedTabViewItem] identifier];

  if ([contentTabID isEqualToString:XTContentTabIDDiff]) {
    [self.diffController loadPath:selectedItem.path
                           commit:_repo.selectedCommit
                       repository:_repo];
  } else if ([contentTabID isEqualToString:XTContentTabIDText]) {
    [_textController loadPath:selectedItem.path
                       commit:_repo.selectedCommit
                   repository:_repo];
  } else if ([contentTabID isEqualToString:XTContentTabIDPreview]) {
    [_filePreview setHidden:NO];

    XTPreviewItem *previewItem = (XTPreviewItem *)_filePreview.previewItem;
    const NSUInteger selectionCount = [selection count];

    if (previewItem == nil) {
      previewItem = [[XTPreviewItem alloc] init];
      previewItem.repo = _repo;
      _filePreview.previewItem = previewItem;
    }

    previewItem.commitSHA = _repo.selectedCommit;
    if (selectionCount != 1) {
      [_filePreview setHidden:YES];
      previewItem.path = nil;
      return;
    }

    previewItem.path = selectedItem.path;
  }
}

- (void)commitSelected:(NSNotification *)note
{
  _headerController.commitSHA = [_repo selectedCommit];
  [self refresh];
}

- (void)fileSelectionChanged:(NSNotification *)note
{
  [self refresh];
}

- (void)headerResized:(NSNotification*)note
{
  const CGFloat newHeight = [[note userInfo][XTHeaderHeightKey] floatValue];

  [_headerSplitView animatePosition:newHeight ofDividerAtIndex:0];
}

- (void)refresh
{
  [self loadSelectedPreview];
  [_filePreview refreshPreviewItem];
}

#pragma mark - NSSplitViewDelegate

- (BOOL)splitView:(NSSplitView*)splitView
    shouldAdjustSizeOfSubview:(NSView*)subview
{
  if (subview == _headerController.view)
    return NO;
  return YES;
}

#pragma mark - RBSplitViewDelegate

const CGFloat kSplitterBonus = 4;

- (NSRect)splitView:(RBSplitView *)sender
         cursorRect:(NSRect)rect
         forDivider:(NSUInteger)divider
{
  if ([sender isVertical]) {
    rect.origin.x -= kSplitterBonus;
    rect.size.width += kSplitterBonus * 2;
  }
  return rect;
}

- (NSUInteger)splitView:(RBSplitView *)sender
        dividerForPoint:(NSPoint)point
              inSubview:(RBSplitSubview *)subview
{
  // Assume sender is the file list split view
  const NSRect subFrame = [subview frame];
  NSRect frame1, frame2, remainder;
  NSUInteger position = [subview position];
  NSRectEdge edge1 = [sender isVertical] ? NSMinXEdge : NSMinYEdge;
  NSRectEdge edge2 = [sender isVertical] ? NSMaxXEdge : NSMaxYEdge;

  NSDivideRect(subFrame, &frame1, &remainder, kSplitterBonus, edge1);
  NSDivideRect(subFrame, &frame2, &remainder, kSplitterBonus, edge2);

  if ([sender mouse:point inRect:frame1] && (position > 0))
    return position - 1;
  else if ([sender mouse:point inRect:frame2])
    return position;
  return NSNotFound;
}

@end

@implementation NSSplitView (Animating)

- (void)animatePosition:(CGFloat)position ofDividerAtIndex:(NSInteger)index
{
  NSView *targetView = [self subviews][index];
  NSRect endFrame = [targetView frame];

  if ([self isVertical])
      endFrame.size.width = position;
  else
      endFrame.size.height = position;

  NSDictionary *windowResize = @{
      NSViewAnimationTargetKey: targetView,
      NSViewAnimationEndFrameKey: [NSValue valueWithRect: endFrame],
      };
  NSViewAnimation *animation =
      [[NSViewAnimation alloc] initWithViewAnimations:@[ windowResize ]];

  [animation setAnimationBlockingMode:NSAnimationBlocking];
  [animation setDuration:0.2];
  [animation startAnimation];
}

@end
