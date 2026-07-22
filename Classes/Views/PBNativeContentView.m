#import "PBNativeContentView.h"
#import "GitX-Swift.h"

NSString *const PBNativeSectionTitleKey = @"title";
NSString *const PBNativeSectionTextKey = @"text";
NSString *const PBNativeSectionPathKey = @"path";
NSString *const PBNativeSectionContextKey = @"context";
NSString *const PBNativeSectionEntriesKey = @"entries";
NSString *const PBNativeSectionImageSourceKey = @"imageSource";
NSString *const PBNativeSectionDiffLayoutKey = @"diffLayout";
NSString *const PBNativeSectionSuppressionPatternsKey = @"suppressionPatterns";
NSString *const PBNativeImageSourceRevisionsKey = @"revisions";
NSString *const PBNativeImageSourceWorkingTreeKey = @"workingTree";
NSString *const PBNativeImageSourceWorkingTreeURLKey = @"workingTreeURL";
NSString *const PBNativeImageSourceGitLaunchPathKey = @"gitLaunchPath";
NSString *const PBNativeImageSourceGitDirectoryKey = @"gitDirectory";
NSString *const PBNativeImageSourceTaskDirectoryKey = @"taskDirectory";

@interface PBNativeContentView ()
@property (nonatomic) NSStackView *rootStack;
@property (nonatomic) NSScrollView *scrollView;
@property (nonatomic, readwrite) NSTextView *textView;
@property (nonatomic) NSView *accessoryView;
@property (nonatomic) NSMutableDictionary<NSString *, NSDictionary *> *linkPayloads;
@property (nonatomic) NSMutableSet<NSString *> *collapsedFiles;
@property (nonatomic) NSMutableSet<NSString *> *expandedImages;
@property (nonatomic) NSArray<NSDictionary *> *currentDiffSections;
@property (nonatomic) NSUInteger renderGeneration;
@property (nonatomic) PBDiffDocumentParser *diffParser;
@property (nonatomic) PBPartialPatchBuilder *partialPatchBuilder;
@property (nonatomic) PBNativeContentTypography *typography;
@property (nonatomic) PBNativeTextRenderer *textRenderer;
@property (nonatomic) PBNativeDiffRenderer *diffRenderer;
@property (nonatomic) NSMutableDictionary<NSString *, PBNativeRenderResult *> *cachedDiffResults;
@property (nonatomic) NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *cachedDiffSections;
@property (nonatomic) NSMutableDictionary<NSString *, NSValue *> *cachedDiffScrollOrigins;
@property (nonatomic, nullable) NSString *currentDiffCacheIdentifier;
@end

@implementation PBNativeContentView

