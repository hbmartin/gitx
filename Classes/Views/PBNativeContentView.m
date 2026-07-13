#import "PBNativeContentView.h"
#import "PBHighlighting.h"

NSString *const PBNativeSectionTitleKey = @"title";
NSString *const PBNativeSectionTextKey = @"text";
NSString *const PBNativeSectionPathKey = @"path";
NSString *const PBNativeSectionContextKey = @"context";
NSString *const PBNativeSectionEntriesKey = @"entries";

static const NSUInteger PBNativeLargePatchThreshold = 200 * 1024;

@interface PBNativeContentView ()
@property (nonatomic) NSStackView *rootStack;
@property (nonatomic) NSScrollView *scrollView;
@property (nonatomic, readwrite) NSTextView *textView;
@property (nonatomic) NSView *accessoryView;
@property (nonatomic) NSMutableDictionary<NSString *, NSDictionary *> *linkPayloads;
@property (nonatomic) NSMutableSet<NSString *> *collapsedFiles;
@property (nonatomic) NSMutableSet<NSString *> *approvedLargeSections;
@property (nonatomic) NSMutableSet<NSString *> *expandedImages;
@property (nonatomic) NSArray<NSDictionary *> *currentDiffSections;
@property (nonatomic) NSUInteger renderGeneration;
@end

@implementation PBNativeContentView

- (instancetype)initWithFrame:(NSRect)frameRect
{
	self = [super initWithFrame:frameRect];
	if (!self) return nil;

	self.translatesAutoresizingMaskIntoConstraints = NO;
	_linkPayloads = [NSMutableDictionary dictionary];
	_collapsedFiles = [NSMutableSet set];
	_approvedLargeSections = [NSMutableSet set];
	_expandedImages = [NSMutableSet set];

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

	return self;
}

- (NSDictionary *)baseAttributes
{
	return @{ NSFontAttributeName : [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular],
			  NSForegroundColorAttributeName : NSColor.textColor };
}

- (NSDictionary *)titleAttributes
{
	return @{ NSFontAttributeName : [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
			  NSForegroundColorAttributeName : NSColor.labelColor };
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

- (void)setRenderedString:(NSAttributedString *)string generation:(NSUInteger)generation
{
	if (generation != self.renderGeneration) return;
	[self.textView.textStorage setAttributedString:string];
	[self.textView scrollRangeToVisible:NSMakeRange(0, 0)];
}

- (void)showMessage:(NSString *)message
{
	self.renderGeneration++;
	[self.linkPayloads removeAllObjects];
	NSAttributedString *string = [[NSAttributedString alloc] initWithString:message ?: @"" attributes:@{
		NSFontAttributeName : [NSFont systemFontOfSize:13],
		NSForegroundColorAttributeName : NSColor.secondaryLabelColor,
	}];
	[self setRenderedString:string generation:self.renderGeneration];
}

- (void)appendSectionTitle:(NSString *)title toString:(NSMutableAttributedString *)result
{
	if (title.length == 0) return;
	if (result.length) [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n\n"]];
	[result appendAttributedString:[[NSAttributedString alloc] initWithString:[title stringByAppendingString:@"\n"] attributes:self.titleAttributes]];
}

- (void)showSourceSections:(NSArray<NSDictionary *> *)sections
{
	NSUInteger generation = ++self.renderGeneration;
	[self.linkPayloads removeAllObjects];
	NSArray *copiedSections = [sections copy];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableAttributedString *rendered = [[NSMutableAttributedString alloc] init];
		for (NSDictionary *section in copiedSections) {
			NSString *title = section[PBNativeSectionTitleKey] ?: section[PBNativeSectionPathKey] ?: @"";
			NSString *path = section[PBNativeSectionPathKey] ?: title;
			NSString *text = section[PBNativeSectionTextKey] ?: @"";
			[self appendSectionTitle:title toString:rendered];
			[rendered appendAttributedString:[PBHighlighting highlightedStringForText:text path:path]];
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			[self setRenderedString:rendered generation:generation];
		});
	});
}

