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

static NSString *VFCStringToString(const char *value) {
    return value ? [NSString stringWithUTF8String:value] ?: @"" : @"";
}

static NSString *VFTypeName(const char *type) {
    NSString *encoding = VFCStringToString(type);
    if (encoding.length == 0) {
        return @"";
    }

    NSDictionary *knownTypes = @{
        @"c": @"char / BOOL", @"i": @"int", @"s": @"short", @"l": @"long", @"q": @"long long",
        @"C": @"unsigned char", @"I": @"unsigned int", @"S": @"unsigned short", @"L": @"unsigned long", @"Q": @"unsigned long long",
        @"f": @"float", @"d": @"double", @"B": @"bool", @"v": @"void", @"*": @"char *", @"@": @"id",
        @"#": @"Class", @":": @"SEL"
    };

    NSString *known = knownTypes[encoding];
    if (known.length > 0) {
        return known;
    }

    if ([encoding hasPrefix:@"@\""] && [encoding hasSuffix:@"\""]) {
        return [encoding substringWithRange:NSMakeRange(2, encoding.length - 3)];
    }

    if ([encoding hasPrefix:@"^"]) {
        return [NSString stringWithFormat:@"pointer to %@", VFTypeName(type + 1)];
    }

    return encoding;
}

static NSString *VFImplementationImage(IMP implementation) {
    if (!implementation) {
        return @"";
    }

    Dl_info info;
    if (dladdr((const void *)implementation, &info) && info.dli_fname) {
        NSString *image = VFCStringToString(info.dli_fname);
        NSString *symbol = VFCStringToString(info.dli_sname);
        if (symbol.length > 0) {
            return [NSString stringWithFormat:@"%@ (%@)", image, symbol];
        }
        return image;
    }

    return @"";
}

static BOOL VFIsClassObject(id object) {
    return object && class_isMetaClass(object_getClass(object));
}

static NSString *VFValueForProperty(id object, objc_property_t property) {
    if (!object || VFIsClassObject(object)) {
        return @"";
    }

    const char *propertyName = property_getName(property);
    if (!propertyName) {
        return @"";
    }

    NSString *name = VFCStringToString(propertyName);
    @try {
        id value = [object valueForKey:name];
        return VFSafeString(value);
    } @catch (__unused NSException *exception) {
        return @"<unavailable>";
    }
}

static NSString *VFValueForIvar(id object, Ivar ivar) {
    if (!object || VFIsClassObject(object)) {
        return @"";
    }

    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') {
        return @"<non-object>";
    }

    @try {
        id value = object_getIvar(object, ivar);
        return VFSafeString(value);
    } @catch (__unused NSException *exception) {
        return @"<unavailable>";
    }
}

static void VFAppendPropertyList(NSMutableString *output, Class cls, id object, BOOL classProperties) {
    unsigned int count = 0;
    Class targetClass = classProperties ? object_getClass(cls) : cls;
    objc_property_t *properties = class_copyPropertyList(targetClass, &count);
    [output appendFormat:@"\n### %@ (%u)\n", classProperties ? @"Class Properties" : @"Properties", count];

    if (count == 0) {
        [output appendString:@"(none)\n"];
        free(properties);
        return;
    }

    for (unsigned int index = 0; index < count; index++) {
        objc_property_t property = properties[index];
        NSString *name = VFCStringToString(property_getName(property));
        NSString *attributes = VFCStringToString(property_getAttributes(property));
        NSString *value = classProperties ? @"" : VFValueForProperty(object, property);

        [output appendFormat:@"- %@\n", name.length ? name : @"(unknown)"];
        if (attributes.length > 0) {
            [output appendFormat:@"  attributes: %@\n", attributes];
        }
        if (value.length > 0) {
            [output appendFormat:@"  value: %@\n", value];
        }
    }

    free(properties);
}

