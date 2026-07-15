#import "PBNativeContentView.h"
#import "PBHighlighting.h"

NSString *const PBNativeSectionTitleKey = @"title";
NSString *const PBNativeSectionTextKey = @"text";
NSString *const PBNativeSectionPathKey = @"path";
NSString *const PBNativeSectionContextKey = @"context";
NSString *const PBNativeSectionEntriesKey = @"entries";

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
@property (nonatomic) NSDictionary<NSAttributedStringKey, id> *baseTextAttributes;
@property (nonatomic) NSDictionary<NSAttributedStringKey, id> *titleTextAttributes;
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
	_baseTextAttributes = @{NSFontAttributeName : [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular],
							NSForegroundColorAttributeName : NSColor.textColor};
	_titleTextAttributes = @{NSFontAttributeName : [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
							 NSForegroundColorAttributeName : NSColor.labelColor};

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
	return self.baseTextAttributes;
}

- (NSDictionary *)titleAttributes
{
	return self.titleTextAttributes;
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
{
	if (generation != self.renderGeneration) return;
	self.linkPayloads = linkPayloads ? [linkPayloads mutableCopy] : [NSMutableDictionary dictionary];
	[self.textView.textStorage setAttributedString:string];
	[self.textView scrollRangeToVisible:NSMakeRange(0, 0)];
}

- (void)showMessage:(NSString *)message
{
	self.renderGeneration++;
	NSAttributedString *string = [[NSAttributedString alloc] initWithString:message ?: @""
																 attributes:@{
																	 NSFontAttributeName : [NSFont systemFontOfSize:13],
																	 NSForegroundColorAttributeName : NSColor.secondaryLabelColor,
																 }];
	[self setRenderedString:string generation:self.renderGeneration linkPayloads:nil];
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
			[self setRenderedString:rendered generation:generation linkPayloads:nil];
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
				shortSHA = [shortSHA stringByPaddingToLength:8 withString:@" " startingAtIndex:0];
				author = [author stringByPaddingToLength:18 withString:@" " startingAtIndex:0];
				NSString *gutter = [NSString stringWithFormat:@"%@  %@ │ ", shortSHA, author];
				[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:gutter
																				 attributes:@{
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
			[self setRenderedString:rendered generation:generation linkPayloads:nil];
		});
	});
}

- (NSURL *)appendLinkWithTitle:(NSString *)title
					   payload:(NSDictionary *)payload
				  linkPayloads:(NSMutableDictionary<NSString *, NSDictionary *> *)linkPayloads
					  toString:(NSMutableAttributedString *)result
{
	NSString *token = NSUUID.UUID.UUIDString;
	NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:@"gitx-action://%@", token]];
	linkPayloads[URL.absoluteString] = payload;
	NSString *localizedTitle = NSLocalizedString(title, @"Native content action title");
	NSMutableAttributedString *link = [[NSMutableAttributedString alloc] initWithString:localizedTitle
																			 attributes:@{
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
	NSUInteger generation = ++self.renderGeneration;
	NSArray *copiedSections = [sections copy];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableAttributedString *rendered = [[NSMutableAttributedString alloc] init];
		NSMutableDictionary<NSString *, NSDictionary *> *linkPayloads = [NSMutableDictionary dictionary];
		for (NSDictionary *section in copiedSections) {
			[self appendSectionTitle:section[PBNativeSectionTitleKey] ?: section[PBNativeSectionPathKey] ?:
																										   @""
							toString:rendered];
			for (NSDictionary *entry in section[PBNativeSectionEntriesKey] ?: @[]) {
				NSString *subject = entry[@"subject"] ?: @"";
				[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:[subject stringByAppendingString:@"\n"] attributes:self.titleAttributes]];
				NSString *detail = [NSString stringWithFormat:@"%@  •  %@  •  ", entry[@"author"] ?: @"", entry[@"date"] ?: @""];
				[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:detail
																				 attributes:@{
																					 NSFontAttributeName : [NSFont systemFontOfSize:11],
																					 NSForegroundColorAttributeName : NSColor.secondaryLabelColor,
																				 }]];
				NSString *sha = entry[@"sha"] ?: @"";
				[self appendLinkWithTitle:(sha.length > 12 ? [sha substringToIndex:12] : sha)
								  payload:@{@"type" : @"commit", @"sha" : sha}
							 linkPayloads:linkPayloads
								 toString:rendered];
				[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n\n"]];
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			[self setRenderedString:rendered generation:generation linkPayloads:linkPayloads];
		});
	});
}