- (NSArray<NSDictionary *> *)blameLinesFromPorcelain:(NSString *)porcelain
{
	NSArray<NSString *> *lines = [porcelain componentsSeparatedByString:@"\n"];
	NSMutableDictionary<NSString *, NSDictionary *> *metadata = [NSMutableDictionary dictionary];
	NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
	NSString *sha = @"";
	NSString *author = @"";
	NSString *summary = @"";
	for (NSString *line in lines) {
		NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
		if (parts.count >= 3 && [parts.firstObject length] == 40) {
			sha = parts.firstObject;
			NSDictionary *cached = metadata[sha];
			if (cached) {
				author = cached[@"author"] ?: @"";
				summary = cached[@"summary"] ?: @"";
			}
		} else if ([line hasPrefix:@"author "]) {
			author = [line substringFromIndex:7];
		} else if ([line hasPrefix:@"summary "]) {
			summary = [line substringFromIndex:8];
			if (sha.length) metadata[sha] = @{ @"author" : author ?: @"", @"summary" : summary ?: @"" };
		} else if ([line hasPrefix:@"\t"]) {
			[result addObject:@{ @"sha" : sha ?: @"", @"author" : author ?: @"", @"summary" : summary ?: @"", @"code" : [line substringFromIndex:1] }];
		}
	}
	return result;
}

- (void)showBlameSections:(NSArray<NSDictionary *> *)sections
{
	NSUInteger generation = ++self.renderGeneration;
	[self.linkPayloads removeAllObjects];
	NSArray *copiedSections = [sections copy];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableAttributedString *rendered = [[NSMutableAttributedString alloc] init];
		for (NSDictionary *section in copiedSections) {
			NSString *title = section[PBNativeSectionTitleKey] ?: section[PBNativeSectionPathKey] ?: @"";
			NSString *path = section[PBNativeSectionPathKey] ?: title;
			NSArray<NSDictionary *> *records = [self blameLinesFromPorcelain:section[PBNativeSectionTextKey] ?: @""];
			NSMutableString *code = [NSMutableString string];
			for (NSDictionary *record in records) [code appendFormat:@"%@\n", record[@"code"] ?: @""];
			NSAttributedString *highlighted = [PBHighlighting highlightedStringForText:code path:path];
			[self appendSectionTitle:title toString:rendered];
			NSUInteger codeLocation = 0;
			for (NSDictionary *record in records) {
				NSString *line = [NSString stringWithFormat:@"%@\n", record[@"code"] ?: @""];
				NSString *fullSHA = record[@"sha"] ?: @"";
				NSString *shortSHA = fullSHA.length >= 8 ? [fullSHA substringToIndex:8] : fullSHA;
				NSString *author = record[@"author"] ?: @"";
				if (author.length > 18) author = [[author substringToIndex:17] stringByAppendingString:@"…"];
				NSString *gutter = [NSString stringWithFormat:@"%-8@  %-18@ │ ", shortSHA, author];
				[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:gutter attributes:@{
					NSFontAttributeName : [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
					NSForegroundColorAttributeName : NSColor.secondaryLabelColor,
					NSBackgroundColorAttributeName : NSColor.controlBackgroundColor,
				}]];
				if (codeLocation + line.length <= highlighted.length) {
					[rendered appendAttributedString:[highlighted attributedSubstringFromRange:NSMakeRange(codeLocation, line.length)]];
				} else {
					[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:self.baseAttributes]];
				}
				codeLocation += line.length;
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			[self setRenderedString:rendered generation:generation];
		});
	});
}

