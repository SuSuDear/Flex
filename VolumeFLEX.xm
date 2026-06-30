#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <rootless.h>

static NSString *gFlexDylibPath = nil;
static NSHashTable *gVFWindowsWithGestures = nil;
static char kVFLongPressCopyGestureKey;
static char kVFExportActionAddedKey;

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

@interface FLEXObjectExplorerViewController : UIViewController
@property (nonatomic, readonly) id object;
@property (nonatomic, readonly) id explorer;
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

static UIViewController *VFTopViewControllerFrom(UIViewController *controller) {
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }

    if ([controller isKindOfClass:UINavigationController.class]) {
        return VFTopViewControllerFrom([(UINavigationController *)controller topViewController]);
    }

    if ([controller isKindOfClass:UITabBarController.class]) {
        return VFTopViewControllerFrom([(UITabBarController *)controller selectedViewController]);
    }

    return controller;
}

static UIViewController *VFTopViewController(void) {
    UIWindow *keyWindow = UIApplication.sharedApplication.keyWindow;
    if (!keyWindow) {
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }
    }

    return VFTopViewControllerFrom(keyWindow.rootViewController);
}

static UIViewController *VFObjectExplorerViewControllerForAlert(UIAlertController *alert) {
    UIViewController *controller = alert.presentingViewController ?: VFTopViewController();
    while (controller) {
        if ([NSStringFromClass(controller.class) isEqualToString:@"FLEXObjectExplorerViewController"]) {
            return controller;
        }

        if ([controller isKindOfClass:UINavigationController.class]) {
            UIViewController *top = [(UINavigationController *)controller topViewController];
            if ([NSStringFromClass(top.class) isEqualToString:@"FLEXObjectExplorerViewController"]) {
                return top;
            }
        }

        controller = controller.presentingViewController;
    }

    return nil;
}

static NSString *VFSafeString(id value) {
    if (!value || value == NSNull.null) {
        return @"";
    }

    @try {
        return [value description] ?: @"";
    } @catch (__unused NSException *exception) {
        return @"<description unavailable>";
    }
}