static void VFAppendIvarList(NSMutableString *output, Class cls, id object) {
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    [output appendFormat:@"\n### Ivars (%u)\n", count];

    if (count == 0) {
        [output appendString:@"(none)\n"];
        free(ivars);
        return;
    }

    for (unsigned int index = 0; index < count; index++) {
        Ivar ivar = ivars[index];
        const char *type = ivar_getTypeEncoding(ivar);
        NSString *name = VFCStringToString(ivar_getName(ivar));
        NSString *encoding = VFCStringToString(type);
        NSString *value = VFValueForIvar(object, ivar);

        [output appendFormat:@"- %@\n", name.length ? name : @"(unknown)"];
        [output appendFormat:@"  type: %@\n", VFTypeName(type)];
        [output appendFormat:@"  encoding: %@\n", encoding];
        [output appendFormat:@"  offset: %td\n", ivar_getOffset(ivar)];
        if (value.length > 0) {
            [output appendFormat:@"  value: %@\n", value];
        }
    }

    free(ivars);
}

static void VFAppendMethodList(NSMutableString *output, Class cls, BOOL classMethods) {
    unsigned int count = 0;
    Class targetClass = classMethods ? object_getClass(cls) : cls;
    Method *methods = class_copyMethodList(targetClass, &count);
    [output appendFormat:@"\n### %@ (%u)\n", classMethods ? @"Class Methods" : @"Methods", count];

    if (count == 0) {
        [output appendString:@"(none)\n"];
        free(methods);
        return;
    }

    NSString *className = NSStringFromClass(cls);
    for (unsigned int index = 0; index < count; index++) {
        Method method = methods[index];
        SEL selector = method_getName(method);
        IMP implementation = method_getImplementation(method);
        unsigned int argumentCount = method_getNumberOfArguments(method);
        char *returnType = method_copyReturnType(method);
        const char *typeEncoding = method_getTypeEncoding(method);

        [output appendFormat:@"- %@[%@ %@]\n", classMethods ? @"+" : @"-", className, NSStringFromSelector(selector)];
        [output appendFormat:@"  selector: %@\n", NSStringFromSelector(selector)];
        [output appendFormat:@"  return: %@ (%@)\n", VFTypeName(returnType), VFCStringToString(returnType)];
        [output appendFormat:@"  arguments: %u\n", argumentCount];
        for (unsigned int argumentIndex = 0; argumentIndex < argumentCount; argumentIndex++) {
            char *argumentType = method_copyArgumentType(method, argumentIndex);
            NSString *argumentName = argumentIndex == 0 ? @"self" : (argumentIndex == 1 ? @"_cmd" : [NSString stringWithFormat:@"arg%u", argumentIndex - 2]);
            [output appendFormat:@"    %@: %@ (%@)\n", argumentName, VFTypeName(argumentType), VFCStringToString(argumentType)];
            free(argumentType);
        }
        [output appendFormat:@"  typeEncoding: %@\n", VFCStringToString(typeEncoding)];
        [output appendFormat:@"  imp: %p\n", implementation];
        NSString *image = VFImplementationImage(implementation);
        if (image.length > 0) {
            [output appendFormat:@"  image: %@\n", image];
        }

        free(returnType);
    }

    free(methods);
}

static void VFAppendProtocolList(NSMutableString *output, Class cls) {
    unsigned int count = 0;
    Protocol *__unsafe_unretained *protocols = class_copyProtocolList(cls, &count);
    [output appendFormat:@"\n### Protocols (%u)\n", count];

    if (count == 0) {
        [output appendString:@"(none)\n"];
        free(protocols);
        return;
    }

    for (unsigned int index = 0; index < count; index++) {
        [output appendFormat:@"- %@\n", VFCStringToString(protocol_getName(protocols[index]))];
    }

    free(protocols);
}