- (NSURL *)appendLinkWithTitle:(NSString *)title payload:(NSDictionary *)payload toString:(NSMutableAttributedString *)result
{
	NSString *token = NSUUID.UUID.UUIDString;
	NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:@"gitx-action://%@", token]];
	self.linkPayloads[URL.absoluteString] = payload;
	NSMutableAttributedString *link = [[NSMutableAttributedString alloc] initWithString:title attributes:@{
		NSFontAttributeName : [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
		NSLinkAttributeName : URL,
		NSForegroundColorAttributeName : NSColor.linkColor,
		NSUnderlineStyleAttributeName : @(NSUnderlineStyleSingle),
	}];
	[result appendAttributedString:link];
	return URL;
}

- (void)showHistorySections:(NSArray<NSDictionary *> *)sections
{
	self.renderGeneration++;
	[self.linkPayloads removeAllObjects];
	NSMutableAttributedString *rendered = [[NSMutableAttributedString alloc] init];
	for (NSDictionary *section in sections) {
		[self appendSectionTitle:section[PBNativeSectionTitleKey] ?: section[PBNativeSectionPathKey] ?: @"" toString:rendered];
		for (NSDictionary *entry in section[PBNativeSectionEntriesKey] ?: @[]) {
			NSString *subject = entry[@"subject"] ?: @"";
			[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:[subject stringByAppendingString:@"\n"] attributes:self.titleAttributes]];
			NSString *detail = [NSString stringWithFormat:@"%@  •  %@  •  ", entry[@"author"] ?: @"", entry[@"date"] ?: @""];
			[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:detail attributes:@{
				NSFontAttributeName : [NSFont systemFontOfSize:11],
				NSForegroundColorAttributeName : NSColor.secondaryLabelColor,
			}]];
			NSString *sha = entry[@"sha"] ?: @"";
			[self appendLinkWithTitle:(sha.length > 12 ? [sha substringToIndex:12] : sha)
						  payload:@{ @"type" : @"commit", @"sha" : sha }
						 toString:rendered];
			[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n\n"]];
		}
	}
	[self setRenderedString:rendered generation:self.renderGeneration];
}

- (NSString *)fileKeyForLine:(NSString *)line section:(NSUInteger)sectionIndex
{
	NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
	NSString *path = parts.count >= 4 ? parts[3] : line;
	if ([path hasPrefix:@"b/"]) path = [path substringFromIndex:2];
	return [NSString stringWithFormat:@"%lu:%@", (unsigned long)sectionIndex, path];
}

- (NSMutableAttributedString *)attributedDiffLine:(NSString *)line counterpart:(nullable NSString *)counterpart
{
	NSMutableDictionary *attributes = [self.baseAttributes mutableCopy];
	if ([line hasPrefix:@"+"] && ![line hasPrefix:@"+++"]) {
		attributes[NSForegroundColorAttributeName] = [NSColor colorWithRed:0.08 green:0.46 blue:0.18 alpha:1];
		attributes[NSBackgroundColorAttributeName] = [NSColor colorWithRed:0.20 green:0.70 blue:0.30 alpha:0.13];
	} else if ([line hasPrefix:@"-"] && ![line hasPrefix:@"---"]) {
		attributes[NSForegroundColorAttributeName] = [NSColor colorWithRed:0.72 green:0.12 blue:0.13 alpha:1];
		attributes[NSBackgroundColorAttributeName] = [NSColor colorWithRed:0.90 green:0.20 blue:0.20 alpha:0.12];
	} else if ([line hasPrefix:@"@@"]) {
		attributes[NSForegroundColorAttributeName] = NSColor.systemBlueColor;
		attributes[NSBackgroundColorAttributeName] = [NSColor colorWithRed:0.20 green:0.45 blue:0.90 alpha:0.10];
	} else if ([line hasPrefix:@"index "] || [line hasPrefix:@"--- "] || [line hasPrefix:@"+++ "]) {
		attributes[NSForegroundColorAttributeName] = NSColor.secondaryLabelColor;
	}
	NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:line attributes:attributes];
	if (counterpart.length > 1 && line.length > 1) {
		NSString *left = [line substringFromIndex:1];
		NSString *right = [counterpart substringFromIndex:1];
		NSUInteger prefix = 0;
		NSUInteger limit = MIN(left.length, right.length);
		while (prefix < limit && [left characterAtIndex:prefix] == [right characterAtIndex:prefix]) prefix++;
		NSUInteger suffix = 0;
		while (suffix < limit - prefix && [left characterAtIndex:left.length - 1 - suffix] == [right characterAtIndex:right.length - 1 - suffix]) suffix++;
		NSUInteger changedLength = left.length - prefix - suffix;
		if (changedLength) {
			NSColor *emphasis = [line hasPrefix:@"+"]
				? [NSColor colorWithRed:0.15 green:0.66 blue:0.25 alpha:0.30]
				: [NSColor colorWithRed:0.90 green:0.18 blue:0.18 alpha:0.27];
			[result addAttribute:NSBackgroundColorAttributeName value:emphasis range:NSMakeRange(1 + prefix, changedLength)];
		}
	}
	return result;
}

