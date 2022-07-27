//
//  Neovim Mac
//  NVTabLine.m
//
//  Copyright © 2022 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import <QuartzCore/CoreAnimation.h>
#import "NVTabLine.h"

static inline CGFloat cgfloatClamp(CGFloat value, CGFloat min, CGFloat max) {
    return MAX(MIN(value, max), min);
}

static inline CGFloat cgfloatSquare(CGFloat x) {
    return x * x;
}

static inline CGFloat cgfloatDistance(CGPoint a, CGPoint b) {
    return sqrt(cgfloatSquare(a.x - b.x) + cgfloatSquare(a.y - b.y));
}

static inline CGRect CGRectWithWidth(CGRect rect, CGFloat width) {
    rect.size.width = width;
    return rect;
}

static inline CGRect CGRectWithX(CGRect rect, CGFloat x) {
    rect.origin.x = x;
    return rect;
}

static void animateLayerOpacity(CALayer *layer, float fromValue, float toValue, float duration) {
    CALayer *presentationLayer = layer.presentationLayer;

    if (presentationLayer) {
        float currentOpacity = presentationLayer.opacity;
        duration = duration * (fabsf(toValue - currentOpacity) / fabsf(toValue - fromValue));
        fromValue = currentOpacity;
    }

    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    animation.fromValue = [NSNumber numberWithFloat:fromValue];
    animation.toValue = [NSNumber numberWithFloat:toValue];
    animation.duration = duration;

    [layer setOpacity:toValue];
    [layer removeAnimationForKey:@"opacity"];
    [layer addAnimation:animation forKey:@"opacity"];
}

static void animateLayerPosition(CALayer *layer, CGPoint fromPosition, CGPoint toPosition,
                                 CGFloat beginTime, CGFloat duration, CAMediaTimingFunction *timingFunction) {
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"position"];
    animation.duration = duration;
    animation.beginTime = CACurrentMediaTime() + beginTime;
    animation.fromValue = [NSValue valueWithPoint:fromPosition];
    animation.toValue = [NSValue valueWithPoint:toPosition];
    animation.timingFunction = timingFunction;
    animation.fillMode = kCAFillModeBackwards;

    [layer setPosition:toPosition];
    [layer addAnimation:animation forKey:@"position"];
}

static void animateLayerBounds(CALayer *layer, CGRect fromBounds, CGRect toBounds, CGFloat beginTime,
                               CGFloat duration, CAMediaTimingFunction *timingFunction) {
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"bounds"];
    animation.duration = duration;
    animation.beginTime = CACurrentMediaTime() + beginTime;
    animation.fromValue = [NSValue valueWithRect:fromBounds];
    animation.toValue = [NSValue valueWithRect:toBounds];
    animation.timingFunction = timingFunction;
    animation.fillMode = kCAFillModeBackwards;

    [layer setBounds:toBounds];
    [layer addAnimation:animation forKey:@"bounds"];
}

static void animateLayerPath(CAShapeLayer *layer, CGPathRef fromPath, CGPathRef toPath, CGFloat beginTime,
                             CGFloat duration, CAMediaTimingFunction *timingFunction) {
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"path"];
    animation.duration = duration;
    animation.beginTime = CACurrentMediaTime() + beginTime;
    animation.fromValue = CFBridgingRelease(fromPath);
    animation.toValue = CFBridgingRelease(toPath);
    animation.timingFunction = timingFunction;
    animation.fillMode = kCAFillModeBackwards;

    [layer setPath:toPath];
    [layer addAnimation:animation forKey:@"path"];
}

@interface NVTabLine()
- (void)onTabAddButton:(id)sender;
- (void)onTabCloseButton:(id)sender;
- (id<NVTabLineDelegate>)delegate;
- (void)performTabDragWithEvent:(NSEvent *)event tab:(NVTab *)tab;
@end

@interface NVTabButton : NSView
@property (nonatomic) SEL action;
@property (nonatomic, unsafe_unretained) id target;
@end

@implementation NVTabButton {
    NSTrackingArea *trackingArea;
    NSImageView *imageView;
    CGColorRef hoverColor;
    CGColorRef highlightColor;
    CGPathRef circlePath;
    CAShapeLayer *circleLayer;
    float fadeAnimationDuration;
    bool isMouseInside;
    bool isAnimating;
}

- (instancetype)initWithFrame:(NSRect)frameRect
                   symbolRect:(NSRect)symbolRect
                   symbolName:(NSString *)symbolName
                 symbolWeight:(NSFontWeight)symbolWeight
                 fadeDuration:(float)fadeDuration
                  colorScheme:(NVColorScheme *)colorScheme {
    self = [super initWithFrame:frameRect];
    self.wantsLayer = YES;

    fadeAnimationDuration = fadeDuration;
    hoverColor = CGColorRetain(colorScheme.tabButtonHoverColor.CGColor);
    highlightColor = CGColorRetain(colorScheme.tabButtonHighlightColor.CGColor);

    NSRect bounds = [self bounds];
    circlePath = CGPathCreateWithEllipseInRect(bounds, nil);

    circleLayer = [CAShapeLayer layer];
    circleLayer.path = circlePath;
    circleLayer.fillColor = hoverColor;
    circleLayer.opacity = 0;

    [self.layer addSublayer:circleLayer];

    NSImage *symbol = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:symbolRect.size.width
                                                                                         weight:symbolWeight];

    imageView = [[NSImageView alloc] initWithFrame:symbolRect];
    imageView.image = [symbol imageWithSymbolConfiguration:config];
    imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    imageView.contentTintColor = colorScheme.tabButtonColor;

    [self addSubview:imageView];
    return self;
}

- (void)dealloc {
    CGColorRelease(hoverColor);
    CGColorRelease(highlightColor);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];

    if (trackingArea) {
        [self removeTrackingArea:trackingArea];
    }

    NSTrackingAreaOptions trackingOptions = NSTrackingMouseMoved
                                          | NSTrackingMouseEnteredAndExited
                                          | NSTrackingActiveInKeyWindow;

    trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                options:trackingOptions
                                                  owner:self
                                               userInfo:nil];

    [self addTrackingArea:trackingArea];
}

- (void)animateCircleLayerOpacityFrom:(float)fromValue to:(float)toValue {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (fadeAnimationDuration > 0) {
        animateLayerOpacity(circleLayer, fromValue, toValue, fadeAnimationDuration);
    } else {
        circleLayer.opacity = toValue;
    }

    [CATransaction commit];
}

- (void)mouseMoved:(NSEvent *)event {
    if (self.layer.animationKeys.count != 0) {
        return;
    }

    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

    bool wasMouseInside = isMouseInside;
    isMouseInside = CGPathContainsPoint(circlePath, NULL, location, false);

    if (wasMouseInside == isMouseInside) {
        return;
    }

    if (isMouseInside) {
        [self animateCircleLayerOpacityFrom:0 to:1];
    } else {
        [self animateCircleLayerOpacityFrom:1 to:0];
    }
}

- (void)mouseEntered:(NSEvent *)event {
    [self mouseMoved:event];
}

- (void)mouseDown:(NSEvent *)event {
    [self mouseMoved:event];

    if (!isMouseInside) {
        return;
    }

    circleLayer.fillColor = highlightColor;
    NSEventMask eventMask = NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged;

    for (;;) {
        NSEvent *nextEvent = [self.window nextEventMatchingMask:eventMask];
        [self mouseMoved:nextEvent];

        if (nextEvent.type == NSEventTypeLeftMouseUp) {
            return [self mouseUp:nextEvent];
        }
    }
}

