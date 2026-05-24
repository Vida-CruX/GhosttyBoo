//
//  GhosttyBoo_Screen_SaverView.m
//  GhosttyBoo Screen Saver
//
//  Created by 陈鹤 on 23/5/2026.
//

#import "GhosttyBoo_Screen_SaverView.h"

/** Time between animation frames, matching the homepage's 31ms frame length. */
static const NSTimeInterval GhosttyBooFrameInterval = 0.031;

/** The homepage terminal is configured for at least 100 source columns. */
static const NSUInteger GhosttyBooMinimumSourceColumns = 100;

/** The homepage terminal reserves 41 source rows. */
static const NSUInteger GhosttyBooSourceRows = 41;

/** The homepage animation starts at frame 16. */
static const NSUInteger GhosttyBooInitialFrameIndex = 16;

/** Markup used by the checked-in text frames for brand-colored spans. */
static NSString * const GhosttyBooBrandOpenTag = @"<span class=\"b\">";

/** Closing markup used by the checked-in text frames for colored spans. */
static NSString * const GhosttyBooBrandCloseTag = @"</span>";

/** Resource subdirectory containing the copied homepage animation frames. */
static NSString * const GhosttyBooAnimationFramesDirectory = @"AnimationFrames";

/** Parsed metrics for one of the website terminal font sizes. */
typedef struct {
    CGFloat contentFontSize;
    CGFloat characterWidth;
    CGFloat characterHeight;
} GhosttyBooTerminalMetrics;

/** Stores one parsed text row and the character columns that use brand color. */
@interface GhosttyBooParsedLine : NSObject

@property (nonatomic, copy, readonly) NSString *text;
@property (nonatomic, copy, readonly) NSIndexSet *brandColumns;

- (instancetype)initWithText:(NSString *)text brandColumns:(NSIndexSet *)brandColumns;

@end

@implementation GhosttyBooParsedLine

- (instancetype)initWithText:(NSString *)text brandColumns:(NSIndexSet *)brandColumns
{
    self = [super init];
    if (self) {
        _text = [text copy];
        _brandColumns = [brandColumns copy];
    }
    return self;
}

@end

/** Converts a CSS-style RGB hex value into an AppKit color. */
static NSColor *GhosttyBooColorFromHex(NSUInteger hex)
{
    CGFloat red = ((hex >> 16) & 0xff) / 255.0;
    CGFloat green = ((hex >> 8) & 0xff) / 255.0;
    CGFloat blue = (hex & 0xff) / 255.0;
    return [NSColor colorWithSRGBRed:red green:green blue:blue alpha:1.0];
}

/** Returns the extra character spacing needed to match the website cell width. */
static CGFloat GhosttyBooKernForFont(NSFont *font, CGFloat characterWidth)
{
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName: font,
        NSLigatureAttributeName: @0,
    };
    CGFloat measuredWidth = [@"0" sizeWithAttributes:attributes].width;
    return characterWidth - measuredWidth;
}

/** Returns the terminal metrics that match the homepage responsive breakpoints. */
static GhosttyBooTerminalMetrics GhosttyBooMetricsForBounds(NSRect bounds)
{
    NSInteger widthSize = NSWidth(bounds) > 1100.0 ? 2 : (NSWidth(bounds) > 674.0 ? 1 : 0);
    NSInteger heightSize = NSHeight(bounds) > 900.0 ? 2 : (NSHeight(bounds) > 750.0 ? 1 : 0);
    NSInteger size = MIN(widthSize, heightSize);

    if (size == 2) {
        return (GhosttyBooTerminalMetrics){
            .contentFontSize = 12.0,
            .characterWidth = 7.2,
            .characterHeight = 16.6,
        };
    }

    if (size == 1) {
        return (GhosttyBooTerminalMetrics){
            .contentFontSize = 10.0,
            .characterWidth = 6.0,
            .characterHeight = 13.8,
        };
    }

    return (GhosttyBooTerminalMetrics){
        .contentFontSize = 6.0,
        .characterWidth = 3.6,
        .characterHeight = 9.0,
    };
}

/** Calculates the borderless animation grid size from the website cell metrics. */
static NSSize GhosttyBooAnimationSize(GhosttyBooTerminalMetrics metrics, NSUInteger columns)
{
    return NSMakeSize(
        (CGFloat)columns * metrics.characterWidth,
        (CGFloat)GhosttyBooSourceRows * metrics.characterHeight
    );
}

/** Scales the website metrics down only when the host view is too small. */
static GhosttyBooTerminalMetrics GhosttyBooScaledMetrics(GhosttyBooTerminalMetrics metrics, CGFloat scale)
{
    return (GhosttyBooTerminalMetrics){
        .contentFontSize = metrics.contentFontSize * scale,
        .characterWidth = metrics.characterWidth * scale,
        .characterHeight = metrics.characterHeight * scale,
    };
}