static NSArray<Class> *VFClassHierarchy(Class cls) {
    NSMutableArray<Class> *classes = [NSMutableArray array];
    for (Class candidate = cls; candidate; candidate = class_getSuperclass(candidate)) {
        [classes addObject:candidate];
    }
    return classes;
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
    Class cls = VFIsClassObject(object) ? (Class)object : object_getClass(object);
    NSString *className = NSStringFromClass(cls);
    NSString *originalClassName = [className hasPrefix:@"NSKVONotifying_"] ? [className substringFromIndex:@"NSKVONotifying_".length] : @"";

    NSMutableString *output = [NSMutableString string];
    [output appendString:@"# FLEX Enhanced Class Export\n\n"];
    [output appendFormat:@"Object: %@\n", VFSafeString(object)];
    [output appendFormat:@"Object Address: %p\n", object];
    [output appendFormat:@"Class: %@\n", className ?: @"(unknown)"];
    if (originalClassName.length > 0) {
        [output appendFormat:@"KVO Original Class: %@\n", originalClassName];
    }
    [output appendFormat:@"Superclass: %@\n", NSStringFromClass(class_getSuperclass(cls)) ?: @"(none)"];
    [output appendFormat:@"Metaclass: %@\n", NSStringFromClass(object_getClass(cls)) ?: @"(unknown)"];
    [output appendFormat:@"Instance Size: %zu\n", class_getInstanceSize(cls)];
    [output appendFormat:@"Exported At: %@\n", NSDate.date];

    NSString *objectDescription = VFSafeString(VFCall(explorer, @selector(objectDescription)) ?: object);
    if (objectDescription.length > 0) {
        [output appendFormat:@"\n## Description\n%@\n", objectDescription];
    }

    NSArray<Class> *hierarchy = VFClassHierarchy(cls);
    [output appendString:@"\n## Class Hierarchy\n"];
    for (Class hierarchyClass in hierarchy) {
        [output appendFormat:@"- %@\n", NSStringFromClass(hierarchyClass)];
    }

    for (Class hierarchyClass in hierarchy) {
        [output appendFormat:@"\n\n## %@\n", NSStringFromClass(hierarchyClass)];
        [output appendFormat:@"Superclass: %@\n", NSStringFromClass(class_getSuperclass(hierarchyClass)) ?: @"(none)"];
        [output appendFormat:@"Instance Size: %zu\n", class_getInstanceSize(hierarchyClass)];
        VFAppendPropertyList(output, hierarchyClass, object, NO);
        VFAppendPropertyList(output, hierarchyClass, object, YES);
        VFAppendIvarList(output, hierarchyClass, object);
        VFAppendMethodList(output, hierarchyClass, NO);
        VFAppendMethodList(output, hierarchyClass, YES);
        VFAppendProtocolList(output, hierarchyClass);
    }

    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"VolumeFLEXExports"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *fileName = [NSString stringWithFormat:@"%@-%@.txt", VFSafeFileName(className), @((long long)(NSDate.date.timeIntervalSince1970))];
    NSString *path = [directory stringByAppendingPathComponent:fileName];
    if (![output writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error]) {
        return nil;
    }

    return path;
}


static NSString *VFShellQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSString *VFFrameString(CGRect rect) {
    return NSStringFromCGRect(rect);
}

static NSString *VFPointString(CGPoint point) {
    return NSStringFromCGPoint(point);
}

static NSString *VFSizeString(CGSize size) {
    return NSStringFromCGSize(size);
}

static id VFKVCValue(id object, NSString *key) {
    if (!object || key.length == 0) {
        return nil;
    }

    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void VFAppendLine(NSMutableString *output, NSString *key, id value) {
    NSString *string = VFSafeString(value);
    if (string.length > 0) {
        [output appendFormat:@"%@: %@\n", key, string];
    }
}

static void VFAppendKVCSection(NSMutableString *output, id object, NSString *title, NSArray<NSString *> *keys) {
    [output appendFormat:@"\n## %@\n", title];
    BOOL hasValue = NO;
    for (NSString *key in keys) {
        id value = VFKVCValue(object, key);
        if (value) {
            hasValue = YES;
            [output appendFormat:@"%@: %@\n", key, VFSafeString(value)];
        }
    }
    if (!hasValue) {
        [output appendString:@"(none)\n"];
    }
}

static void VFAppendObjectIvars(NSMutableString *output, id object, NSUInteger limit) {
    if (!object || VFIsClassObject(object)) {
        return;
    }

    [output appendString:@"\n## Runtime Ivars\n"];
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(object), &count);
    if (count == 0) {
        [output appendString:@"(none)\n"];
        free(ivars);
        return;
    }

    unsigned int cappedCount = (unsigned int)MIN((NSUInteger)count, limit);
    for (unsigned int index = 0; index < cappedCount; index++) {
        Ivar ivar = ivars[index];
        NSString *name = VFCStringToString(ivar_getName(ivar));
        NSString *encoding = VFCStringToString(ivar_getTypeEncoding(ivar));
        NSString *value = VFValueForIvar(object, ivar);
        [output appendFormat:@"- %@\n  encoding: %@\n  offset: %td\n", name, encoding, ivar_getOffset(ivar)];
        if (value.length > 0) {
            [output appendFormat:@"  value: %@\n", value];
        }
    }
    if (count > cappedCount) {
        [output appendFormat:@"... truncated %u ivars\n", count - cappedCount];
    }
    free(ivars);
}