- (void)mouseUp:(NSEvent *)event {
    circleLayer.fillColor = hoverColor;

    if (isMouseInside && _target && _action) {
        void (*callback)(id, SEL, id) = (void*)[_target methodForSelector:_action];
        callback(_target, _action, self);
    }
}

- (void)mouseExited:(NSEvent *)event {
    isMouseInside = false;
    [self animateCircleLayerOpacityFrom:1 to:0];
}

- (void)animateSetFrameOrigin:(NSPoint)origin
                     duration:(CGFloat)duration
               timingFunction:(CAMediaTimingFunction *)timingFunction {
    NSRect frame = self.frame;
    CALayer *layer = self.layer;

    CGFloat deltaX = origin.x - frame.origin.x;
    CGFloat deltaY = origin.y - frame.origin.y;

    CGPoint fromPosition = layer.position;
    CGPoint toPosition = CGPointMake(fromPosition.x + deltaX, fromPosition.y + deltaY);
    animateLayerPosition(layer, fromPosition, toPosition, 0, duration, timingFunction);

    NSPoint mouseLocationInWindow = [self.window mouseLocationOutsideOfEventStream];
    NSPoint mouseLocation = [self convertPoint:mouseLocationInWindow fromView:nil];
    mouseLocation.x += deltaX;
    mouseLocation.y += deltaY;

    bool wasMouseInside = isMouseInside;
    isMouseInside = CGPathContainsPoint(circlePath, NULL, mouseLocation, false);

    if (wasMouseInside == isMouseInside) {
        return;
    }

    if (isMouseInside) {
        animateLayerOpacity(circleLayer, 0, 1, fadeAnimationDuration);
    } else {
        animateLayerOpacity(circleLayer, 1, 0, fadeAnimationDuration);
    }
}

- (void)setColorScheme:(NVColorScheme *)colorScheme {
    CGColorRelease(hoverColor);
    CGColorRelease(highlightColor);
    hoverColor = CGColorRetain(colorScheme.tabButtonHoverColor.CGColor);
    highlightColor = CGColorRetain(colorScheme.tabButtonHighlightColor.CGColor);
    imageView.contentTintColor = colorScheme.tabButtonColor;
}

@end

@interface NVTabCloseButton : NVTabButton
@end

@implementation NVTabCloseButton

- (instancetype)initWithColorscheme:(NVColorScheme *)colorScheme {
    self = [super initWithFrame:CGRectMake(0, 0, 14, 14)
                     symbolRect:CGRectMake(1, 1.5, 12, 12)
                     symbolName:@"xmark"
                   symbolWeight:NSFontWeightBold
                   fadeDuration:0
                    colorScheme:colorScheme];

    return self;
}

@end

@interface NVTabAddButton : NVTabButton
@end

@implementation NVTabAddButton

- (instancetype)initWithColorscheme:(NVColorScheme *)colorScheme {
    self = [super initWithFrame:CGRectMake(0, 3, 28, 28)
                     symbolRect:CGRectMake(5.5, 6.0, 17, 17)
                     symbolName:@"plus"
                   symbolWeight:NSFontWeightBold
                   fadeDuration:0.33
                    colorScheme:colorScheme];
    return self;
}

@end

@interface NVTabTitle : NSTextField
@end

@implementation NVTabTitle {
    CAGradientLayer *alphaMask;
    NSRect maxFrame;
    NSRect visualFrame;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    self.wantsLayer = YES;

    alphaMask = [CAGradientLayer layer];
    alphaMask.colors = @[(id)CGColorGetConstantColor(kCGColorBlack), (id)CGColorGetConstantColor(kCGColorClear)];
    alphaMask.anchorPoint = CGPointMake(0, 0);
    alphaMask.position = CGPointMake(0, 0);
    alphaMask.startPoint = CGPointMake(0, 0.5);
    alphaMask.endPoint = CGPointMake(1.0, 0.5);

    self.layer.mask = alphaMask;
    return self;
}

static NSArray* alphaMaskGradientLocations(CGFloat intrinsicWidth, CGFloat frameWidth) {
    CGFloat start = 1;
    CGFloat end = 1;

    if ((frameWidth - 8) <= intrinsicWidth) {
        CGFloat threeQuarterWidth = 0.75 * frameWidth;
        CGFloat gradientSize = MIN(threeQuarterWidth, 24);

        start = (frameWidth - gradientSize) / intrinsicWidth;
        end = frameWidth / intrinsicWidth;
    }

    return @[[NSNumber numberWithFloat:start], [NSNumber numberWithFloat:end]];
}

- (void)setFrame:(NSRect)frame {
    CGFloat intrinsicWidth = self.intrinsicContentSize.width + 4;

    maxFrame = frame;
    visualFrame = frame;
    visualFrame.size.width = MIN(frame.size.width, intrinsicWidth);

    NSRect adjustedFrame = frame;
    adjustedFrame.size.width = intrinsicWidth;

    [super setFrame:adjustedFrame];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    alphaMask.bounds = self.layer.bounds;
    alphaMask.locations = alphaMaskGradientLocations(intrinsicWidth, frame.size.width);
    [CATransaction commit];
}

- (void)setStringValue:(NSString *)stringValue {
    [super setStringValue:stringValue];
    [self setFrame:maxFrame];
}

- (NSRect)frame {
    return visualFrame;
}

- (void)animateSetWidth:(CGFloat)width
              beginTime:(CGFloat)beginTime
               duration:(CGFloat)duration
         timingFunction:(CAMediaTimingFunction *)timingFunction {
    CGFloat intrinsicWidth = self.intrinsicContentSize.width;
    NSArray *oldLocations = alphaMask.locations;
    NSArray *newLocations = alphaMaskGradientLocations(intrinsicWidth, width);

    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"locations"];
    animation.duration = duration;
    animation.fromValue = oldLocations;
    animation.toValue = newLocations;
    animation.beginTime = CACurrentMediaTime() + beginTime;
    animation.timingFunction = timingFunction;
    animation.fillMode = kCAFillModeBackwards;

    [alphaMask setLocations:newLocations];
    [alphaMask addAnimation:animation forKey:@"locations"];
}

@end

@interface NVTab()
@property (nonatomic) CALayer *leftSeparator;
@property (nonatomic) CALayer *rightSeparator;
@property (nonatomic) BOOL isSelected;
@property (nonatomic) BOOL isHighlighted;
@end

@implementation NVTab {
    NSTrackingArea *trackingArea;
    CALayer *background;
    CAShapeLayer *shapeLayer;
    CGColorRef selectColor;
    CGColorRef hoverColor;
    CALayer *iconLayer;
    NVTabTitle *titleLabel;
    NVTabCloseButton *closeButton;
    NVTabLine __unsafe_unretained *tabLine;
}

- (NVTabCloseButton*)tabCloseButton {
    return closeButton;
}