/** Returns a non-upscaling fit factor for small System Settings preview views. */
static CGFloat GhosttyBooFitScaleForSize(NSSize size, NSRect bounds)
{
    if (size.width <= 0.0 || size.height <= 0.0 || NSWidth(bounds) <= 0.0 || NSHeight(bounds) <= 0.0) {
        return 1.0;
    }

    CGFloat widthScale = NSWidth(bounds) / size.width;
    CGFloat heightScale = NSHeight(bounds) / size.height;
    return MIN(1.0, MIN(widthScale, heightScale));
}

/** Returns sorted frame resource URLs, falling back to the bundle root if needed. */
static NSArray<NSURL *> *GhosttyBooSortedFrameURLs(NSBundle *bundle)
{
    NSArray<NSURL *> *frameURLs = [bundle URLsForResourcesWithExtension:@"txt" subdirectory:GhosttyBooAnimationFramesDirectory];
    if (frameURLs.count == 0) {
        NSArray<NSURL *> *rootURLs = [bundle URLsForResourcesWithExtension:@"txt" subdirectory:nil];
        NSPredicate *framePredicate = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary<NSString *,id> *bindings) {
            (void)bindings;
            return [url.lastPathComponent hasPrefix:@"frame_"];
        }];
        frameURLs = [rootURLs filteredArrayUsingPredicate:framePredicate];
    }

    return [frameURLs sortedArrayUsingComparator:^NSComparisonResult(NSURL *firstURL, NSURL *secondURL) {
        return [firstURL.lastPathComponent compare:secondURL.lastPathComponent options:NSNumericSearch];
    }];
}

/** Parses a frame line, preserving text columns while marking brand-colored spans. */
static GhosttyBooParsedLine *GhosttyBooParseLine(NSString *rawLine)
{
    NSMutableString *text = [NSMutableString stringWithCapacity:rawLine.length];
    NSMutableIndexSet *brandColumns = [NSMutableIndexSet indexSet];
    BOOL isBrand = NO;
    NSUInteger sourceIndex = 0;
    NSUInteger column = 0;

    while (sourceIndex < rawLine.length) {
        if (sourceIndex + GhosttyBooBrandOpenTag.length <= rawLine.length) {
            NSString *candidate = [rawLine substringWithRange:NSMakeRange(sourceIndex, GhosttyBooBrandOpenTag.length)];
            if ([candidate isEqualToString:GhosttyBooBrandOpenTag]) {
                isBrand = YES;
                sourceIndex += GhosttyBooBrandOpenTag.length;
                continue;
            }
        }

        if (sourceIndex + GhosttyBooBrandCloseTag.length <= rawLine.length) {
            NSString *candidate = [rawLine substringWithRange:NSMakeRange(sourceIndex, GhosttyBooBrandCloseTag.length)];
            if ([candidate isEqualToString:GhosttyBooBrandCloseTag]) {
                isBrand = NO;
                sourceIndex += GhosttyBooBrandCloseTag.length;
                continue;
            }
        }

        unichar character = [rawLine characterAtIndex:sourceIndex];
        [text appendFormat:@"%C", character];
        if (isBrand) {
            [brandColumns addIndex:column];
        }
        column += 1;
        sourceIndex += 1;
    }

    return [[GhosttyBooParsedLine alloc] initWithText:text brandColumns:brandColumns];
}

@interface GhosttyBoo_Screen_SaverView ()

@property (nonatomic, copy) NSArray<NSArray<GhosttyBooParsedLine *> *> *frames;
@property (nonatomic) NSUInteger currentFrameIndex;
@property (nonatomic) NSUInteger sourceColumnCount;

- (NSArray<NSArray<GhosttyBooParsedLine *> *> *)loadAnimationFrames;
- (NSUInteger)sourceColumnCountForFrames:(NSArray<NSArray<GhosttyBooParsedLine *> *> *)frames;

@end

@implementation GhosttyBoo_Screen_SaverView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        _frames = [self loadAnimationFrames];
        _currentFrameIndex = _frames.count > GhosttyBooInitialFrameIndex ? GhosttyBooInitialFrameIndex : 0;
        _sourceColumnCount = [self sourceColumnCountForFrames:_frames];
        [self setAnimationTimeInterval:GhosttyBooFrameInterval];
    }
    return self;
}

- (BOOL)isFlipped
{
    return YES;
}

- (void)startAnimation
{
    [super startAnimation];
    [self setNeedsDisplay:YES];
}

- (void)stopAnimation
{
    [super stopAnimation];
}