- (instancetype)initWithFrame:(NSRect)frameRect
{
	self = [super initWithFrame:frameRect];
	if (!self) return nil;

	self.translatesAutoresizingMaskIntoConstraints = NO;
	_linkPayloads = [NSMutableDictionary dictionary];
	_collapsedFiles = [NSMutableSet set];
	_expandedImages = [NSMutableSet set];
	_cachedDiffResults = [NSMutableDictionary dictionary];
	_cachedDiffSections = [NSMutableDictionary dictionary];
	_cachedDiffScrollOrigins = [NSMutableDictionary dictionary];
	_diffParser = [[PBDiffDocumentParser alloc] init];
	_partialPatchBuilder = [[PBPartialPatchBuilder alloc] init];
	_typography = [PBNativeContentTypography currentTypography];
	[self configureRenderers];

	_rootStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
	_rootStack.translatesAutoresizingMaskIntoConstraints = NO;
	_rootStack.orientation = NSUserInterfaceLayoutOrientationVertical;
	_rootStack.alignment = NSLayoutAttributeLeading;
	_rootStack.spacing = 0;
	[self addSubview:_rootStack];

	_scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	_scrollView.translatesAutoresizingMaskIntoConstraints = NO;
	_scrollView.hasVerticalScroller = YES;
	_scrollView.hasHorizontalScroller = YES;
	_scrollView.autohidesScrollers = YES;
	_scrollView.borderType = NSNoBorder;
	_scrollView.drawsBackground = YES;
	_scrollView.backgroundColor = NSColor.textBackgroundColor;

	NSTextStorage *storage = [[NSTextStorage alloc] init];
	NSLayoutManager *layout = [[NSLayoutManager alloc] init];
	[storage addLayoutManager:layout];
	NSTextContainer *container = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
	container.widthTracksTextView = NO;
	container.heightTracksTextView = NO;
	[layout addTextContainer:container];
	_textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 1000) textContainer:container];
	_textView.minSize = NSMakeSize(0, 0);
	_textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
	_textView.verticallyResizable = YES;
	_textView.horizontallyResizable = YES;
	_textView.autoresizingMask = NSViewWidthSizable;
	_textView.textContainerInset = NSMakeSize(12, 12);
	_textView.editable = NO;
	_textView.selectable = YES;
	_textView.richText = YES;
	_textView.automaticLinkDetectionEnabled = NO;
	_textView.delegate = self;
	_textView.accessibilityIdentifier = @"NativeContentText";
	_textView.backgroundColor = NSColor.textBackgroundColor;
	_textView.textColor = NSColor.textColor;
	_scrollView.documentView = _textView;
	[_rootStack addArrangedSubview:_scrollView];

	[NSLayoutConstraint activateConstraints:@[
		[_rootStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[_rootStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		[_rootStack.topAnchor constraintEqualToAnchor:self.topAnchor],
		[_rootStack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
		[_scrollView.widthAnchor constraintEqualToAnchor:_rootStack.widthAnchor],
	]];
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(diffTextTypographyDidChange:)
												 name:PBApplicationSettings.diffTextTypographyDidChangeNotificationName
											   object:nil];

	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)configureRenderers
{
	self.textRenderer = [[PBNativeTextRenderer alloc] initWithBaseAttributes:self.typography.bodyAttributes
															 titleAttributes:self.typography.titleAttributes];
	self.diffRenderer = [[PBNativeDiffRenderer alloc] initWithBaseAttributes:self.typography.bodyAttributes
															 titleAttributes:self.typography.titleAttributes
																	  parser:self.diffParser];
}

- (void)setAccessoryView:(NSView *)accessoryView
{
	if (_accessoryView == accessoryView) return;
	if (_accessoryView) [_rootStack removeArrangedSubview:_accessoryView];
	[_accessoryView removeFromSuperview];
	_accessoryView = accessoryView;
	if (!accessoryView) return;
	accessoryView.translatesAutoresizingMaskIntoConstraints = NO;
	[_rootStack insertArrangedSubview:accessoryView atIndex:0];
	[accessoryView.widthAnchor constraintEqualToAnchor:_rootStack.widthAnchor].active = YES;
}

- (void)setRenderedString:(NSAttributedString *)string
			   generation:(NSUInteger)generation
			 linkPayloads:(nullable NSDictionary<NSString *, NSDictionary *> *)linkPayloads
			 scrollOrigin:(nullable NSValue *)scrollOrigin
{
	if (generation != self.renderGeneration) return;
	NSArray<NSValue *> *selectedRanges = scrollOrigin ? self.textView.selectedRanges : nil;
	self.linkPayloads = linkPayloads ? [linkPayloads mutableCopy] : [NSMutableDictionary dictionary];
	[self.textView.textStorage setAttributedString:string];
	if (selectedRanges)
		self.textView.selectedRanges = [self validSelectedRanges:selectedRanges
												  textLength:string.length];
	if (scrollOrigin) {
		[self.textView layoutSubtreeIfNeeded];
		[self.scrollView.contentView scrollToPoint:scrollOrigin.pointValue];
		[self.scrollView reflectScrolledClipView:self.scrollView.contentView];
	} else {
		[self.textView scrollRangeToVisible:NSMakeRange(0, 0)];
	}
}

- (NSArray<NSValue *> *)validSelectedRanges:(NSArray<NSValue *> *)ranges textLength:(NSUInteger)textLength
{
	NSMutableArray<NSValue *> *validRanges = [NSMutableArray arrayWithCapacity:ranges.count];
	for (NSValue *value in ranges) {
		NSRange range = value.rangeValue;
		range.location = MIN(range.location, textLength);
		range.length = MIN(range.length, textLength - range.location);
		[validRanges addObject:[NSValue valueWithRange:range]];
	}
	return validRanges;
}

- (nullable NSDictionary<NSString *, NSNumber *> *)currentViewportAnchor
{
	if (self.textView.textStorage.length == 0) return nil;
	NSLayoutManager *layoutManager = self.textView.layoutManager;
	NSTextContainer *textContainer = self.textView.textContainer;
	if (!layoutManager || !textContainer) return nil;
	[layoutManager ensureLayoutForTextContainer:textContainer];
	NSRect visibleRect = self.textView.visibleRect;
	NSPoint containerPoint = NSMakePoint(NSMinX(visibleRect) - self.textView.textContainerOrigin.x,
										 NSMinY(visibleRect) - self.textView.textContainerOrigin.y);
	CGFloat fraction = 0;
	NSUInteger glyphIndex = [layoutManager glyphIndexForPoint:containerPoint
											  inTextContainer:textContainer
							   fractionOfDistanceThroughGlyph:&fraction];
	if (glyphIndex >= layoutManager.numberOfGlyphs) return nil;
	NSUInteger characterIndex = [layoutManager characterIndexForGlyphAtIndex:glyphIndex];
	NSRect glyphRect = [layoutManager boundingRectForGlyphRange:NSMakeRange(glyphIndex, 1)
												inTextContainer:textContainer];
	CGFloat offset = NSMinY(visibleRect) - (NSMinY(glyphRect) + self.textView.textContainerOrigin.y);
	return @{
		@"characterIndex" : @(characterIndex),
		@"offset" : @(offset),
		@"x" : @(self.scrollView.contentView.bounds.origin.x),
	};
}

- (void)restoreViewportAnchor:(NSDictionary<NSString *, NSNumber *> *)anchor
{
	if (!anchor || self.textView.textStorage.length == 0) return;
	NSLayoutManager *layoutManager = self.textView.layoutManager;
	NSTextContainer *textContainer = self.textView.textContainer;
	if (!layoutManager || !textContainer) return;
	[layoutManager ensureLayoutForTextContainer:textContainer];
	NSUInteger characterIndex = MIN(anchor[@"characterIndex"].unsignedIntegerValue,
									self.textView.textStorage.length - 1);
	NSRange glyphRange = [layoutManager glyphRangeForCharacterRange:NSMakeRange(characterIndex, 1)
											   actualCharacterRange:NULL];
	if (glyphRange.length == 0) return;
	NSRect glyphRect = [layoutManager boundingRectForGlyphRange:glyphRange
												inTextContainer:textContainer];
	CGFloat targetY = NSMinY(glyphRect) + self.textView.textContainerOrigin.y + anchor[@"offset"].doubleValue;
	NSView *documentView = self.scrollView.documentView;
	CGFloat maximumY = MAX(0, NSHeight(documentView.frame) - NSHeight(self.scrollView.contentView.bounds));
	NSPoint target = NSMakePoint(anchor[@"x"].doubleValue, MIN(MAX(0, targetY), maximumY));
	[self.scrollView.contentView scrollToPoint:target];
	[self.scrollView reflectScrolledClipView:self.scrollView.contentView];
}

- (void)diffTextTypographyDidChange:(NSNotification *)notification
{
	if (!NSThread.isMainThread) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self diffTextTypographyDidChange:notification];
		});
		return;
	}
	NSArray<NSValue *> *selectedRanges = self.textView.selectedRanges;
	NSDictionary<NSString *, NSNumber *> *anchor = [self currentViewportAnchor];
	self.typography = [PBNativeContentTypography currentTypography];
	[self configureRenderers];
	[self.cachedDiffResults removeAllObjects];
	[self.cachedDiffSections removeAllObjects];
	NSAttributedString *restyledString = [self.typography restyledString:self.textView.attributedString];
	[self.textView.textStorage setAttributedString:restyledString];
	self.textView.selectedRanges = [self validSelectedRanges:selectedRanges textLength:restyledString.length];
	[self.textView layoutSubtreeIfNeeded];
	[self restoreViewportAnchor:anchor];
	NSLog(@"[GitX] Applied native content typography %@ at %.1f pt",
		  PBApplicationSettings.diffFontName,
		  PBApplicationSettings.diffFontSize);
}