- (instancetype)initWithTitle:(NSString *)title
                     filetype:(NSString *)filetype
                      tabpage:(void *)tabpage
                      tabLine:(NVTabLine *)owner {
    self = [super init];
    self.wantsLayer = YES;

    tabLine = owner;
    _tabpage = tabpage;
    NVColorScheme *colorScheme = owner.colorScheme;

    iconLayer = [CALayer layer];
    iconLayer.anchorPoint = CGPointMake(0, 0);
    iconLayer.bounds = CGRectMake(0, 0, 16, 16);
    iconLayer.contentsGravity = kCAGravityLeft;
    iconLayer.masksToBounds = YES;
    [self setFiletype:filetype];

    titleLabel = [NVTabTitle labelWithString:title];
    titleLabel.textColor = colorScheme.tabTitleColor;

    closeButton = [[NVTabCloseButton alloc] initWithColorscheme:colorScheme];
    closeButton.action = @selector(onTabCloseButton:);
    closeButton.target = owner;

    [self addSubview:titleLabel];
    [self addSubview:closeButton];

    background = [CALayer layer];
    background.backgroundColor = colorScheme.tabBackgroundColor.CGColor;

    shapeLayer = [CAShapeLayer layer];
    shapeLayer.opacity = 0;
    selectColor = CGColorRetain(colorScheme.tabSelectedColor.CGColor);
    hoverColor = CGColorRetain(colorScheme.tabHoverColor.CGColor);

    CGRect separatorBounds = CGRectMake(0, 7, 1, owner.bounds.size.height - 22);

    _leftSeparator = [CALayer layer];
    _leftSeparator.backgroundColor = colorScheme.tabSeparatorColor.CGColor;
    _leftSeparator.anchorPoint = CGPointMake(0, 0);
    _leftSeparator.bounds = separatorBounds;

    _rightSeparator = [CALayer layer];
    _rightSeparator.backgroundColor = colorScheme.tabSeparatorColor.CGColor;
    _rightSeparator.anchorPoint = CGPointMake(0, 0);
    _rightSeparator.bounds = separatorBounds;

    CALayer *layer = self.layer;
    [layer setMasksToBounds:NO];
    [layer addSublayer:background];
    [layer addSublayer:shapeLayer];
    [layer addSublayer:iconLayer];

    return self;
}

- (void)dealloc {
    CGColorRelease(selectColor);
    CGColorRelease(hoverColor);
}

static NSImage* iconForFileType(NSString *filetype) {
    if (filetype && [filetype length]) {
        NSImage *icon = [NSImage imageNamed:filetype];

        if (icon) {
            return icon;
        }
    }

    return [NSImage imageNamed:@"vim"];
}

- (void)setColorScheme:(NVColorScheme *)colorScheme {
    CGColorRelease(selectColor);
    CGColorRelease(hoverColor);

    selectColor = CGColorRetain(colorScheme.tabSelectedColor.CGColor);
    hoverColor = CGColorRetain(colorScheme.tabHoverColor.CGColor);

    titleLabel.textColor = colorScheme.tabTitleColor;
    background.backgroundColor = colorScheme.tabBackgroundColor.CGColor;
    _leftSeparator.backgroundColor = colorScheme.tabSeparatorColor.CGColor;
    _rightSeparator.backgroundColor = colorScheme.tabSeparatorColor.CGColor;

    closeButton.colorScheme = colorScheme;

    if (_isSelected) {
        shapeLayer.fillColor = selectColor;
    } else if (_isHighlighted) {
        shapeLayer.fillColor = hoverColor;
    }
}

- (void)setTitle:(NSString *)title {
    titleLabel.stringValue = title;
}

- (void)setFiletype:(NSString *)filetype {
    NSImage *icon = iconForFileType(filetype);
    CGFloat iconScale = [icon recommendedLayerContentsScale:0];

    CGSize size = icon.size;

    if (size.width == size.height) {
        icon.size = CGSizeMake(16, 16);
    } else if (size.width < size.height) {
        icon.size = CGSizeMake(16 * (size.width / size.height), 16);
    } else {
        icon.size = CGSizeMake(16, 16 * (size.height / size.width));
    }

    iconLayer.contentsScale = iconScale;
    iconLayer.contents = [icon layerContentsForContentsScale:iconScale];
}

- (void)setIsSelected:(BOOL)isSelected {
    if (_isSelected == isSelected) {
        return;
    }

    _isSelected = isSelected;
    _isHighlighted = NO;
    [self layout];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    shapeLayer.opacity = isSelected ? 1 : 0;
    shapeLayer.fillColor = selectColor;

    if (!shapeLayer.path) {
        shapeLayer.path = NVTabFillPathCreate(self.bounds, 8);
    }

    [CATransaction commit];
}

- (CALayer*)backgroundLayer {
    return background;
}

- (NSView*)hitTest:(NSPoint)point {
    NSView *view = [super hitTest:point];

    if (view != self) {
        return view;
    }

    if (_isSelected) {
        CGPathRef shapePath = [shapeLayer path];
        NSPoint converted = [self convertPoint:point fromView:self.superview];

        if (CGPathContainsPoint(shapePath, NULL, converted, false)) {
            return self;
        }
    } else if (CGRectContainsPoint(CGRectInset(self.frame, 8, 0), point)) {
        return self;
    }

    return nil;
}

- (void)setIsHighlighted:(BOOL)isHighlighted {
    if (_isSelected || _isHighlighted == isHighlighted) {
        return;
    }

    _isHighlighted = isHighlighted;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (isHighlighted) {
        shapeLayer.fillColor = hoverColor;

        if (!shapeLayer.path) {
            shapeLayer.path = NVTabFillPathCreate(self.bounds, 8);
        }

        animateLayerOpacity(shapeLayer, 0, 1, 0.25);
    } else {
        animateLayerOpacity(shapeLayer, 1, 0, 0.33);
    }

    [CATransaction commit];
}

static CGPathRef NVTabFillPathCreate(NSRect bounds, CGFloat radius) {
    CGMutablePathRef path = CGPathCreateMutable();

    CGPathAddArc(path, NULL, 0, radius, radius, M_PI + M_PI_2, 0, false);
    CGPathAddLineToPoint(path, NULL, radius, bounds.size.height - radius);
    CGPathAddArc(path, NULL, radius * 2, bounds.size.height - radius, radius, M_PI, M_PI_2, true);
    CGPathAddLineToPoint(path, NULL, bounds.size.width - (radius * 2), bounds.size.height);
    CGPathAddArc(path, NULL, bounds.size.width - (radius * 2), bounds.size.height - radius, radius, M_PI_2, 0, true);
    CGPathAddLineToPoint(path, NULL, bounds.size.width - radius, radius);
    CGPathAddArc(path, NULL, bounds.size.width, radius, radius, M_PI, M_PI + M_PI_2, false);
    CGPathAddLineToPoint(path, NULL, 0, 0);

    return path;
}

typedef struct {
    NSRect iconFrame;
    NSRect titleFrame;
    NSRect closeButtonFrame;
} NVTabLayoutInfo;