static id VFCall(id target, SEL selector) {
    if (!target || ![target respondsToSelector:selector]) {
        return nil;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [target performSelector:selector];
#pragma clang diagnostic pop
}

static void VFAppendMetadataItems(NSMutableString *output, NSString *title, NSArray *items) {
    [output appendFormat:@"\n## %@ (%lu)\n", title, (unsigned long)items.count];

    if (items.count == 0) {
        [output appendString:@"(none)\n"];
        return;
    }

    for (id item in items) {
        NSString *name = VFSafeString(VFCall(item, @selector(name)) ?: VFCall(item, @selector(selectorString)));
        NSString *detail = VFSafeString(
            VFCall(item, @selector(fullDescription)) ?:
            VFCall(item, @selector(details)) ?:
            VFCall(item, @selector(description))
        );

        if (name.length > 0 && detail.length > 0 && ![detail isEqualToString:name]) {
            [output appendFormat:@"%@\n  %@\n", name, detail];
        } else if (detail.length > 0) {
            [output appendFormat:@"%@\n", detail];
        } else if (name.length > 0) {
            [output appendFormat:@"%@\n", name];
        }
    }
}

static NSString *VFSafeFileName(NSString *name) {
    NSMutableCharacterSet *invalid = [NSMutableCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>"];
    [invalid formUnionWithCharacterSet:NSCharacterSet.newlineCharacterSet];
    NSArray *parts = [name componentsSeparatedByCharactersInSet:invalid];
    NSString *safe = [parts componentsJoinedByString:@"_"];
    return safe.length > 0 ? safe : @"FLEXObject";
}

static NSString *VFExportCurrentClassInfo(UIViewController *controller, NSError **error) {
    id explorer = VFCall(controller, @selector(explorer));
    if (!explorer) {
        if (error) {
            *error = [NSError errorWithDomain:@"VolumeFLEXExport" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Cannot find FLEX explorer for current screen."}];
        }
        return nil;
    }

    id object = VFCall(explorer, @selector(object)) ?: VFCall(controller, @selector(object));
    NSString *objectName = NSStringFromClass(object_getClass(object));
    if (object && object == object_getClass(object)) {
        objectName = NSStringFromClass((Class)object);
    }

    NSMutableString *output = [NSMutableString string];
    [output appendFormat:@"FLEX Class Export\n"];
    [output appendFormat:@"Object: %@\n", VFSafeString(object)];
    [output appendFormat:@"Class: %@\n", objectName ?: @"(unknown)"];
    [output appendFormat:@"Exported At: %@\n", NSDate.date];

    NSString *objectDescription = VFSafeString(VFCall(explorer, @selector(objectDescription)));
    if (objectDescription.length > 0) {
        [output appendFormat:@"\n## Description\n%@\n", objectDescription];
    }

    VFAppendMetadataItems(output, @"Properties", VFCall(explorer, @selector(properties)) ?: @[]);
    VFAppendMetadataItems(output, @"Class Properties", VFCall(explorer, @selector(classProperties)) ?: @[]);
    VFAppendMetadataItems(output, @"Ivars", VFCall(explorer, @selector(ivars)) ?: @[]);
    VFAppendMetadataItems(output, @"Methods", VFCall(explorer, @selector(methods)) ?: @[]);
    VFAppendMetadataItems(output, @"Class Methods", VFCall(explorer, @selector(classMethods)) ?: @[]);
    VFAppendMetadataItems(output, @"Protocols", VFCall(explorer, @selector(conformedProtocols)) ?: @[]);
    VFAppendMetadataItems(output, @"Class Hierarchy", VFCall(explorer, @selector(classHierarchy)) ?: @[]);

    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"VolumeFLEXExports"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *fileName = [NSString stringWithFormat:@"%@-%@.txt", VFSafeFileName(objectName), @((long long)(NSDate.date.timeIntervalSince1970))];
    NSString *path = [directory stringByAppendingPathComponent:fileName];
    if (![output writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error]) {
        return nil;
    }

    return path;
}

static void VFShareExportedFile(UIViewController *presenter, NSString *path, NSError *error) {
    if (!path) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Export Failed" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSURL *fileURL = [NSURL fileURLWithPath:path];
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
    if (activity.popoverPresentationController) {
        activity.popoverPresentationController.sourceView = presenter.view;
        activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
        activity.popoverPresentationController.permittedArrowDirections = 0;
    }
    [presenter presentViewController:activity animated:YES completion:nil];
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


%group ExportHooks

%hook UIAlertController

- (void)addAction:(UIAlertAction *)action {
    %orig;

    if (objc_getAssociatedObject(self, &kVFExportActionAddedKey)) {
        return;
    }

    if (![action.title isEqualToString:@"Copy Address"]) {
        return;
    }

    BOOL hasBookmarkAction = NO;
    BOOL hasCopyDescriptionAction = NO;
    for (UIAlertAction *existingAction in self.actions) {
        hasBookmarkAction = hasBookmarkAction || [existingAction.title isEqualToString:@"Add to Bookmarks"];
        hasCopyDescriptionAction = hasCopyDescriptionAction || [existingAction.title isEqualToString:@"Copy Description"];
    }

    if (!hasBookmarkAction || !hasCopyDescriptionAction) {
        return;
    }

    __weak UIAlertController *weakAlert = self;
    UIAlertAction *exportAction = [UIAlertAction actionWithTitle:@"Export Class Info TXT" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *selectedAction) {
        UIAlertController *alert = weakAlert;
        UIViewController *explorerController = VFObjectExplorerViewControllerForAlert(alert);
        UIViewController *presenter = explorerController ?: VFTopViewController();
        NSError *error = nil;
        NSString *path = VFExportCurrentClassInfo(explorerController, &error);
        VFShareExportedFile(presenter, path, error);
    }];

    objc_setAssociatedObject(self, &kVFExportActionAddedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self addAction:exportAction];
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
    %init(ExportHooks);

    if (bid.length > 0) {
        %init(ActivationGestureHooks);
    }

    if ([bid isEqualToString:@"com.apple.springboard"]) {
        %init(SpringBoardStatusBarHooks);
    }
}