- (void)appendDiffLine:(NSString *)line counterpart:(nullable NSString *)counterpart newline:(BOOL)newline toString:(NSMutableAttributedString *)rendered
{
	[rendered appendAttributedString:[self attributedDiffLine:line counterpart:counterpart]];
	if (newline) [rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:self.baseAttributes]];
}

- (void)appendDiffLine:(NSString *)line toString:(NSMutableAttributedString *)rendered
{
	[self appendDiffLine:line counterpart:nil newline:YES toString:rendered];
}

- (nullable NSString *)patchWithFileHeader:(NSArray<NSString *> *)fileHeader
							 hunkLines:(NSArray<NSString *> *)hunkLines
						selectedIndexes:(NSIndexSet *)selectedIndexes
							   reverse:(BOOL)reverse
{
	if (hunkLines.count < 2 || ![hunkLines.firstObject hasPrefix:@"@@"]) return nil;
	NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:@"^@@ -(\\d+)(?:,\\d+)? \\+(\\d+)(?:,\\d+)? @@(.*)$" options:0 error:nil];
	NSTextCheckingResult *match = [expression firstMatchInString:hunkLines.firstObject options:0 range:NSMakeRange(0, hunkLines.firstObject.length)];
	if (!match || match.numberOfRanges < 4) return nil;
	NSString *oldStart = [hunkLines.firstObject substringWithRange:[match rangeAtIndex:1]];
	NSString *newStart = [hunkLines.firstObject substringWithRange:[match rangeAtIndex:2]];
	NSString *suffix = [hunkLines.firstObject substringWithRange:[match rangeAtIndex:3]];

	NSMutableArray<NSString *> *body = [NSMutableArray array];
	NSUInteger oldCount = 0;
	NSUInteger newCount = 0;
	for (NSUInteger index = 1; index < hunkLines.count; index++) {
		NSString *line = hunkLines[index];
		if (!line.length) continue;
		unichar prefix = [line characterAtIndex:0];
		BOOL marker = prefix == '\\';
		BOOL selected = [selectedIndexes containsIndex:index];
		if (marker && index > 0 && [selectedIndexes containsIndex:index - 1]) selected = YES;
		if (!selected) {
			unichar contextualChange = reverse ? '+' : '-';
			unichar omittedChange = reverse ? '-' : '+';
			if (prefix == contextualChange) {
				line = [@" " stringByAppendingString:[line substringFromIndex:1]];
				prefix = ' ';
			}
			if (prefix == omittedChange) continue;
		}
		[body addObject:line];
		if (marker) continue;
		if (prefix == '-') oldCount++;
		else if (prefix == '+') newCount++;
		else { oldCount++; newCount++; }
	}
	if (!oldCount && !newCount) return nil;
	NSMutableArray<NSString *> *patch = [fileHeader mutableCopy];
	[patch addObject:[NSString stringWithFormat:@"@@ -%@,%lu +%@,%lu @@%@", oldStart, (unsigned long)oldCount, newStart, (unsigned long)newCount, suffix]];
	[patch addObjectsFromArray:body];
	return [[[patch componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] copy];
}