static NVTabLayoutInfo tabLayoutInfo(NSRect frame, NSSize titleSize, bool isSelected) {
    NVTabLayoutInfo layoutInfo;
    layoutInfo.iconFrame.origin.y = (frame.size.height - 16) / 2;
    layoutInfo.iconFrame.size.height = 16;
    layoutInfo.titleFrame.origin.y = (frame.size.height - titleSize.height) / 2;
    layoutInfo.titleFrame.size.height = titleSize.height;
    layoutInfo.closeButtonFrame.origin.y = (frame.size.height - 14) / 2;
    layoutInfo.closeButtonFrame.size.height = 14;

    if (frame.size.width > 96) {
        layoutInfo.iconFrame.origin.x = 20;
        layoutInfo.iconFrame.size.width = 16;
        layoutInfo.titleFrame.origin.x = 40;
        layoutInfo.titleFrame.size.width = frame.size.width - 76;
        layoutInfo.closeButtonFrame.origin.x = frame.size.width - 32;
        layoutInfo.closeButtonFrame.size.width = 14;
    } else if (isSelected) {
        layoutInfo.iconFrame.origin.x = 12;
        layoutInfo.iconFrame.size.width = 0;
        layoutInfo.titleFrame.origin.x = 12;
        layoutInfo.closeButtonFrame.size.width = 14;

        if (frame.size.width > 48) {
            layoutInfo.titleFrame.size.width = frame.size.width - 44;
            layoutInfo.closeButtonFrame.origin.x = frame.size.width - 28;
        } else {
            layoutInfo.titleFrame.size.width = 0;
            layoutInfo.closeButtonFrame.origin.x = (frame.size.width - 14) / 2;
        }
    } else {
        layoutInfo.closeButtonFrame.origin.x = frame.size.width - 14;
        layoutInfo.closeButtonFrame.size.width = 0;

        if (frame.size.width > 48) {
            layoutInfo.iconFrame.origin.x = 16;
            layoutInfo.iconFrame.size.width = 16;
            layoutInfo.titleFrame.origin.x = 36;
            layoutInfo.titleFrame.size.width = MAX(frame.size.width - 52, 0);
        } else {
            layoutInfo.iconFrame.origin.x = 12;
            layoutInfo.iconFrame.size.width = frame.size.width - 28;
            layoutInfo.titleFrame.origin.x = 12;
            layoutInfo.titleFrame.size.width = 0;
        }
    }

    return layoutInfo;
}

- (void)layout {
    NSRect bounds = self.layer.bounds;
    NVTabLayoutInfo layout = tabLayoutInfo(bounds, titleLabel.intrinsicContentSize, _isSelected);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    background.frame = CGRectInset(bounds, 10, 0);

    if (_isSelected || _isHighlighted) {
        shapeLayer.path = NVTabFillPathCreate(bounds, 8);
    } else {
        shapeLayer.path = nil;
    }

    iconLayer.position = layout.iconFrame.origin;
    iconLayer.bounds = CGRectMake(0, 0, layout.iconFrame.size.width, layout.iconFrame.size.height);

    [CATransaction commit];

    titleLabel.frame = layout.titleFrame;
    closeButton.frame = layout.closeButtonFrame;
}

- (void)mouseDown:(NSEvent *)event {
    if (tabLine.tabs.count == 1) {
        return [[self window] performWindowDragWithEvent:event];
    }

    if (![tabLine.delegate tabLine:tabLine shouldSelectTab:self]) {
        return NSBeep();
    }

    tabLine.selectedTab = self;

    NSPoint dragOrigin = event.locationInWindow;
    NSEventMask eventMask = NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged;

    for (;;) {
        NSEvent *nextEvent = [self.window nextEventMatchingMask:eventMask];

        if (nextEvent.type == NSEventTypeLeftMouseUp) {
            return;
        }

        if (cgfloatDistance(dragOrigin, nextEvent.locationInWindow) >= 4) {
            return [tabLine performTabDragWithEvent:nextEvent tab:self];
        }
    }
}

- (NSRect)presentedFrame {
    CALayer *layer = [self layer];
    CALayer *presentedLayer = layer.presentationLayer;

    if (presentedLayer) {
        return presentedLayer.frame;
    }

    return self.frame;
}

- (void)animateSetWidth:(CGFloat)width
               duration:(CGFloat)duration
         timingFunction:(CAMediaTimingFunction *)timingFunction {
    CALayer *layer = self.layer;
    CALayer *titleLayer = titleLabel.layer;
    CALayer *buttonLayer = closeButton.layer;

    CGRect fromBounds = layer.bounds;
    CGRect toBounds = CGRectWithWidth(fromBounds, width);

    NVTabLayoutInfo newLayout = tabLayoutInfo(toBounds, titleLabel.intrinsicContentSize, _isSelected);
    CGFloat speed = fabs(fromBounds.size.width - width) / duration;

    CGRect  iconBoundsFromValue = iconLayer.bounds;
    CGFloat iconBoundsDuration = fabs(newLayout.iconFrame.size.width - iconBoundsFromValue.size.width) / speed;
    CGFloat iconBoundsBeginTime = 0;

    CGPoint iconPositionFromValue = iconLayer.position;
    CGFloat iconPositionDuration = fabs(newLayout.iconFrame.origin.x - iconPositionFromValue.x) / speed;
    CGFloat iconPositionBeginTime = 0;

    CGRect  titleFrame = titleLabel.frame;
    CGFloat titleBoundsDuration = fabs(newLayout.titleFrame.size.width - titleFrame.size.width) / speed;
    CGFloat titleBoundsBeginTime = 0;

    CGFloat titleDeltaX = newLayout.titleFrame.origin.x - titleFrame.origin.x;
    CGPoint titlePositionFromValue = titleLayer.position;
    CGPoint titlePositionToValue = CGPointMake(titlePositionFromValue.x + titleDeltaX, titlePositionFromValue.y);
    CGFloat titlePositionBeginTime = 0;
    CGFloat titlePositionDuration = fabs(titleDeltaX) / speed;

    CGRect  buttonFrame = closeButton.frame;
    CGRect  buttonBoundsFromValue = buttonLayer.bounds;
    CGRect  buttonBoundsToValue = CGRectWithWidth(buttonBoundsFromValue, newLayout.closeButtonFrame.size.width);
    CGFloat buttonBoundsBeginTime = 0;
    CGFloat buttonBoundsDuration = duration * 0.33;

    CGFloat buttonDeltaX = newLayout.closeButtonFrame.origin.x - buttonFrame.origin.x;
    CGPoint buttonPositionFromValue = buttonLayer.position;
    CGPoint buttonPositionToValue = CGPointMake(buttonPositionFromValue.x + buttonDeltaX, buttonPositionFromValue.y);
    CGFloat buttonPositionBeginTime = 0;
    CGFloat buttonPositionDuration = fabs(buttonDeltaX) / speed;

    if (fromBounds.size.width < width) {
        CGFloat delay = (72 - MIN(fromBounds.size.width, 72)) / speed;
        buttonPositionBeginTime = (40 - MIN(fromBounds.size.width, 40)) / speed;;
        iconPositionBeginTime = delay;
        iconBoundsBeginTime = delay + iconPositionDuration;
        titlePositionBeginTime = delay;
        titleBoundsBeginTime = delay + titlePositionDuration;
    } else {
        titlePositionBeginTime = titleBoundsDuration;
        iconBoundsBeginTime = titleBoundsDuration;
        iconPositionBeginTime = iconBoundsBeginTime + iconBoundsDuration;
    }

    CGFloat maxBeginTime = duration * 0.8;
    iconBoundsBeginTime = cgfloatClamp(iconBoundsBeginTime, 0, maxBeginTime);
    iconPositionBeginTime = cgfloatClamp(iconPositionBeginTime, 0, maxBeginTime);
    iconBoundsDuration = cgfloatClamp(iconBoundsDuration, 0, duration - iconBoundsBeginTime);
    iconPositionDuration = cgfloatClamp(iconPositionDuration, 0, duration - iconPositionBeginTime);

    titleBoundsBeginTime = cgfloatClamp(titleBoundsBeginTime, 0, maxBeginTime);
    titlePositionBeginTime = cgfloatClamp(titlePositionBeginTime, 0, maxBeginTime);
    titleBoundsDuration = cgfloatClamp(titleBoundsDuration, 0, duration - titleBoundsBeginTime);
    titlePositionDuration = cgfloatClamp(titlePositionDuration, 0, duration - titlePositionBeginTime);

    buttonBoundsBeginTime = cgfloatClamp(buttonBoundsBeginTime, 0, maxBeginTime);
    buttonPositionBeginTime = cgfloatClamp(buttonPositionBeginTime, 0, maxBeginTime);
    buttonBoundsDuration = cgfloatClamp(buttonBoundsDuration, 0, duration - buttonBoundsBeginTime);
    buttonPositionDuration = cgfloatClamp(buttonPositionDuration, 0, duration - buttonPositionBeginTime);

    animateLayerBounds(layer, fromBounds, toBounds, 0, duration, timingFunction);

    animateLayerBounds(buttonLayer, buttonBoundsFromValue, buttonBoundsToValue,
                       buttonBoundsBeginTime, buttonBoundsDuration, timingFunction);

    animateLayerPosition(buttonLayer, buttonPositionFromValue, buttonPositionToValue,
                         buttonPositionBeginTime, buttonPositionDuration, timingFunction);

    animateLayerBounds(iconLayer, iconBoundsFromValue, CGRectWithX(newLayout.iconFrame, 0),
                       iconBoundsBeginTime, iconBoundsDuration, timingFunction);

    animateLayerPosition(iconLayer, iconPositionFromValue, newLayout.iconFrame.origin,
                         iconPositionBeginTime, iconPositionDuration, timingFunction);

    [titleLabel animateSetWidth:newLayout.titleFrame.size.width
                      beginTime:titleBoundsBeginTime
                       duration:titleBoundsDuration
                 timingFunction:timingFunction];

    animateLayerPosition(titleLabel.layer, titlePositionFromValue, titlePositionToValue,
                         titlePositionBeginTime, titlePositionDuration, timingFunction);

    if (_isSelected || _isHighlighted) {
        animateLayerPath(shapeLayer, NVTabFillPathCreate(fromBounds, 8),
                         NVTabFillPathCreate(toBounds, 8), 0, duration, timingFunction);
    }
}