- (NSString *)normalizedDiffPath:(NSString *)path
{
	if ([path hasPrefix:@"\""] && [path hasSuffix:@"\""] && path.length >= 2)
		path = [path substringWithRange:NSMakeRange(1, path.length - 2)];
	path = [path stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
	path = [path stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
	if ([path hasPrefix:@"a/"] || [path hasPrefix:@"b/"]) path = [path substringFromIndex:2];
	return path;
}

- (NSString *)pathForDiffHeaderAtIndex:(NSUInteger)headerIndex lines:(NSArray<NSString *> *)lines
{
	NSString *oldPath = nil;
	for (NSUInteger index = headerIndex + 1; index < lines.count && ![lines[index] hasPrefix:@"diff --git "]; index++) {
		NSString *line = lines[index];
		if ([line hasPrefix:@"rename to "]) return [self normalizedDiffPath:[line substringFromIndex:10]];
		if ([line hasPrefix:@"copy to "]) return [self normalizedDiffPath:[line substringFromIndex:8]];
		if ([line hasPrefix:@"+++ "] && ![line isEqualToString:@"+++ /dev/null"])
			return [self normalizedDiffPath:[line substringFromIndex:4]];
		if ([line hasPrefix:@"--- "] && ![line isEqualToString:@"--- /dev/null"])
			oldPath = [self normalizedDiffPath:[line substringFromIndex:4]];
	}
	if (oldPath.length) return oldPath;
	NSString *header = lines[headerIndex];
	NSRange destination = [header rangeOfString:@" b/" options:NSBackwardsSearch];
	if (destination.location != NSNotFound)
		return [self normalizedDiffPath:[header substringFromIndex:NSMaxRange(destination) - 2]];
	return header;
}

- (NSDictionary<NSNumber *, NSAttributedString *> *)syntaxHighlightsForHunkLines:(NSArray<NSString *> *)hunkLines path:(NSString *)path
{
	if (![PBHighlighting languageNameForPath:path]) return @{};

	NSMutableString *oldText = [NSMutableString string];
	NSMutableString *newText = [NSMutableString string];
	NSMutableDictionary<NSNumber *, NSValue *> *oldRanges = [NSMutableDictionary dictionary];
	NSMutableDictionary<NSNumber *, NSValue *> *newRanges = [NSMutableDictionary dictionary];
	for (NSUInteger index = 1; index < hunkLines.count; index++) {
		NSString *line = hunkLines[index];
		if (!line.length) continue;
		unichar prefix = [line characterAtIndex:0];
		if (prefix != ' ' && prefix != '+' && prefix != '-') continue;
		NSString *body = [line substringFromIndex:1];
		if (prefix != '+') {
			NSRange range = NSMakeRange(oldText.length, body.length);
			[oldText appendFormat:@"%@\n", body];
			if (prefix == '-') oldRanges[@(index)] = [NSValue valueWithRange:range];
		}
		if (prefix != '-') {
			NSRange range = NSMakeRange(newText.length, body.length);
			[newText appendFormat:@"%@\n", body];
			newRanges[@(index)] = [NSValue valueWithRange:range];
		}
	}

	NSMutableDictionary<NSNumber *, NSAttributedString *> *highlights = [NSMutableDictionary dictionary];
	if (oldRanges.count) {
		NSAttributedString *highlighted = [PBHighlighting highlightedStringForText:oldText path:path];
		for (NSNumber *index in oldRanges) {
			NSRange range = oldRanges[index].rangeValue;
			if (NSMaxRange(range) <= highlighted.length)
				highlights[index] = [highlighted attributedSubstringFromRange:range];
		}
	}
	if (newRanges.count) {
		NSAttributedString *highlighted = [PBHighlighting highlightedStringForText:newText path:path];
		for (NSNumber *index in newRanges) {
			NSRange range = newRanges[index].rangeValue;
			if (NSMaxRange(range) <= highlighted.length)
				highlights[index] = [highlighted attributedSubstringFromRange:range];
		}
	}
	return highlights;
}

- (NSMutableAttributedString *)attributedDiffLine:(NSString *)line
									  counterpart:(nullable NSString *)counterpart
									   syntaxBody:(nullable NSAttributedString *)syntaxBody
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
	NSMutableAttributedString *result;
	if (syntaxBody && line.length && syntaxBody.length == line.length - 1) {
		result = [[NSMutableAttributedString alloc] initWithString:[line substringToIndex:1] attributes:attributes];
		[result appendAttributedString:syntaxBody];
		NSColor *background = attributes[NSBackgroundColorAttributeName];
		if (background)
			[result addAttribute:NSBackgroundColorAttributeName value:background range:NSMakeRange(0, result.length)];
	} else {
		result = [[NSMutableAttributedString alloc] initWithString:line attributes:attributes];
	}
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

- (void)appendDiffLine:(NSString *)line
		   counterpart:(nullable NSString *)counterpart
			syntaxBody:(nullable NSAttributedString *)syntaxBody
			   newline:(BOOL)newline
			  toString:(NSMutableAttributedString *)rendered
{
	[rendered appendAttributedString:[self attributedDiffLine:line counterpart:counterpart syntaxBody:syntaxBody]];
	if (newline) [rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:self.baseAttributes]];
}

- (void)appendDiffLine:(NSString *)line toString:(NSMutableAttributedString *)rendered
{
	[self appendDiffLine:line counterpart:nil syntaxBody:nil newline:YES toString:rendered];
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
	BOOL previousLineWasEmittedVerbatim = NO;
	for (NSUInteger index = 1; index < hunkLines.count; index++) {
		NSString *line = hunkLines[index];
		if (!line.length) continue;
		unichar prefix = [line characterAtIndex:0];
		BOOL marker = prefix == '\\';
		if (marker) {
			if (previousLineWasEmittedVerbatim) [body addObject:line];
			continue;
		}
		BOOL selected = [selectedIndexes containsIndex:index];
		BOOL emittedVerbatim = YES;
		if (!selected) {
			unichar contextualChange = reverse ? '+' : '-';
			unichar omittedChange = reverse ? '-' : '+';
			if (prefix == contextualChange) {
				line = [@" " stringByAppendingString:[line substringFromIndex:1]];
				prefix = ' ';
				emittedVerbatim = NO;
			}
			if (prefix == omittedChange) {
				previousLineWasEmittedVerbatim = NO;
				continue;
			}
		}
		[body addObject:line];
		previousLineWasEmittedVerbatim = emittedVerbatim;
		if (prefix == '-')
			oldCount++;
		else if (prefix == '+')
			newCount++;
		else {
			oldCount++;
			newCount++;
		}
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
				  path:(NSString *)fallbackPath
		collapsedFiles:(NSSet<NSString *> *)collapsedFiles
		expandedImages:(NSSet<NSString *> *)expandedImages
		  linkPayloads:(NSMutableDictionary<NSString *, NSDictionary *> *)linkPayloads
			  toString:(NSMutableAttributedString *)rendered
{
	NSArray<NSString *> *lines = [diff componentsSeparatedByString:@"\n"];
	NSUInteger byteCount = [diff lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
	BOOL shouldHighlightSyntax = [PBHighlighting shouldHighlightDiffWithByteCount:byteCount];
	if (!shouldHighlightSyntax)
		NSLog(@"[GitX] Rendering %lu-byte diff with lightweight coloring for responsive scrolling", (unsigned long)byteCount);
	NSMutableArray<NSString *> *fileHeader = [NSMutableArray array];
	NSString *fileKey;
	NSString *currentPath = fallbackPath ?: @"";
	BOOL collapsed = NO;
	NSUInteger currentHunkStart = NSNotFound;
	NSUInteger currentHunkEnd = NSNotFound;
	NSArray<NSString *> *currentHunkLines = nil;
	NSArray<NSString *> *currentFileHeader = nil;
	NSDictionary<NSNumber *, NSAttributedString *> *currentHunkSyntax = @{};
	for (NSUInteger index = 0; index < lines.count; index++) {
		NSString *line = lines[index];
		if ([line hasPrefix:@"diff --git "]) {
			[fileHeader removeAllObjects];
			[fileHeader addObject:line];
			currentPath = [self pathForDiffHeaderAtIndex:index lines:lines];
			currentHunkStart = NSNotFound;
			currentHunkEnd = NSNotFound;
			currentHunkLines = nil;
			currentFileHeader = nil;
			currentHunkSyntax = @{};
			fileKey = [NSString stringWithFormat:@"%lu:%@", (unsigned long)sectionIndex, currentPath];
			collapsed = [collapsedFiles containsObject:fileKey];
			[self appendLinkWithTitle:(collapsed ? @"▸ " : @"▾ ")
							  payload:@{@"type" : @"collapse", @"key" : fileKey}
						 linkPayloads:linkPayloads
							 toString:rendered];
			[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:[currentPath stringByAppendingString:@"\n"] attributes:self.titleAttributes]];
			continue;
		}
		if (collapsed) continue;
		if ([line hasPrefix:@"@@"]) {
			NSUInteger end = index + 1;
			while (end < lines.count && ![lines[end] hasPrefix:@"@@"] && ![lines[end] hasPrefix:@"diff --git "]) end++;
			currentHunkLines = [lines subarrayWithRange:NSMakeRange(index, end - index)];
			currentFileHeader = [fileHeader copy];
			NSMutableArray<NSString *> *patchLines = [currentFileHeader mutableCopy];
			[patchLines addObjectsFromArray:currentHunkLines];
			NSString *patch = [[patchLines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
			currentHunkStart = index;
			currentHunkEnd = end;
			currentHunkSyntax = shouldHighlightSyntax ? [self syntaxHighlightsForHunkLines:currentHunkLines path:currentPath] : @{};
			[self appendDiffLine:line toString:rendered];
			[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "]];
			if ([context isEqualToString:@"staged"]) {
				[self appendLinkWithTitle:@"Unstage hunk" payload:@{@"type" : @"diff", @"action" : @"unstage", @"patch" : patch} linkPayloads:linkPayloads toString:rendered];
			} else if ([context isEqualToString:@"unstaged"]) {
				[self appendLinkWithTitle:@"Stage hunk" payload:@{@"type" : @"diff", @"action" : @"stage", @"patch" : patch} linkPayloads:linkPayloads toString:rendered];
				[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"   "]];
				[self appendLinkWithTitle:@"Discard hunk" payload:@{@"type" : @"diff", @"action" : @"discard", @"patch" : patch} linkPayloads:linkPayloads toString:rendered];
			}
			[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
			continue;
		}
		if (fileHeader.count && ([line hasPrefix:@"index "] || [line hasPrefix:@"new file "] || [line hasPrefix:@"deleted file "] || [line hasPrefix:@"--- "] || [line hasPrefix:@"+++ "])) {
			[fileHeader addObject:line];
		}
		BOOL binaryImage = ([line hasPrefix:@"Binary files "] || [line isEqualToString:@"GIT binary patch"]) && [@[ @"png", @"jpg", @"jpeg", @"gif", @"tiff", @"tif", @"bmp", @"icns", @"webp" ] containsObject:currentPath.pathExtension.lowercaseString];
		if (binaryImage && currentPath.length) {
			[self appendDiffLine:line toString:rendered];
			NSString *imageKey = [NSString stringWithFormat:@"%lu:%@", (unsigned long)sectionIndex, currentPath];
			if (![expandedImages containsObject:imageKey]) {
				[self appendLinkWithTitle:@"Show image" payload:@{@"type" : @"image", @"key" : imageKey, @"path" : currentPath, @"section" : @(sectionIndex)} linkPayloads:linkPayloads toString:rendered];
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
		if ([line hasPrefix:@"-"] && index + 1 < lines.count && [lines[index + 1] hasPrefix:@"+"])
			counterpart = lines[index + 1];
		else if ([line hasPrefix:@"+"] && index > 0 && [lines[index - 1] hasPrefix:@"-"])
			counterpart = lines[index - 1];
		NSAttributedString *syntaxBody = currentHunkStart != NSNotFound && index < currentHunkEnd ? currentHunkSyntax[@(index - currentHunkStart)] : nil;
		if (!changedLine || [context isEqualToString:@"readOnly"] || currentHunkStart == NSNotFound) {
			[self appendDiffLine:line counterpart:counterpart syntaxBody:syntaxBody newline:YES toString:rendered];
			continue;
		}

		[self appendDiffLine:line counterpart:counterpart syntaxBody:syntaxBody newline:NO toString:rendered];
		[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"   " attributes:self.baseAttributes]];
		NSUInteger relativeIndex = index - currentHunkStart;
		NSIndexSet *lineIndexes = [NSIndexSet indexSetWithIndex:relativeIndex];
		NSDictionary *linePayload = @{
			@"type" : @"diff",
			@"fileHeader" : currentFileHeader,
			@"hunkLines" : currentHunkLines,
			@"selectedIndexes" : lineIndexes,
			@"reverse" : @([context isEqualToString:@"staged"]),
		};
		NSString *primaryTitle = [context isEqualToString:@"staged"] ? @"Unstage line" : @"Stage line";
		NSString *primaryAction = [context isEqualToString:@"staged"] ? @"unstage" : @"stage";
		NSMutableDictionary *primaryPayload = [linePayload mutableCopy];
		primaryPayload[@"action"] = primaryAction;
		[self appendLinkWithTitle:primaryTitle payload:primaryPayload linkPayloads:linkPayloads toString:rendered];

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
			NSMutableDictionary *blockPayload = [linePayload mutableCopy];
			blockPayload[@"action"] = primaryAction;
			blockPayload[@"selectedIndexes"] = [blockIndexes copy];
			[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"   " attributes:self.baseAttributes]];
			[self appendLinkWithTitle:[context isEqualToString:@"staged"] ? @"Unstage block" : @"Stage block" payload:blockPayload linkPayloads:linkPayloads toString:rendered];
		}
		if ([context isEqualToString:@"unstaged"]) {
			[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"   " attributes:self.baseAttributes]];
			NSMutableDictionary *discardPayload = [linePayload mutableCopy];
			discardPayload[@"action"] = @"discard";
			[self appendLinkWithTitle:@"Discard line" payload:discardPayload linkPayloads:linkPayloads toString:rendered];
		}
		[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:self.baseAttributes]];
	}
}

- (void)showDiffSections:(NSArray<NSDictionary *> *)sections
{
	self.currentDiffSections = [sections copy];
	NSUInteger generation = ++self.renderGeneration;
	NSArray *copiedSections = [sections copy];
	NSSet<NSString *> *collapsedFiles = [self.collapsedFiles copy];
	NSSet<NSString *> *expandedImages = [self.expandedImages copy];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableAttributedString *rendered = [[NSMutableAttributedString alloc] init];
		NSMutableDictionary<NSString *, NSDictionary *> *linkPayloads = [NSMutableDictionary dictionary];
		NSUInteger sectionIndex = 0;
		for (NSDictionary *section in copiedSections) {
			NSString *title = section[PBNativeSectionTitleKey] ?: @"";
			NSString *diff = section[PBNativeSectionTextKey] ?: @"";
			[self appendSectionTitle:title toString:rendered];
			if (diff.length == 0) {
				[rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"There are no differences.\n" attributes:@{NSForegroundColorAttributeName : NSColor.secondaryLabelColor}]];
			} else {
				[self renderDiffText:diff context:section[PBNativeSectionContextKey] ?: @"readOnly" section:sectionIndex path:section[PBNativeSectionPathKey] ?: @"" collapsedFiles:collapsedFiles expandedImages:expandedImages linkPayloads:linkPayloads toString:rendered];
			}
			sectionIndex++;
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			[self setRenderedString:rendered generation:generation linkPayloads:linkPayloads];
		});
	});
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
		[self showDiffSections:self.currentDiffSections];
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