- (void)renderDiffText:(NSString *)diff
				 context:(NSString *)context
			 section:(NSUInteger)sectionIndex
			  toString:(NSMutableAttributedString *)rendered
{
	NSArray<NSString *> *lines = [diff componentsSeparatedByString:@"\n"];
	NSMutableArray<NSString *> *fileHeader = [NSMutableArray array];
	NSString *fileKey = [NSString stringWithFormat:@"%lu:patch", (unsigned long)sectionIndex];
	NSString *currentPath = @"";
	BOOL collapsed = NO;
	NSUInteger currentHunkStart = NSNotFound;
	NSUInteger currentHunkEnd = NSNotFound;
	for (NSUInteger index = 0; index < lines.count; index++) {
		NSString *line = lines[index];
		if ([line hasPrefix:@"diff --git "]) {
			[fileHeader removeAllObjects];
			[fileHeader addObject:line];
			fileKey = [self fileKeyForLine:line section:sectionIndex];
			collapsed = [self.collapsedFiles containsObject:fileKey];
			[self appendLinkWithTitle:(collapsed ? @"▸ " : @"▾ ")
						  payload:@{ @"type" : @"collapse", @"key" : fileKey }
						 toString:rendered];
			NSArray *parts = [line componentsSeparatedByString:@" "];
			NSString *path = parts.count >= 4 ? parts[3] : line;
			if ([path hasPrefix:@"b/"]) path = [path substringFromIndex:2];
			currentPath = path;
			[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:[path stringByAppendingString:@"\n"] attributes:self.titleAttributes]];
			continue;
		}
		if (collapsed) continue;
		if ([line hasPrefix:@"@@"]) {
			NSUInteger end = index + 1;
			while (end < lines.count && ![lines[end] hasPrefix:@"@@"] && ![lines[end] hasPrefix:@"diff --git "]) end++;
			NSMutableArray<NSString *> *patchLines = [fileHeader mutableCopy];
			[patchLines addObjectsFromArray:[lines subarrayWithRange:NSMakeRange(index, end - index)]];
			NSString *patch = [[patchLines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
			currentHunkStart = index;
			currentHunkEnd = end;
			[self appendDiffLine:line toString:rendered];
			[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "]];
			if ([context isEqualToString:@"staged"]) {
				[self appendLinkWithTitle:@"Unstage hunk" payload:@{ @"type" : @"diff", @"action" : @"unstage", @"patch" : patch } toString:rendered];
			} else if ([context isEqualToString:@"unstaged"]) {
				[self appendLinkWithTitle:@"Stage hunk" payload:@{ @"type" : @"diff", @"action" : @"stage", @"patch" : patch } toString:rendered];
				[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"   "]];
				[self appendLinkWithTitle:@"Discard hunk" payload:@{ @"type" : @"diff", @"action" : @"discard", @"patch" : patch } toString:rendered];
			}
			[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
			continue;
		}
		if (fileHeader.count && ([line hasPrefix:@"index "] || [line hasPrefix:@"new file "] || [line hasPrefix:@"deleted file "] || [line hasPrefix:@"--- "] || [line hasPrefix:@"+++ "])) {
			[fileHeader addObject:line];
		}
		BOOL binaryImage = ([line hasPrefix:@"Binary files "] || [line isEqualToString:@"GIT binary patch"])
			&& [@[ @"png", @"jpg", @"jpeg", @"gif", @"tiff", @"tif", @"bmp", @"icns", @"webp" ] containsObject:currentPath.pathExtension.lowercaseString];
		if (binaryImage && currentPath.length) {
			[self appendDiffLine:line toString:rendered];
			NSString *imageKey = [NSString stringWithFormat:@"%lu:%@", (unsigned long)sectionIndex, currentPath];
			if (![self.expandedImages containsObject:imageKey]) {
				[self appendLinkWithTitle:@"Show image" payload:@{ @"type" : @"image", @"key" : imageKey, @"path" : currentPath, @"section" : @(sectionIndex) } toString:rendered];
				[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:self.baseAttributes]];
			} else if ([self.delegate respondsToSelector:@selector(nativeContentView:imageForPath:section:)]) {
				NSImage *image = [self.delegate nativeContentView:self imageForPath:currentPath section:sectionIndex];
				if (image) {
					NSSize size = image.size;
					CGFloat scale = MIN(1.0, MIN(800.0 / MAX(1.0, size.width), 500.0 / MAX(1.0, size.height)));
					image.size = NSMakeSize(size.width * scale, size.height * scale);
					NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
					attachment.image = image;
					[rendered appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
					[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:self.baseAttributes]];
				}
			}
			continue;
		}
		BOOL changedLine = ([line hasPrefix:@"+"] && ![line hasPrefix:@"+++"]) || ([line hasPrefix:@"-"] && ![line hasPrefix:@"---"]);
		NSString *counterpart = nil;
		if ([line hasPrefix:@"-"] && index + 1 < lines.count && [lines[index + 1] hasPrefix:@"+"]) counterpart = lines[index + 1];
		else if ([line hasPrefix:@"+"] && index > 0 && [lines[index - 1] hasPrefix:@"-"]) counterpart = lines[index - 1];
		if (!changedLine || [context isEqualToString:@"readOnly"] || currentHunkStart == NSNotFound) {
			[self appendDiffLine:line counterpart:counterpart newline:YES toString:rendered];
			continue;
		}

		[self appendDiffLine:line counterpart:counterpart newline:NO toString:rendered];
		[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"   " attributes:self.baseAttributes]];
		NSArray *hunkLines = [lines subarrayWithRange:NSMakeRange(currentHunkStart, currentHunkEnd - currentHunkStart)];
		NSUInteger relativeIndex = index - currentHunkStart;
		NSString *linePatch = [self patchWithFileHeader:fileHeader hunkLines:hunkLines selectedIndexes:[NSIndexSet indexSetWithIndex:relativeIndex] reverse:[context isEqualToString:@"staged"]];
		NSString *primaryTitle = [context isEqualToString:@"staged"] ? @"Unstage line" : @"Stage line";
		NSString *primaryAction = [context isEqualToString:@"staged"] ? @"unstage" : @"stage";
		if (linePatch) [self appendLinkWithTitle:primaryTitle payload:@{ @"type" : @"diff", @"action" : primaryAction, @"patch" : linePatch } toString:rendered];

		BOOL blockStart = index == currentHunkStart + 1;
		if (!blockStart && index > currentHunkStart + 1) {
			NSString *previous = lines[index - 1];
			blockStart = ![previous hasPrefix:@"+"] && ![previous hasPrefix:@"-"];
		}
		if (blockStart) {
			NSUInteger blockEnd = index;
			while (blockEnd + 1 < currentHunkEnd && ([lines[blockEnd + 1] hasPrefix:@"+"] || [lines[blockEnd + 1] hasPrefix:@"-"] || [lines[blockEnd + 1] hasPrefix:@"\\"])) blockEnd++;
			NSMutableIndexSet *blockIndexes = [NSMutableIndexSet indexSet];
			for (NSUInteger absolute = index; absolute <= blockEnd; absolute++) [blockIndexes addIndex:absolute - currentHunkStart];
			NSString *blockPatch = [self patchWithFileHeader:fileHeader hunkLines:hunkLines selectedIndexes:blockIndexes reverse:[context isEqualToString:@"staged"]];
			if (blockPatch) {
				[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"   " attributes:self.baseAttributes]];
				[self appendLinkWithTitle:[context isEqualToString:@"staged"] ? @"Unstage block" : @"Stage block" payload:@{ @"type" : @"diff", @"action" : primaryAction, @"patch" : blockPatch } toString:rendered];
			}
		}
		if ([context isEqualToString:@"unstaged"] && linePatch) {
			[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"   " attributes:self.baseAttributes]];
			[self appendLinkWithTitle:@"Discard line" payload:@{ @"type" : @"diff", @"action" : @"discard", @"patch" : linePatch } toString:rendered];
		}
		[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:self.baseAttributes]];
	}
}