@end

@interface NVTabLineScrollView : NSScrollView
- (CGFloat)scrollTabLineWithEvent:(NSEvent *)event;
@end

@implementation NVTabLineScrollView

- (instancetype)init {
    self = [super init];
    self.wantsLayer = YES;
    self.drawsBackground = NO;
    self.contentInsets = NSEdgeInsetsMake(0, 0, 0, 0);
    self.borderType = NSNoBorder;
    self.hasVerticalScroller = NO;
    self.hasHorizontalScroller = NO;
    self.horizontalScrollElasticity = NSScrollElasticityAutomatic;
    self.verticalScrollElasticity = NSScrollElasticityNone;
    return self;
}

- (CGFloat)scrollHorizontallyBy:(CGFloat)deltaX {
    NSClipView *clipView = self.contentView;
    CGFloat documentWidth = self.documentView.frame.size.width;
    NSRect bounds = clipView.bounds;

    if (documentWidth <= bounds.size.width) {
        return 0;
    }

    CGFloat adjustedX = cgfloatClamp(bounds.origin.x - deltaX, 0, documentWidth - bounds.size.width);
    [clipView scrollToPoint:CGPointMake(adjustedX, 0)];
    return adjustedX - bounds.origin.x;
}

- (void)scrollWheel:(NSEvent *)event {
    if (![event hasPreciseScrollingDeltas]) {
        return [super scrollWheel:event];
    }

    CGFloat deltaX = [event deltaX];

    if (deltaX != 0) {
        [self scrollHorizontallyBy:deltaX];
    }
}

- (CGFloat)scrollTabLineWithEvent:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

    if (location.x < 64) {
        if (location.x < 32) {
            return [self scrollHorizontallyBy:2];
        } else {
            return [self scrollHorizontallyBy:1];
        }
    }

    CGFloat maxX = CGRectGetMaxX(self.bounds);

    if (location.x > maxX - 64) {
        if (location.x > maxX - 32) {
            return [self scrollHorizontallyBy:-2];
        } else {
            return [self scrollHorizontallyBy:-1];
        }
    }

    return 0;
}

@end

@implementation NVTabLine {
    NSTrackingArea *trackingArea;
    NVTabLineScrollView *scrollView;
    NVTabAddButton *tabAddButton;
    NSView *tabLine;
    NSMutableArray<NVTab*> *_tabs;
    NVTab *highlightedTab;
    int selectedTabIndex;
    BOOL inLiveLayout;

    NSMutableArray<void(^)(NVTabLine*)> *animationQueue;
    BOOL isAnimating;

    id<NVTabLineDelegate> __unsafe_unretained _delegate;
}

- (instancetype)initWithFrame:(NSRect)frame
                     delegate:(id<NVTabLineDelegate>)delegate
                  colorScheme:(NVColorScheme *)colorScheme {
    self = [super initWithFrame:frame];
    self.wantsLayer = YES;

    CALayer *layer = [self layer];
    layer.backgroundColor = colorScheme.tabBackgroundColor.CGColor;

    tabLine = [[NSView alloc] init];
    tabLine.wantsLayer = YES;

    CALayer *documentLayer = [tabLine layer];
    documentLayer.backgroundColor = colorScheme.tabBackgroundColor.CGColor;

    scrollView = [[NVTabLineScrollView alloc] init];
    scrollView.documentView = tabLine;;
    [scrollView setHasVerticalScroller:NO];
    [self addSubview:scrollView];

    tabAddButton = [[NVTabAddButton alloc] initWithColorscheme:colorScheme];
    tabAddButton.target = self;
    tabAddButton.action = @selector(onTabAddButton:);
    [self addSubview:tabAddButton];

    _colorScheme = colorScheme;
    _delegate = delegate;
    _tabs = [[NSMutableArray alloc] initWithCapacity:32];
    animationQueue = [[NSMutableArray alloc] initWithCapacity:8];

    return self;
}


- (void)updateTrackingAreas {
    [super updateTrackingAreas];

    if (trackingArea) {
        [self removeTrackingArea:trackingArea];
    }

    NSTrackingAreaOptions trackingOptions = NSTrackingMouseMoved
                                          | NSTrackingMouseEnteredAndExited
                                          | NSTrackingActiveInKeyWindow;

    trackingArea = [[NSTrackingArea alloc] initWithRect:CGRectInset(self.bounds, 8, 0)
                                                options:trackingOptions
                                                  owner:self
                                               userInfo:nil];

    [self addTrackingArea:trackingArea];
}

- (void)insertTab:(NVTab *)tab atIndex:(NSUInteger)index {
    [_tabs insertObject:tab atIndex:index];

    if (tab.superview == self) {
        return;
    }

    CALayer *documentLayer = [tabLine layer];
    [documentLayer addSublayer:tab.leftSeparator];
    [documentLayer addSublayer:tab.rightSeparator];
    [tabLine addSubview:tab];
}