static void VFAppendObjectProperties(NSMutableString *output, id object, NSUInteger limit) {
    if (!object || VFIsClassObject(object)) {
        return;
    }

    [output appendString:@"\n## Runtime Properties\n"];
    unsigned int count = 0;
    objc_property_t *properties = class_copyPropertyList(object_getClass(object), &count);
    if (count == 0) {
        [output appendString:@"(none)\n"];
        free(properties);
        return;
    }

    unsigned int cappedCount = (unsigned int)MIN((NSUInteger)count, limit);
    for (unsigned int index = 0; index < cappedCount; index++) {
        objc_property_t property = properties[index];
        NSString *name = VFCStringToString(property_getName(property));
        NSString *attributes = VFCStringToString(property_getAttributes(property));
        NSString *value = VFValueForProperty(object, property);
        [output appendFormat:@"- %@\n  attributes: %@\n", name, attributes];
        if (value.length > 0) {
            [output appendFormat:@"  value: %@\n", value];
        }
    }
    if (count > cappedCount) {
        [output appendFormat:@"... truncated %u properties\n", count - cappedCount];
    }
    free(properties);
}

static void VFAppendLayerSnapshot(NSMutableString *output, CALayer *layer) {
    if (!layer) {
        return;
    }

    [output appendString:@"\n## Layer\n"];
    [output appendFormat:@"class: %@\n", NSStringFromClass(layer.class)];
    [output appendFormat:@"address: %p\n", layer];
    [output appendFormat:@"frame: %@\n", VFFrameString(layer.frame)];
    [output appendFormat:@"bounds: %@\n", VFFrameString(layer.bounds)];
    [output appendFormat:@"position: %@\n", VFPointString(layer.position)];
    [output appendFormat:@"anchorPoint: %@\n", VFPointString(layer.anchorPoint)];
    [output appendFormat:@"opacity: %g\n", layer.opacity];
    [output appendFormat:@"hidden: %@\n", layer.hidden ? @"YES" : @"NO"];
    [output appendFormat:@"masksToBounds: %@\n", layer.masksToBounds ? @"YES" : @"NO"];
    [output appendFormat:@"cornerRadius: %g\n", layer.cornerRadius];
    [output appendFormat:@"borderWidth: %g\n", layer.borderWidth];
    [output appendFormat:@"shadowOpacity: %g\n", layer.shadowOpacity];
    [output appendFormat:@"shadowRadius: %g\n", layer.shadowRadius];
    [output appendFormat:@"shadowOffset: %@\n", VFSizeString(layer.shadowOffset)];
    VFAppendLine(output, @"compositingFilter", layer.compositingFilter);
    VFAppendLine(output, @"filters", layer.filters);
    VFAppendLine(output, @"backgroundFilters", layer.backgroundFilters);
    [output appendFormat:@"sublayersCount: %lu\n", (unsigned long)layer.sublayers.count];
}