- (void)saveCurrentDiffScrollPosition
{
	if (!self.currentDiffCacheIdentifier) return;
	self.cachedDiffScrollOrigins[self.currentDiffCacheIdentifier] =
		[NSValue valueWithPoint:self.scrollView.contentView.bounds.origin];
}

- (void)showMessage:(NSString *)message
{
	[self saveCurrentDiffScrollPosition];
	self.currentDiffCacheIdentifier = nil;
	self.renderGeneration++;
	NSMutableDictionary<NSAttributedStringKey, id> *attributes = self.typography.statusAttributes.mutableCopy;
	attributes[NSForegroundColorAttributeName] = NSColor.secondaryLabelColor;
	NSAttributedString *string = [[NSAttributedString alloc] initWithString:message ?: @""
																 attributes:attributes];
	[self setRenderedString:string generation:self.renderGeneration linkPayloads:nil scrollOrigin:nil];
}

- (void)showSourceSections:(NSArray<NSDictionary *> *)sections
{
	[self saveCurrentDiffScrollPosition];
	self.currentDiffCacheIdentifier = nil;
	NSUInteger generation = ++self.renderGeneration;
	NSArray<PBNativeContentSection *> *copiedSections = [PBNativeContentSection sectionsWithDictionaries:sections];
	PBNativeTextRenderer *renderer = self.textRenderer;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		PBNativeRenderResult *result = [renderer renderSourceSections:copiedSections];
		dispatch_async(dispatch_get_main_queue(), ^{
			[self setRenderedString:result.attributedString generation:generation linkPayloads:result.linkPayloads scrollOrigin:nil];
		});
	});
}