- (void)setTabs:(NSArray<NVTab *> *)tabs {
    if ([_tabs isEqualToArray:tabs]) {
        return;
    }

    [_tabs removeAllObjects];
    size_t index = 0;

    for (NVTab *tab in tabs) {
        [self insertTab:tab atIndex:index];
        index += 1;
    }
}

- (NSArray<NVTab*>*)tabs {
    return _tabs;
}

static inline NVTab* tabHitTest(NSView *tabLine, NSPoint location) {
    NSView *view = [tabLine hitTest:location];
    Class nvTab = [NVTab class];

    while (view) {
        if ([view isKindOfClass:nvTab]) {
            return (NVTab*)view;
        }

        view = [view superview];

        if (view == tabLine) {
            return nil;
        }
    }

    return nil;
}

- (void)highlightTabAtLocation:(NSPoint)location {
    NVTab *tab = tabHitTest(tabLine, location);

    if (tab == highlightedTab) {
        return;
    }

    if (highlightedTab) {
        highlightedTab.isHighlighted = NO;
        highlightedTab = nil;
    }

    if (tab.isSelected) {
        return;
    }

    highlightedTab = tab;

    if (!tab) {
        return;
    }

    [tab removeFromSuperviewWithoutNeedingDisplay];
    [tabLine addSubview:tab positioned:NSWindowBelow relativeTo:_selectedTab];

    tab.isHighlighted = YES;
}

- (void)mouseMoved:(NSEvent *)event {
    if (inLiveLayout) {
        return;
    }

    NSPoint location = [tabLine.superview convertPoint:event.locationInWindow fromView:nil];
    [self highlightTabAtLocation:location];
}

- (void)updateHighlightedTab {
    NSPoint locationInWindow = [self.window mouseLocationOutsideOfEventStream];
    NSPoint location = [tabLine.superview convertPoint:locationInWindow fromView:nil];
    [self highlightTabAtLocation:location];
}

- (void)setSelectedTab:(NVTab *)selectedTab {
    if (_selectedTab == selectedTab) {
        return;
    }

    selectedTabIndex = (int)[_tabs indexOfObject:selectedTab];
    _selectedTab.isSelected = NO;
    _selectedTab = selectedTab;

    [selectedTab setIsSelected:YES];
    [selectedTab removeFromSuperviewWithoutNeedingDisplay];
    [tabLine addSubview:selectedTab positioned:NSWindowAbove relativeTo:nil];
}

- (void)mouseEntered:(NSEvent *)event {
    [self mouseMoved:event];
}

- (void)mouseExited:(NSEvent *)event {
    if (highlightedTab) {
        highlightedTab.isHighlighted = NO;
        highlightedTab = nil;
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint location = [tabLine.superview convertPoint:event.locationInWindow fromView:nil];
    NSView *view = [tabLine hitTest:location];

    if (view && view != tabLine) {
        return [view mouseDown:event];
    }

    [[self window] performWindowDragWithEvent:event];
}

- (void)setColorScheme:(NVColorScheme *)colorScheme {
    _colorScheme = colorScheme;

    self.layer.backgroundColor = colorScheme.tabBackgroundColor.CGColor;
    tabLine.layer.backgroundColor = colorScheme.tabBackgroundColor.CGColor;
    tabAddButton.colorScheme = colorScheme;

    for (NVTab *tab in _tabs) {
        tab.colorScheme = colorScheme;
    }
}

- (void)onTabAddButton:(id)sender {
    [_delegate tabLineAddNewTab:self];
}

- (void)onTabCloseButton:(id)sender {
    NVTab *tab = (NVTab*)[(NVTabAddButton*)sender superview];
    [_delegate tabLine:self closeTab:tab];
}

typedef struct {
    CGRect scrollViewFrame;
    CGRect documentViewFrame;
    CGFloat tabAddButtonX;
    CGFloat tabsTotalWidth;
    CGFloat tabWidth;
    CGFloat tabHeight;
} NVTabLineLayoutInfo;

typedef struct {
    NSRect tabFrame;
    CGPoint leftSeparatorPosition;
    CGPoint rightSeparatorPosition;
} NVTabPositionInfo;

static NVTabPositionInfo tabPositionInfo(NVTabLineLayoutInfo *layoutInfo, unsigned long index) {
    NVTabPositionInfo tabLayoutInfo;

    int position = (int)index;
    CGFloat originX = (layoutInfo->tabWidth - 18) * position;

    tabLayoutInfo.tabFrame.origin.x = originX;
    tabLayoutInfo.tabFrame.origin.y = 0;
    tabLayoutInfo.tabFrame.size.height = layoutInfo->tabHeight;
    tabLayoutInfo.tabFrame.size.width = layoutInfo->tabWidth;

    tabLayoutInfo.rightSeparatorPosition.x = originX + layoutInfo->tabWidth - 10;
    tabLayoutInfo.rightSeparatorPosition.y = 7;

    if (position == 0) {
        tabLayoutInfo.leftSeparatorPosition = tabLayoutInfo.rightSeparatorPosition;
    } else {
        tabLayoutInfo.leftSeparatorPosition.x = originX + 8;
        tabLayoutInfo.leftSeparatorPosition.y = 7;
    }

    return tabLayoutInfo;
}

static NVTabLineLayoutInfo tabLineLayoutInfo(NSRect bounds, unsigned long tabCount) {
    CGFloat tabLineWidth = bounds.size.width - 170;

    NVTabLineLayoutInfo layoutInfo;
    layoutInfo.scrollViewFrame.origin.x = 85;
    layoutInfo.scrollViewFrame.origin.y = 0;
    layoutInfo.scrollViewFrame.size.width = tabLineWidth;
    layoutInfo.scrollViewFrame.size.height = bounds.size.height;

    CGFloat tabLineSpace = bounds.size.width - (85 * 2) - 18;
    layoutInfo.tabWidth = cgfloatClamp((tabLineSpace / tabCount) + 18, 34, 256);
    layoutInfo.tabHeight = bounds.size.height - 8;

    CGFloat tabsWidth = ((layoutInfo.tabWidth - 18) * tabCount) + 18;
    layoutInfo.documentViewFrame.origin.x = 0;
    layoutInfo.documentViewFrame.origin.y = 0;
    layoutInfo.documentViewFrame.size.width = MAX(tabsWidth, tabLineWidth);
    layoutInfo.documentViewFrame.size.height = bounds.size.height;
    layoutInfo.tabsTotalWidth = tabsWidth;

    CGFloat tabAddButtonMaxX = bounds.size.width - 85;
    CGFloat tabAddButtonX = tabsWidth + 85;
    layoutInfo.tabAddButtonX = MIN(tabAddButtonX, tabAddButtonMaxX);

    return layoutInfo;
}

static void translateSeparator(CALayer *layer,
                               CGPoint position,
                               CGFloat duration,
                               CAMediaTimingFunction *timingFunction) {
    [layer removeAnimationForKey:@"position"];
    layer.position = position;

    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"position"];
    CALayer *presentedLayer = [layer presentationLayer];

    if (!presentedLayer) {
        presentedLayer = layer;
    }

    animation.duration = duration;
    animation.fromValue = [presentedLayer valueForKey:@"position"];
    animation.toValue = [NSValue valueWithPoint:position];
    animation.timingFunction = timingFunction;

    [layer addAnimation:animation forKey:@"position"];
}

