//
//  Neovim Mac
//  NVTabLine.h
//
//  Copyright © 2022 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import <Cocoa/Cocoa.h>
#import "NVColorScheme.h"

NS_ASSUME_NONNULL_BEGIN

@class NVTab;
@class NVTabLine;

/// NVTabLine Delegate. Forwards events originating from GUI elements.
@protocol NVTabLineDelegate

/// Called when the user clicks the new tab button.
- (void)tabLineAddNewTab:(NVTabLine *)tabLine;

/// Called when the user closes a tab.
- (void)tabLine:(NVTabLine *)tabLine closeTab:(NVTab *)tab;

/// Called when the user clicks on a tab.
- (BOOL)tabLine:(NVTabLine *)tabLine shouldSelectTab:(NVTab *)tab;

/// Called when the user rearranges tabs.
/// @param tabLine      The tabLine.
/// @param tab          The tab that was moved.
/// @param fromIndex    The original position of tab.
/// @param toIndex      The new  position of tab.
/// Note: Only the currently selected tab can be moved.
- (void)tabLine:(NVTabLine *)tabLine
     didMoveTab:(NVTab *)tab
      fromIndex:(NSUInteger)fromIndex
        toIndex:(NSUInteger)toIndex;

@end

/// Represents an externalized Neovim tabpage.
@interface NVTab : NSView

/// Create a new tab.
/// @param title    The tab title.
/// @param filetype The filetype of the current buffer. Used for icons.
/// @param tabpage  Opaque pointer to the corresponding nvim::tabpage.
/// @param tabLine  The tabLine that will own this tab.
- (instancetype)initWithTitle:(NSString *)title
                     filetype:(NSString *)filetype
                      tabpage:(void *)tabpage
                      tabLine:(NVTabLine *)tabLine;

/// Opaque pointer to the corresponding nvim::tabpage.
@property (nonatomic, readonly) void *tabpage;

/// Set the tab title.
- (void)setTitle:(NSString *)title;

/// Set the tab filetype. Used for the tab icon.
- (void)setFiletype:(NSString *)filetype;

@end

/// Represents an externalized Neovim tabline.
@interface NVTabLine : NSView

/// Create a new tabline.
/// @param frame        The tabline frame.
/// @param delegate     The tabline delegate.
/// @param colorScheme  The colorscheme.
- (instancetype)initWithFrame:(NSRect)frame
                     delegate:(id<NVTabLineDelegate>)delegate
                  colorScheme:(NVColorScheme *)colorScheme;

/// The tabline theme.
@property (nonatomic) NVColorScheme *colorScheme;

/// The currently selected tab.
@property (nonatomic) NVTab *selectedTab;

/// Boolean indicating whether the tabline is currently shown or not.
@property (nonatomic) BOOL isShown;

/// Set the tabs in the tabline.
- (void)setTabs:(NSArray<NVTab*> *)tabs;

/// Get the tabs in the tabline. Not this returns an internal pointer which may mutate.
- (NSArray<NVTab*>*)tabs;

/// Cancel all pending animations.
- (void)cancelAllAnimations;

/// Close the given tab.
- (void)closeTab:(NVTab *)tab;

/// Add a new tab. Animated.
/// @param tab          The tab to add to the tabline.
/// @param index        The position of the new tab.
/// @param isSelected   A boolean indicating whether the new tab is selected or not.
- (void)animateAddTab:(NVTab *)tab atIndex:(NSUInteger)index isSelected:(BOOL)isSelected;

/// Close the given tab. Animated.
- (void)animateCloseTab:(NVTab *)tab;

/// Set the tabs array and the selected tab. Animated.
- (void)animateSetTabs:(NSArray<NVTab*> *)tabs selectedTab:(NVTab *)tab;

@end

NS_ASSUME_NONNULL_END
