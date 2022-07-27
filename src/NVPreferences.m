//
//  Neovim Mac
//  NVPreferences.m
//
//  Copyright © 2022 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import "NVPreferences.h"

static NSString * const kTitlebarAppearsTransparent = @"NVPreferencesTitlebarAppearsTransparent";
static NSString * const kExternalizeTabline = @"NVPreferencesExternalizeTabline";

static BOOL getBooleanPreference(NSString *key, BOOL defaultValue) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSNumber *value = [defaults objectForKey:key];

    if (!value || ![value isKindOfClass:[NSNumber class]]) {
        return defaultValue;
    }

    return [value boolValue];
}

static void setBooleanPreference(NSString *key, BOOL value) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:[NSNumber numberWithBool:value] forKey:key];
}

@implementation NVPreferences

+ (BOOL)titlebarAppearsTransparent {
    return getBooleanPreference(kTitlebarAppearsTransparent, YES);
}

+ (BOOL)externalizeTabline {
    return getBooleanPreference(kExternalizeTabline, YES);
}

@end

@interface NVPreferencesController()
@property (nonatomic) IBOutlet NSButton *titlebarTransparentCheckbox;
@property (nonatomic) IBOutlet NSButton *externalTablineCheckbox;
@end

@implementation NVPreferencesController {
    BOOL wasShown;
}

- (instancetype)init {
    self = [super initWithWindowNibName:@"Preferences"];
    return self;
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];

    if (!wasShown) {
        [self.window center];
        wasShown = YES;
    }
}

- (void)windowDidLoad {
    [super windowDidLoad];

    _titlebarTransparentCheckbox.state = [NVPreferences titlebarAppearsTransparent] ? NSControlStateValueOn : NSControlStateValueOff;
    _externalTablineCheckbox.state = [NVPreferences externalizeTabline] ? NSControlStateValueOn : NSControlStateValueOff;
}

static BOOL getCheckboxValue(NSButton *button) {
    NSControlStateValue state = [button state];

    if (state == NSControlStateValueOff) {
        return NO;
    } else {
        return YES;
    }
}

- (IBAction)toggledTitlebarAppearsTransparent:(NSButton *)sender {
    setBooleanPreference(kTitlebarAppearsTransparent, getCheckboxValue(sender));
}

- (IBAction)toggledExternalizeTabline:(NSButton *)sender {
    setBooleanPreference(kExternalizeTabline, getCheckboxValue(sender));
}

@end