- (void)showBlameSections:(NSArray<NSDictionary *> *)sections
{
	[self saveCurrentDiffScrollPosition];
	self.currentDiffCacheIdentifier = nil;
	NSUInteger generation = ++self.renderGeneration;
	NSArray<PBNativeContentSection *> *copiedSections = [PBNativeContentSection sectionsWithDictionaries:sections];
	PBNativeTextRenderer *renderer = self.textRenderer;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		PBNativeRenderResult *result = [renderer renderBlameSections:copiedSections];
		dispatch_async(dispatch_get_main_queue(), ^{
			[self setRenderedString:result.attributedString generation:generation linkPayloads:result.linkPayloads scrollOrigin:nil];
		});
	});
}

- (void)showHistorySections:(NSArray<NSDictionary *> *)sections
{
	[self saveCurrentDiffScrollPosition];
	self.currentDiffCacheIdentifier = nil;
	NSUInteger generation = ++self.renderGeneration;
	NSArray<PBNativeContentSection *> *copiedSections = [PBNativeContentSection sectionsWithDictionaries:sections];
	PBNativeTextRenderer *renderer = self.textRenderer;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		PBNativeRenderResult *result = [renderer renderHistorySections:copiedSections];
		dispatch_async(dispatch_get_main_queue(), ^{
			[self setRenderedString:result.attributedString generation:generation linkPayloads:result.linkPayloads scrollOrigin:nil];
		});
	});
}

- (NSString *)pathForDiffHeaderAtIndex:(NSUInteger)headerIndex lines:(NSArray<NSString *> *)lines
{
	return [self.diffParser pathForDiffHeaderAtIndex:headerIndex lines:lines];
}

- (nullable NSString *)patchWithFileHeader:(NSArray<NSString *> *)fileHeader
								 hunkLines:(NSArray<NSString *> *)hunkLines
						   selectedIndexes:(NSIndexSet *)selectedIndexes
								   reverse:(BOOL)reverse
{
	return [self.partialPatchBuilder patchWithFileHeader:fileHeader hunkLines:hunkLines selectedIndexes:selectedIndexes reverse:reverse];
}

- (void)showDiffSections:(NSArray<NSDictionary *> *)sections
{
	[self showDiffSections:sections cacheIdentifier:nil preserveScrollPosition:NO];
}