static void VFAppendViewSnapshot(NSMutableString *output, UIView *view) {
    [output appendString:@"\n## UIView\n"];
    [output appendFormat:@"frame: %@\n", VFFrameString(view.frame)];
    [output appendFormat:@"bounds: %@\n", VFFrameString(view.bounds)];
    [output appendFormat:@"center: %@\n", VFPointString(view.center)];
    [output appendFormat:@"alpha: %g\n", view.alpha];
    [output appendFormat:@"hidden: %@\n", view.hidden ? @"YES" : @"NO"];
    [output appendFormat:@"opaque: %@\n", view.opaque ? @"YES" : @"NO"];
    [output appendFormat:@"clipsToBounds: %@\n", view.clipsToBounds ? @"YES" : @"NO"];
    [output appendFormat:@"userInteractionEnabled: %@\n", view.userInteractionEnabled ? @"YES" : @"NO"];
    [output appendFormat:@"contentMode: %ld\n", (long)view.contentMode];
    VFAppendLine(output, @"backgroundColor", view.backgroundColor);
    VFAppendLine(output, @"tintColor", view.tintColor);
    [output appendFormat:@"subviewsCount: %lu\n", (unsigned long)view.subviews.count];
    VFAppendLayerSnapshot(output, view.layer);
}

static void VFAppendVisualEffectSnapshot(NSMutableString *output, UIVisualEffectView *view) {
    [output appendString:@"\n## UIVisualEffectView\n"];
    VFAppendLine(output, @"effect", view.effect);
    if (view.effect) {
        [output appendFormat:@"effectClass: %@\n", NSStringFromClass(view.effect.class)];
        VFAppendKVCSection(output, view.effect, @"Effect Private Keys", @[@"style", @"_style", @"_settings", @"settings", @"effectSettings", @"_effectSettings"]);
        VFAppendObjectIvars(output, view.effect, 80);
    }
    VFAppendLine(output, @"contentView", view.contentView);
    VFAppendKVCSection(output, view, @"Visual Effect Private Keys", @[@"_effect", @"_effectConfig", @"_effectSettings", @"_backdropView", @"backdropView", @"_backdropViewSettings", @"_contentView", @"_backgroundView"]);
}

