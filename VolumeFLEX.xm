#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <rootless.h>

static NSString *gFlexDylibPath = nil;
static NSHashTable *gVFWindowsWithGestures = nil;
static char kVFLongPressCopyGestureKey;

#define kVFStatusBarLongPressGesture 0xdeadbabe

@interface FLEXManager : NSObject
+ (instancetype)sharedManager;
- (void)showExplorer;
@end

@interface UIStatusBarWindow : UIWindow
@end

@interface UIStatusBarTapAction : NSObject
@property (nonatomic, readonly) NSInteger type;
@end

@interface SBMainDisplaySceneLayoutStatusBarView : UIView
- (void)_statusBarTapped:(id)sender type:(NSInteger)type;
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

static void VFShowExplorer(void) {
    dlopen(gFlexDylibPath.UTF8String, RTLD_NOW);
    [[objc_getClass("FLEXManager") sharedManager] showExplorer];
}


%group SpringBoardStatusBarHooks

%hook SBMainDisplaySceneLayoutStatusBarView

- (void)_addStatusBarIfNeeded {
    %orig;

    UIView *statusBar = [self valueForKey:@"_statusBar"];
    [statusBar addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(vf_statusBarLongPressed:)]];
}

%new
- (void)vf_statusBarLongPressed:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        [self _statusBarTapped:recognizer type:kVFStatusBarLongPressGesture];
    }
}

%end

%end

%group ActivationGestureHooks

%hook UIStatusBarManager

- (void)handleTapAction:(UIStatusBarTapAction *)action {
    if (action.type == kVFStatusBarLongPressGesture) {
        VFShowExplorer();
    } else {
        %orig(action);
    }
}

%end

%hook UIWindow

%new
- (void)vf_showExplorerFromGesture:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        VFShowExplorer();
    }
}

- (void)becomeKeyWindow {
    %orig;

    if (!gVFWindowsWithGestures) {
        gVFWindowsWithGestures = [NSHashTable weakObjectsHashTable];
    }

    BOOL needsGesture = ![gVFWindowsWithGestures containsObject:self];
    BOOL isFLEXWindow = VFClassNameIsFLEX(self.class);
    BOOL isStatusBar = [self isKindOfClass:[UIStatusBarWindow class]];
    if (needsGesture && !isFLEXWindow && !isStatusBar) {
        [gVFWindowsWithGestures addObject:self];

        UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(vf_showExplorerFromGesture:)];
        gesture.minimumPressDuration = 0.5;
        gesture.numberOfTouchesRequired = 3;
        [self addGestureRecognizer:gesture];
    }
}

%end

%hook UIStatusBarWindow

- (id)initWithFrame:(CGRect)frame {
    self = %orig;
    [self addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(vf_showExplorerFromGesture:)]];
    return self;
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

    if (bid.length > 0) {
        %init(ActivationGestureHooks);
    }

    if ([bid isEqualToString:@"com.apple.springboard"]) {
        %init(SpringBoardStatusBarHooks);
    }
}