- (void)showDiffSections:(NSArray<NSDictionary *> *)sections
		   cacheIdentifier:(nullable NSString *)cacheIdentifier
	preserveScrollPosition:(BOOL)preserveScrollPosition
{
	NSArray<NSDictionary *> *sourceSections = [sections copy];
	[self saveCurrentDiffScrollPosition];
	NSValue *savedScrollOrigin = cacheIdentifier ? self.cachedDiffScrollOrigins[cacheIdentifier] : nil;
	BOOL refreshingCurrentCache = cacheIdentifier && [cacheIdentifier isEqualToString:self.currentDiffCacheIdentifier];
	if (refreshingCurrentCache && preserveScrollPosition) {
		savedScrollOrigin = [NSValue valueWithPoint:self.scrollView.contentView.bounds.origin];
	}
	self.currentDiffCacheIdentifier = [cacheIdentifier copy];
	self.currentDiffSections = sourceSections;
	NSUInteger generation = ++self.renderGeneration;
	PBNativeRenderResult *cachedResult = cacheIdentifier ? self.cachedDiffResults[cacheIdentifier] : nil;
	NSArray<NSDictionary *> *cachedSections = cacheIdentifier ? self.cachedDiffSections[cacheIdentifier] : nil;
	if (cachedResult) {
		[self setRenderedString:cachedResult.attributedString
					 generation:generation
				   linkPayloads:cachedResult.linkPayloads
				   scrollOrigin:savedScrollOrigin];
		if ([cachedSections isEqualToArray:sourceSections]) return;
	}
	NSArray<PBNativeContentSection *> *copiedSections = [PBNativeContentSection sectionsWithDictionaries:sourceSections];
	NSSet<NSString *> *collapsedFiles = [self.collapsedFiles copy];
	NSSet<NSString *> *expandedImages = [self.expandedImages copy];
	id<PBNativeContentViewDelegate> delegate = self.delegate;
	PBNativeDiffRenderer *renderer = self.diffRenderer;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSData * (^imageDataProvider)(NSString *, NSInteger, NSDictionary<NSString *, id> *) =
			^NSData *(NSString *path, NSInteger sectionIndex, NSDictionary<NSString *, id> *imageSource) {
				if (![delegate respondsToSelector:@selector(nativeContentView:imageDataForPath:section:imageSource:)]) return nil;
				return [delegate nativeContentView:self imageDataForPath:path section:(NSUInteger)sectionIndex imageSource:imageSource];
			};
		PBNativeRenderResult *result = [renderer renderSections:copiedSections
												 collapsedFiles:collapsedFiles
												 expandedImages:expandedImages
											  imageDataProvider:imageDataProvider];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (generation != self.renderGeneration) return;
			if (cacheIdentifier) {
				self.cachedDiffResults[cacheIdentifier] = result;
				self.cachedDiffSections[cacheIdentifier] = sourceSections;
			}
			NSValue *replacementScrollOrigin = preserveScrollPosition ?
				[NSValue valueWithPoint:self.scrollView.contentView.bounds.origin] :
				savedScrollOrigin;
			[self setRenderedString:result.attributedString
						 generation:generation
					   linkPayloads:result.linkPayloads
					   scrollOrigin:replacementScrollOrigin];
		});
	});
}

- (void)rerenderCurrentDiffPreservingScrollPosition
{
	NSString *cacheIdentifier = self.currentDiffCacheIdentifier;
	if (cacheIdentifier) {
		[self.cachedDiffResults removeObjectForKey:cacheIdentifier];
		[self.cachedDiffSections removeObjectForKey:cacheIdentifier];
	}
	[self showDiffSections:self.currentDiffSections
			   cacheIdentifier:cacheIdentifier
		preserveScrollPosition:YES];
}

- (BOOL)textView:(NSTextView *)textView clickedOnLink:(id)link atIndex:(NSUInteger)charIndex
{
	NSString *key = [link isKindOfClass:NSURL.class] ? [link absoluteString] : [link description];
	NSDictionary *payload = self.linkPayloads[key];
	if (!payload) return NO;
	NSString *type = payload[@"type"];
	if ([type isEqualToString:@"diff"]) {
		NSString *patch = payload[@"patch"];
		if (!patch) {
			patch = [self patchWithFileHeader:payload[@"fileHeader"]
									hunkLines:payload[@"hunkLines"]
							  selectedIndexes:payload[@"selectedIndexes"]
									  reverse:[payload[@"reverse"] boolValue]];
		}
		if (patch && [self.delegate respondsToSelector:@selector(nativeContentView:performDiffAction:patch:)])
			[self.delegate nativeContentView:self performDiffAction:payload[@"action"] patch:patch];
	} else if ([type isEqualToString:@"commit"]) {
		if ([self.delegate respondsToSelector:@selector(nativeContentView:selectCommit:)])
			[self.delegate nativeContentView:self selectCommit:payload[@"sha"]];
	} else if ([type isEqualToString:@"collapse"]) {
		NSString *fileKey = payload[@"key"];
		if ([self.collapsedFiles containsObject:fileKey])
			[self.collapsedFiles removeObject:fileKey];
		else
			[self.collapsedFiles addObject:fileKey];
		[self rerenderCurrentDiffPreservingScrollPosition];
	} else if ([type isEqualToString:@"reveal-suppressed"]) {
		[self.expandedImages addObject:[@"suppression:" stringByAppendingString:payload[@"key"]]];
		[self rerenderCurrentDiffPreservingScrollPosition];
	} else if ([type isEqualToString:@"image"]) {
		[self.expandedImages addObject:payload[@"key"]];
		[self rerenderCurrentDiffPreservingScrollPosition];
	}
	return YES;
}

- (void)scrollPageUp
{
	[self.textView scrollPageUp:self];
}

- (void)scrollPageDown
{
	[self.textView scrollPageDown:self];
}

@end