static NSString *VFFileNameForSnapshotNode(NSUInteger index, NSString *path, id object) {
    NSString *className = NSStringFromClass([object class]) ?: @"Object";
    NSString *pathPart = [[path stringByReplacingOccurrencesOfString:@"." withString:@"_"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [NSString stringWithFormat:@"%04lu_%@_%@.txt", (unsigned long)index, pathPart.length ? pathPart : @"root", VFSafeFileName(className)];
}

static NSString *VFWriteSnapshotNode(id object, NSString *path, NSUInteger depth, NSString *directory, NSMutableArray<NSString *> *indexLines, NSUInteger *counter);

static void VFWriteSnapshotChildren(UIView *view, NSString *path, NSUInteger depth, NSString *directory, NSMutableArray<NSString *> *indexLines, NSUInteger *counter) {
    if (depth >= 4) {
        return;
    }

    NSUInteger childIndex = 0;
    for (UIView *subview in view.subviews) {
        if (childIndex >= 50) {
            [indexLines addObject:[NSString stringWithFormat:@"%@/... truncated subviews: %lu", path, (unsigned long)(view.subviews.count - childIndex)]];
            break;
        }
        NSString *childPath = [NSString stringWithFormat:@"%@.%lu", path, (unsigned long)childIndex];
        VFWriteSnapshotNode(subview, childPath, depth + 1, directory, indexLines, counter);
        childIndex++;
    }
}

static NSString *VFWriteSnapshotNode(id object, NSString *path, NSUInteger depth, NSString *directory, NSMutableArray<NSString *> *indexLines, NSUInteger *counter) {
    NSUInteger index = (*counter)++;
    NSString *fileName = VFFileNameForSnapshotNode(index, path, object);
    NSString *filePath = [directory stringByAppendingPathComponent:fileName];

    NSMutableString *output = [NSMutableString string];
    [output appendString:@"# FLEX Object Snapshot Node\n\n"];
    [output appendFormat:@"path: %@\n", path];
    [output appendFormat:@"depth: %lu\n", (unsigned long)depth];
    [output appendFormat:@"class: %@\n", NSStringFromClass([object class])];
    [output appendFormat:@"address: %p\n", object];
    [output appendFormat:@"description: %@\n", VFSafeString(object)];

    if ([object isKindOfClass:UIView.class]) {
        UIView *view = (UIView *)object;
        VFAppendViewSnapshot(output, view);
        if ([view isKindOfClass:UIVisualEffectView.class]) {
            VFAppendVisualEffectSnapshot(output, (UIVisualEffectView *)view);
        }
        VFAppendObjectProperties(output, view, 120);
        VFAppendObjectIvars(output, view, 120);
        VFWriteSnapshotChildren(view, path, depth, directory, indexLines, counter);
    } else if ([object isKindOfClass:CALayer.class]) {
        VFAppendLayerSnapshot(output, (CALayer *)object);
        VFAppendObjectProperties(output, object, 120);
        VFAppendObjectIvars(output, object, 120);
    } else {
        VFAppendObjectProperties(output, object, 120);
        VFAppendObjectIvars(output, object, 120);
    }

    [output writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [indexLines addObject:[NSString stringWithFormat:@"%@ -> %@ (%@ %p)", path, fileName, NSStringFromClass([object class]), object]];
    return filePath;
}

static NSString *VFExportObjectSnapshotZIP(UIViewController *controller, NSError **error) {
    id explorer = VFCall(controller, @selector(explorer));
    id object = VFCall(explorer, @selector(object)) ?: VFCall(controller, @selector(object));
    if (!object) {
        if (error) {
            *error = [NSError errorWithDomain:@"VolumeFLEXExport" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Cannot find current object."}];
        }
        return nil;
    }

    NSString *className = NSStringFromClass([object class]) ?: @"Object";
    NSString *baseDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"VolumeFLEXExports"];
    [NSFileManager.defaultManager createDirectoryAtPath:baseDirectory withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *exportName = [NSString stringWithFormat:@"%@-Snapshot-%@", VFSafeFileName(className), @((long long)(NSDate.date.timeIntervalSince1970))];
    NSString *directory = [baseDirectory stringByAppendingPathComponent:exportName];
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }

    NSMutableArray<NSString *> *indexLines = [NSMutableArray array];
    [indexLines addObject:@"# FLEX Object Snapshot ZIP Index"];
    [indexLines addObject:[NSString stringWithFormat:@"rootClass: %@", className]];
    [indexLines addObject:[NSString stringWithFormat:@"rootAddress: %p", object]];
    [indexLines addObject:[NSString stringWithFormat:@"exportedAt: %@", NSDate.date]];
    [indexLines addObject:@""];

    NSUInteger counter = 0;
    VFWriteSnapshotNode(object, @"root", 0, directory, indexLines, &counter);
    [[indexLines componentsJoinedByString:@"\n"] writeToFile:[directory stringByAppendingPathComponent:@"index.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSString *zipPath = [baseDirectory stringByAppendingPathComponent:[exportName stringByAppendingPathExtension:@"zip"]];
    [NSFileManager.defaultManager removeItemAtPath:zipPath error:nil];
    NSString *command = [NSString stringWithFormat:@"cd %@ && /usr/bin/zip -qry %@ %@", VFShellQuote(baseDirectory), VFShellQuote(zipPath), VFShellQuote(exportName)];
    int result = system(command.UTF8String);
    if (result != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"VolumeFLEXExport" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Failed to create ZIP archive."}];
        }
        return nil;
    }

    return zipPath;
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

    UIAlertAction *snapshotAction = [UIAlertAction actionWithTitle:@"Export Object Snapshot ZIP" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *selectedAction) {
        UIAlertController *alert = weakAlert;
        UIViewController *explorerController = VFObjectExplorerViewControllerForAlert(alert);
        UIViewController *presenter = explorerController ?: VFTopViewController();
        NSError *error = nil;
        NSString *path = VFExportObjectSnapshotZIP(explorerController, &error);
        VFShareExportedFile(presenter, path, error);
    }];

    objc_setAssociatedObject(self, &kVFExportActionAddedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self addAction:exportAction];
    [self addAction:snapshotAction];
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