static void translateTab(NVTab *tab,
                         NVTabPositionInfo *from,
                         NVTabPositionInfo *to,
                         CGFloat duration,
                         NVTabAddButton *addButton) {
    CGPoint toOrigin = to->tabFrame.origin;
    CGFloat fromX = from->tabFrame.origin.x;

    CGPoint currentOrigin = tab.presentedFrame.origin;
    CGFloat adjustedDuration = fabs((currentOrigin.x - toOrigin.x) / (fromX - toOrigin.x)) * duration;

    [NSAnimationContext beginGrouping];
    NSAnimationContext *currentContext = [NSAnimationContext currentContext];
    CAMediaTimingFunction *timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];

    [currentContext setTimingFunction:timingFunction];
    [currentContext setDuration:adjustedDuration];
    [tab.animator setFrameOrigin:toOrigin];

    if (addButton) {
        NSPoint origin = addButton.frame.origin;
        origin.x = CGRectGetMaxX(to->tabFrame) + 85;
        addButton.animator.frameOrigin = origin;
    }

    [NSAnimationContext endGrouping];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    translateSeparator(tab.leftSeparator, to->leftSeparatorPosition, adjustedDuration, timingFunction);
    translateSeparator(tab.rightSeparator, to->rightSeparatorPosition, adjustedDuration, timingFunction);
    [CATransaction commit];
}

- (void)tabLayoutInfo:(NVTabLineLayoutInfo *)layoutInfo
           didDragTab:(NVTab *)tab
              atIndex:(int)oldIndex
              toIndex:(int)newIndex
      adjustAddButton:(bool)adjustAddButton {
    selectedTabIndex = newIndex;

    int begin;
    int end;
    int delta;

    if (oldIndex < newIndex) {
        begin = oldIndex + 1;
        end = newIndex + 1;
        delta = -1;
    } else {
        begin = newIndex;
        end = oldIndex;
        delta = 1;
    }

    for (int i=begin; i<end; ++i) {
        int newIndex = i + delta;
        bool shouldMoveAddButton = adjustAddButton && newIndex == (_tabs.count - 1);

        NVTabPositionInfo from = tabPositionInfo(layoutInfo, i);
        NVTabPositionInfo to = tabPositionInfo(layoutInfo, newIndex);
        translateTab(_tabs[i], &from, &to, 0.25, shouldMoveAddButton ? tabAddButton : nil);
    }

    [_tabs removeObjectAtIndex:oldIndex];
    [_tabs insertObject:tab atIndex:newIndex];
}

- (void)performTabDragWithEvent:(NSEvent *)event tab:(NVTab *)tab; {
    inLiveLayout = YES;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    tab.leftSeparator.position = CGPointMake(-10, -10);
    tab.rightSeparator.position = CGPointMake(-10, -10);
    [CATransaction commit];

    NVTabLineLayoutInfo layoutInfo = tabLineLayoutInfo(self.bounds, _tabs.count);
    NSRect tabFrame = [tab frame];

    int fromIndex = selectedTabIndex;
    int tabIndex = fromIndex;
    int maxIndex = (int)_tabs.count - 1;

    CGFloat dragOriginX = [tab convertPoint:event.locationInWindow fromView:nil].x;
    NSEventMask eventMask = NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged;

    CGFloat tabWidth = layoutInfo.tabWidth - 18;
    CGFloat tabHalfWidth = tabWidth / 2;
    CGFloat maxX = tabLine.bounds.size.width - layoutInfo.tabWidth;
    bool shouldAdjustAddButton = layoutInfo.tabsTotalWidth <= layoutInfo.scrollViewFrame.size.width;

    for (;;) {
        NSEvent *nextEvent = [self.window nextEventMatchingMask:eventMask
                                                      untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
                                                         inMode:NSEventTrackingRunLoopMode
                                                        dequeue:YES];

        CGFloat deltaX = 0;

        if (nextEvent) {
            if (nextEvent.type == NSEventTypeLeftMouseUp) {
                break;
            }

            deltaX = [tab convertPoint:nextEvent.locationInWindow fromView:nil].x - dragOriginX;
            event = nextEvent;
        }

        if (!shouldAdjustAddButton) {
            deltaX += [scrollView scrollTabLineWithEvent:event];
        }

        tabFrame.origin.x = cgfloatClamp(tabFrame.origin.x + deltaX, 0, maxX);
        tab.frame = tabFrame;

        int position = (tabFrame.origin.x + tabHalfWidth) / tabWidth;
        int newIndex = MIN(position, maxIndex);

        if (!shouldAdjustAddButton) {
            [scrollView.contentView scrollRectToVisible:tabFrame];
        } else if (newIndex == maxIndex) {
            NSPoint origin = tabAddButton.frame.origin;
            origin.x = tabFrame.origin.x + tabFrame.size.width + 85;
            tabAddButton.frameOrigin = origin;
        }

        if (newIndex != tabIndex) {
            [self tabLayoutInfo:&layoutInfo
                     didDragTab:tab
                        atIndex:tabIndex
                        toIndex:newIndex
                adjustAddButton:shouldAdjustAddButton];
            tabIndex = newIndex;
        }
    }

    selectedTabIndex = tabIndex;
    [self animateLayout];

    [_delegate tabLine:self didMoveTab:tab fromIndex:fromIndex toIndex:tabIndex];
}

- (void)layout {
    if (inLiveLayout) {
        return;
    }

    NVTabLineLayoutInfo layoutInfo = tabLineLayoutInfo(self.bounds, _tabs.count);
    scrollView.frame = layoutInfo.scrollViewFrame;
    tabLine.frame = layoutInfo.documentViewFrame;

    int tabIndex = 0;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    for (NVTab *tab in _tabs) {
        NVTabPositionInfo tabLayout = tabPositionInfo(&layoutInfo, tabIndex);

        tab.frame = tabLayout.tabFrame;
        tab.leftSeparator.position = tabLayout.leftSeparatorPosition;
        tab.rightSeparator.position = tabLayout.rightSeparatorPosition;

        tabIndex += 1;
    }

    NSRect tabAddButtonRect = tabAddButton.frame;
    tabAddButtonRect.origin.x = layoutInfo.tabAddButtonX;
    tabAddButton.frame = tabAddButtonRect;

    [CATransaction commit];
}

static NSMutableArray<CALayer*>* tabsBackgroundLayers(NSArray<NVTab*> *tabs) {
    NSMutableArray<CALayer*> *backgrounds = [NSMutableArray arrayWithCapacity:tabs.count * 2];

    for (NVTab *tab in tabs) {
        [backgrounds addObject:tab.backgroundLayer];
    }

    return backgrounds;
}

static void layersSetHidden(NSArray<CALayer*> *layers, bool hidden, bool newTransaction) {
    if (newTransaction) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
    }

    for (CALayer *layer in layers) {
        layer.hidden = hidden;
    }

    if (newTransaction) {
        [CATransaction commit];
    }
}

