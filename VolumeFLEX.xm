#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <notify.h>
#import <objc/runtime.h>
#import <rootless.h>

static NSString *gFlexDylibPath = nil;
static char kVFLongPressCopyGestureKey;

@interface FLEXManager : NSObject
+ (instancetype)sharedManager;
- (void)showExplorer;
@end

@interface SBApplication
- (NSString *)bundleIdentifier;
@end

@interface SpringBoard
- (SBApplication *)_accessibilityFrontMostApplication;
@end

@interface UITableViewCell (VolumeFLEXCopy)
- (void)vf_installLongPressCopyGestureIfNeeded;
- (void)vf_copyFLEXText:(UILongPressGestureRecognizer *)gesture;
@end

static BOOL VFClassNameIsFLEX(Class cls) {
    return [NSStringFromClass(cls) hasPrefix:@"FLEX"];
}

static BOOL VFViewBelongsToFLEX(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if (VFClassNameIsFLEX(candidate.class)) {
            return YES;
        }
    }

    UIResponder *responder = view.nextResponder;
    while (responder) {
        if (VFClassNameIsFLEX(responder.class)) {
            return YES;
        }
        responder = responder.nextResponder;
    }

    return NO;
}

static UILabel *VFLabelFromView(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) {
        return (UILabel *)view;
    }

    for (UIView *subview in view.subviews) {
        UILabel *label = VFLabelFromView(subview);
        if (label.text.length > 0) {
            return label;
        }
    }

    return nil;
}

%group SpringBoardHooks

%hook SpringBoard

- (BOOL)_handlePhysicalButtonEvent:(UIPressesEvent *)event {
    BOOL upPressed = NO;
    BOOL downPressed = NO;

    for (UIPress *press in event.allPresses.allObjects) {
        if (press.type == 102 && press.force == 1) {
            upPressed = YES;
        }
        if (press.type == 103 && press.force == 1) {
            downPressed = YES;
        }
#if TARGET_IPHONE_SIMULATOR
        if (press.type == 2227 && press.force == 1) {
            upPressed = YES;
        }
        if (press.type == 2231 && press.force == 1) {
            downPressed = YES;
        }
#endif
    }

    if (upPressed && downPressed) {
        SBApplication *frontMostApp =
            [(SpringBoard *)UIApplication.sharedApplication _accessibilityFrontMostApplication];

        if (frontMostApp) {
            notify_post(
                [[NSString stringWithFormat:@"com.joshua.volumeflex/%@", frontMostApp.bundleIdentifier] UTF8String]);
        } else {
            dlopen([gFlexDylibPath UTF8String], RTLD_NOW);
            [[objc_getClass("FLEXManager") sharedManager] showExplorer];
        }
    }

    return %orig;
}

%end

%end

%group CopyHooks

%hook UITableViewCell

%new
- (void)vf_installLongPressCopyGestureIfNeeded {
    if (!self.window || !VFViewBelongsToFLEX(self)) {
        return;
    }

    UILongPressGestureRecognizer *gesture = objc_getAssociatedObject(self, &kVFLongPressCopyGestureKey);
    if (!gesture) {
        gesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(vf_copyFLEXText:)];
        gesture.minimumPressDuration = 0.5;
        gesture.cancelsTouchesInView = YES;
        gesture.delaysTouchesBegan = YES;
        [self addGestureRecognizer:gesture];
        objc_setAssociatedObject(self, &kVFLongPressCopyGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)didMoveToWindow {
    %orig;
    [self vf_installLongPressCopyGestureIfNeeded];
}

- (void)layoutSubviews {
    %orig;
    [self vf_installLongPressCopyGestureIfNeeded];
}

%new
- (void)vf_copyFLEXText:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }

    NSString *text = nil;
    UIView *hitView = [self hitTest:[gesture locationInView:self] withEvent:nil];
    UILabel *label = VFLabelFromView(hitView);
    if (label.text.length > 0) {
        text = label.text;
    } else if (self.textLabel.text.length > 0) {
        text = self.textLabel.text;
    } else if (self.detailTextLabel.text.length > 0) {
        text = self.detailTextLabel.text;
    }

    if (text.length > 0) {
        UIPasteboard.generalPasteboard.string = text;
        AudioServicesPlaySystemSound(1519);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            AudioServicesPlaySystemSound(1519);
        });
    }
}

%end

%end

%ctor {
#if TARGET_IPHONE_SIMULATOR
    gFlexDylibPath = @"/opt/simject/libVolumeFLEX.dylib";
#else
    gFlexDylibPath = ROOT_PATH_NS(@"/usr/lib/libVolumeFLEX.dylib");
#endif

    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    %init(CopyHooks);

    if ([bid isEqualToString:@"com.apple.springboard"]) {
        %init(SpringBoardHooks);
    } else if (bid.length > 0) {
        int regToken;
        NSString *notifForBundle = [NSString stringWithFormat:@"com.joshua.volumeflex/%@", bid];
        notify_register_dispatch(notifForBundle.UTF8String, &regToken, dispatch_get_main_queue(), ^(int token) {
            dlopen(gFlexDylibPath.UTF8String, RTLD_NOW);
            [[objc_getClass("FLEXManager") sharedManager] showExplorer];
        });
    }
}