- (void)showDiffSections:(NSArray<NSDictionary *> *)sections
{
	self.currentDiffSections = [sections copy];
	self.renderGeneration++;
	[self.linkPayloads removeAllObjects];
	NSMutableAttributedString *rendered = [[NSMutableAttributedString alloc] init];
	NSUInteger sectionIndex = 0;
	for (NSDictionary *section in sections) {
		NSString *title = section[PBNativeSectionTitleKey] ?: @"";
		NSString *diff = section[PBNativeSectionTextKey] ?: @"";
		[self appendSectionTitle:title toString:rendered];
		NSString *largeKey = [NSString stringWithFormat:@"%lu:%lu", (unsigned long)sectionIndex, (unsigned long)diff.length];
		if ([diff lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > PBNativeLargePatchThreshold && ![self.approvedLargeSections containsObject:largeKey]) {
			NSString *size = [NSByteCountFormatter stringFromByteCount:[diff lengthOfBytesUsingEncoding:NSUTF8StringEncoding] countStyle:NSByteCountFormatterCountStyleFile];
			[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"Patch is %@. ", size] attributes:self.baseAttributes]];
			[self appendLinkWithTitle:@"Render patch…" payload:@{ @"type" : @"large", @"key" : largeKey } toString:rendered];
			[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
		} else if (diff.length == 0) {
			[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"There are no differences.\n" attributes:@{ NSForegroundColorAttributeName : NSColor.secondaryLabelColor }]];
		} else {
			[self renderDiffText:diff context:section[PBNativeSectionContextKey] ?: @"readOnly" section:sectionIndex toString:rendered];
		}
		sectionIndex++;
	}
	[self setRenderedString:rendered generation:self.renderGeneration];
}