- (void)animateLayoutWithInfo:(NVTabLineLayoutInfo *)layoutInfo
                     duration:(CGFloat)duration
               timingFunction:(CAMediaTimingFunction *)timingFunction {
    int tabIndex = 0;

    for (NVTab *tab in _tabs) {
        NVTabPositionInfo newPosition = tabPositionInfo(layoutInfo, tabIndex);
        NSRect tabFrame = tab.frame;

        if (tabFrame.size.width != newPosition.tabFrame.size.width) {
            [tab animateSetWidth:newPosition.tabFrame.size.width duration:duration timingFunction:timingFunction];
        }

        if (tabFrame.origin.x != newPosition.tabFrame.origin.x) {
            CALayer *tabLayer = tab.layer;
            CGFloat deltaX = newPosition.tabFrame.origin.x - tabFrame.origin.x;
            CGPoint fromPosition = tabLayer.position;
            CGPoint toPosition = CGPointMake(fromPosition.x + deltaX, fromPosition.y);
            animateLayerPosition(tabLayer, fromPosition, toPosition, 0, duration, timingFunction);
        }

        tab.frame = newPosition.tabFrame;

        translateSeparator(tab.leftSeparator, newPosition.leftSeparatorPosition, duration, timingFunction);
        translateSeparator(tab.rightSeparator, newPosition.rightSeparatorPosition, duration, timingFunction);

        tabIndex += 1;
    }

    NSRect addButtonFrame = tabAddButton.frame;

    if (addButtonFrame.origin.x != layoutInfo->tabAddButtonX) {
        [tabAddButton animateSetFrameOrigin:CGPointMake(layoutInfo->tabAddButtonX, addButtonFrame.origin.y)
                                   duration:duration
                             timingFunction:timingFunction];
    }
}

- (void)queueAnimation:(void(^)(NVTabLine*))animationHandler {
    if (isAnimating) {
        [animationQueue addObject:animationHandler];
    } else {
        isAnimating = YES;
        animationHandler(self);
    }
}

- (void)didFinishAnimation {
    if ([animationQueue count] == 0) {
        isAnimating = NO;
    } else {
        void(^nextAnimation)(NVTabLine*) = [animationQueue firstObject];
        [animationQueue removeObjectAtIndex:0];
        nextAnimation(self);
    }
}

- (id<NVTabLineDelegate>)delegate {
    return _delegate;
}

- (void)cancelAllAnimations {
    [animationQueue removeAllObjects];
}

- (void)animateLayout {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    [CATransaction setCompletionBlock:^{
        [self layout];
        [self didFinishAnimation];
    }];

    NVTabLineLayoutInfo layoutInfo = tabLineLayoutInfo(self.bounds, _tabs.count);
    [self animateLayoutWithInfo:&layoutInfo
                       duration:0.33
                 timingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];

    [CATransaction commit];
}

- (void)animateCloseTab:(NVTab *)tab
               duration:(CGFloat)duration
         timingFunction:(CAMediaTimingFunction *)timingFunction {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    NSArray<CALayer*> *tabBackgrounds = tabsBackgroundLayers(_tabs);
    layersSetHidden(tabBackgrounds, true, false);

    unsigned long index = [_tabs indexOfObject:tab];
    [_tabs removeObjectAtIndex:index];

    unsigned long tabsCount = _tabs.count;
    NVTabLineLayoutInfo layoutInfo = tabLineLayoutInfo(self.bounds, tabsCount);

    [CATransaction setCompletionBlock:^{
        layersSetHidden(tabBackgrounds, false, true);
        [tab removeFromSuperview];
        [self layout];

        [self updateHighlightedTab];
        [self didFinishAnimation];
    }];

    [tab.leftSeparator removeFromSuperlayer];
    [tab.rightSeparator removeFromSuperlayer];
    [tab animateSetWidth:24 duration:duration timingFunction:timingFunction];

    if (index != 0) {
        CGRect tabFrame = tab.frame;
        CGRect previousTabFrame = tabPositionInfo(&layoutInfo, index).tabFrame;

        if (tabFrame.origin.x != previousTabFrame.origin.x) {
            CALayer *tabLayer = tab.layer;
            CGFloat deltaX = previousTabFrame.origin.x - tabFrame.origin.x;
            CGPoint fromPosition = tabLayer.position;
            CGPoint toPosition = CGPointMake(fromPosition.x + deltaX, fromPosition.y);
            animateLayerPosition(tab.layer, fromPosition, toPosition, 0, duration, timingFunction);
        }
    }

    [self animateLayoutWithInfo:&layoutInfo duration:duration timingFunction:timingFunction];
    [CATransaction commit];
}

- (void)closeTab:(NVTab *)tab {
    [_tabs removeObjectIdenticalTo:tab];
    [tab.leftSeparator removeFromSuperlayer];
    [tab.rightSeparator removeFromSuperlayer];
    [tab removeFromSuperview];
}

- (void)animateCloseTab:(NVTab *)tab {
    [self queueAnimation:^(NVTabLine *tabLine) {
        [tabLine animateCloseTab:tab
                        duration:0.2
                  timingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn]];
    }];
}

- (void)animateAddTab:(NVTab *)tab
              atIndex:(NSUInteger)index
           isSelected:(BOOL)isSelected
             duration:(CGFloat)duration
       timingFunction:(CAMediaTimingFunction *)timingFunction {
    unsigned long tabCount = [_tabs count];
    [self insertTab:tab atIndex:index];

    NVTabLineLayoutInfo layoutInfo = tabLineLayoutInfo(self.bounds, tabCount + 1);

    NSRect tabFrame = CGRectMake(0, 0, 24, layoutInfo.tabHeight);
    NSMutableArray<CALayer*> *layers = tabsBackgroundLayers(_tabs);
    [layers addObject:tab.leftSeparator];
    [layers addObject:tab.rightSeparator];

    if (index == 0) {
        [layers addObject:_tabs[1].leftSeparator];
    } else if (index == tabCount) {
        tabFrame.origin.x = CGRectGetMaxX(_tabs[index - 1].frame) - 22;
    } else {
        tabFrame.origin.x = _tabs[index + 1].frame.origin.x - 4;
    }

    [tab setFrame:tabFrame];
    [tab layout];

    if (isSelected) {
        [self setSelectedTab:tab];
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    layersSetHidden(layers, true, false);

    [CATransaction setCompletionBlock:^{
        layersSetHidden(layers, false, true);
        [self layout];
        [self updateHighlightedTab];
        [self didFinishAnimation];
    }];

    [self animateLayoutWithInfo:&layoutInfo duration:duration timingFunction:timingFunction];
    [CATransaction commit];
}

- (void)animateAddTab:(NVTab *)tab atIndex:(NSUInteger)index isSelected:(BOOL)isSelected {
    [self queueAnimation:^(NVTabLine *tabLine) {
        if ([tabLine->_tabs count] == 0) {
            [tabLine setTabs:@[tab]];
            [tabLine layout];
            [tabLine didFinishAnimation];
            return;
        }
        
        [self animateAddTab:tab
                    atIndex:index
                 isSelected:isSelected
                   duration:0.2
             timingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
    }];
}

- (void)animateSetTabs:(NSArray<NVTab*> *)tabs selectedTab:(NVTab *)tab {
    NSArray<NVTab*> *tabsCopy = [tabs copy];

    [self queueAnimation:^(NVTabLine *tabLine) {
        if ([tabLine->_tabs isEqualToArray:tabsCopy]) {
            [tabLine setSelectedTab:tab];
            [tabLine didFinishAnimation];
        } else {
            [tabLine setTabs:tabsCopy];
            [tabLine setSelectedTab:tab];
            [tabLine animateLayout];
        }
    }];
}

@end