- (void)drawRect:(NSRect)rect
{
    (void)rect;
    [super drawRect:self.bounds];

    [GhosttyBooColorFromHex(0x0F0F11) setFill];
    NSRectFill(self.bounds);

    GhosttyBooTerminalMetrics metrics = GhosttyBooMetricsForBounds(self.bounds);
    NSSize animationSize = GhosttyBooAnimationSize(metrics, self.sourceColumnCount);
    CGFloat fitScale = GhosttyBooFitScaleForSize(animationSize, self.bounds);
    if (fitScale < 1.0) {
        metrics = GhosttyBooScaledMetrics(metrics, fitScale);
        animationSize = GhosttyBooAnimationSize(metrics, self.sourceColumnCount);
    }

    NSRect animationRect = NSMakeRect(
        NSMinX(self.bounds) + ((NSWidth(self.bounds) - animationSize.width) / 2.0),
        NSMinY(self.bounds) + ((NSHeight(self.bounds) - animationSize.height) / 2.0),
        animationSize.width,
        animationSize.height
    );

    if (self.frames.count == 0) {
        return;
    }

    NSArray<GhosttyBooParsedLine *> *frame = self.frames[self.currentFrameIndex];
    [self drawFrame:frame inAnimationRect:animationRect metrics:metrics];
}

- (void)animateOneFrame
{
    if (self.frames.count == 0) {
        return;
    }

    self.currentFrameIndex = (self.currentFrameIndex + 1) % self.frames.count;
    [self setNeedsDisplay:YES];
}

- (BOOL)hasConfigureSheet
{
    return NO;
}

- (NSWindow*)configureSheet
{
    return nil;
}

/** Loads all bundled animation frame resources into parsed line objects. */
- (NSArray<NSArray<GhosttyBooParsedLine *> *> *)loadAnimationFrames
{
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSArray<NSURL *> *frameURLs = GhosttyBooSortedFrameURLs(bundle);
    if (frameURLs.count == 0) {
        NSLog(@"GhosttyBoo: no bundled animation frame resources were found.");
    }

    NSMutableArray<NSArray<GhosttyBooParsedLine *> *> *frames = [NSMutableArray arrayWithCapacity:frameURLs.count];

    for (NSURL *frameURL in frameURLs) {
        NSError *error = nil;
        NSString *content = [NSString stringWithContentsOfURL:frameURL encoding:NSUTF8StringEncoding error:&error];
        if (content == nil) {
            continue;
        }

        NSMutableArray<NSString *> *rawLines = [[content componentsSeparatedByString:@"\n"] mutableCopy];
        if (rawLines.count > 0 && rawLines.lastObject.length == 0) {
            [rawLines removeLastObject];
        }

        NSMutableArray<GhosttyBooParsedLine *> *parsedLines = [NSMutableArray arrayWithCapacity:rawLines.count];
        for (NSString *rawLine in rawLines) {
            [parsedLines addObject:GhosttyBooParseLine(rawLine)];
        }
        [frames addObject:parsedLines];
    }

    return frames;
}

/** Measures the widest parsed frame line so right-edge animation details are not clipped. */
- (NSUInteger)sourceColumnCountForFrames:(NSArray<NSArray<GhosttyBooParsedLine *> *> *)frames
{
    NSUInteger sourceColumnCount = GhosttyBooMinimumSourceColumns;
    for (NSArray<GhosttyBooParsedLine *> *frame in frames) {
        for (GhosttyBooParsedLine *line in frame) {
            sourceColumnCount = MAX(sourceColumnCount, line.text.length);
        }
    }
    return sourceColumnCount;
}

/** Draws one parsed frame into the centered borderless animation grid. */
- (void)drawFrame:(NSArray<GhosttyBooParsedLine *> *)frame
  inAnimationRect:(NSRect)animationRect
          metrics:(GhosttyBooTerminalMetrics)metrics
{
    NSFont *font = [NSFont monospacedSystemFontOfSize:metrics.contentFontSize weight:NSFontWeightRegular];
    CGFloat kern = GhosttyBooKernForFont(font, metrics.characterWidth);
    NSDictionary<NSAttributedStringKey, id> *normalAttributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: GhosttyBooColorFromHex(0xc3c3c4),
        NSKernAttributeName: @(kern),
        NSLigatureAttributeName: @0,
    };
    NSColor *brandColor = GhosttyBooColorFromHex(0x3551F3);

    CGFloat contentX = NSMinX(animationRect);
    CGFloat contentY = NSMinY(animationRect);
    NSUInteger rowCount = MIN(frame.count, GhosttyBooSourceRows);

    for (NSUInteger row = 0; row < rowCount; row += 1) {
        GhosttyBooParsedLine *line = frame[row];
        NSString *text = line.text;
        NSMutableAttributedString *attributedLine = [[NSMutableAttributedString alloc] initWithString:text attributes:normalAttributes];
        [line.brandColumns enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
            (void)stop;
            NSRange clippedRange = NSIntersectionRange(range, NSMakeRange(0, text.length));
            if (clippedRange.length > 0) {
                [attributedLine addAttribute:NSForegroundColorAttributeName value:brandColor range:clippedRange];
            }
        }];

        NSRect lineRect = NSMakeRect(
            contentX,
            contentY + ((CGFloat)row * metrics.characterHeight),
            (CGFloat)self.sourceColumnCount * metrics.characterWidth,
            metrics.characterHeight
        );
        [attributedLine drawInRect:lineRect];
    }
}

@end