- (BOOL)textView:(NSTextView *)textView clickedOnLink:(id)link atIndex:(NSUInteger)charIndex
{
	NSString *key = [link isKindOfClass:NSURL.class] ? [link absoluteString] : [link description];
	NSDictionary *payload = self.linkPayloads[key];
	if (!payload) return NO;
	NSString *type = payload[@"type"];
	if ([type isEqualToString:@"diff"]) {
		if ([self.delegate respondsToSelector:@selector(nativeContentView:performDiffAction:patch:)])
			[self.delegate nativeContentView:self performDiffAction:payload[@"action"] patch:payload[@"patch"]];
	} else if ([type isEqualToString:@"commit"]) {
		if ([self.delegate respondsToSelector:@selector(nativeContentView:selectCommit:)])
			[self.delegate nativeContentView:self selectCommit:payload[@"sha"]];
	} else if ([type isEqualToString:@"collapse"]) {
		NSString *fileKey = payload[@"key"];
		if ([self.collapsedFiles containsObject:fileKey]) [self.collapsedFiles removeObject:fileKey];
		else [self.collapsedFiles addObject:fileKey];
		[self showDiffSections:self.currentDiffSections];
	} else if ([type isEqualToString:@"large"]) {
		NSAlert *alert = [[NSAlert alloc] init];
		alert.messageText = @"Render large patch?";
		alert.informativeText = @"Rendering a large patch can briefly make GitX less responsive.";
		[alert addButtonWithTitle:@"Render"];
		[alert addButtonWithTitle:@"Cancel"];
		void (^completion)(NSModalResponse) = ^(NSModalResponse response) {
			if (response == NSAlertFirstButtonReturn) {
				[self.approvedLargeSections addObject:payload[@"key"]];
				[self showDiffSections:self.currentDiffSections];
			}
		};
		if (self.window) [alert beginSheetModalForWindow:self.window completionHandler:completion];
		else completion([alert runModal]);
	} else if ([type isEqualToString:@"image"]) {
		[self.expandedImages addObject:payload[@"key"]];
		[self showDiffSections:self.currentDiffSections];
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
