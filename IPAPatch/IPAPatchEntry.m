//
//  IPAPatchEntry.m
//  IPAPatch
//
//  Created by wutian on 2017/3/17.
//  Copyright © 2017 Weibo. All rights reserved.
//

#import "IPAPatchEntry.h"
#import <objc/runtime.h>
#import <TargetConditionals.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#else
#import <UIKit/UIKit.h>
#endif

static NSString *const ILConfigFileName = @"IPAPatchLookinConfig";
static NSString *const ILAppGroupRedirectsKey = @"AppGroupRedirects";
static NSString *const ILForcedBooleanDefaultsKey = @"ForcedBooleanDefaults";
static NSString *const ILRedirectUserDefaultsSuitesKey = @"RedirectUserDefaultsSuites";

static NSDictionary<NSString *, NSString *> *ILAppGroupRedirects;
static BOOL ILRedirectUserDefaultsSuites;
static NSMutableSet<NSString *> *ILLoggedAppGroupRedirects;
static NSMutableSet<NSString *> *ILLoggedUserDefaultsRedirects;

#if !TARGET_OS_OSX
static const CGFloat ILLookinScreenshotMaxLengthInPixels = 16384.0;

static UIImage *ILRenderLayerScreenshot(
    CALayer *layer,
    BOOL lowQuality,
    BOOL hidesSublayers
)
{
    CGSize contextSize = layer.frame.size;
    CGFloat screenScale = UIScreen.mainScreen.scale;
    CGFloat pixelWidth = contextSize.width * screenScale;
    CGFloat pixelHeight = contextSize.height * screenScale;
    if (pixelWidth <= 0 ||
        pixelHeight <= 0 ||
        contextSize.width > 20000 ||
        contextSize.height > 20000) {
        return nil;
    }

    CGFloat renderScale = lowQuality ? 1.0 : 0.0;
    CGFloat maxLength = MAX(pixelWidth, pixelHeight);
    if (maxLength > ILLookinScreenshotMaxLengthInPixels) {
        renderScale = MIN(
            screenScale * ILLookinScreenshotMaxLengthInPixels / maxLength,
            1.0
        );
    }

    NSMutableArray<CALayer *> *visibleSublayers = nil;
    if (hidesSublayers) {
        visibleSublayers = [NSMutableArray array];
        for (CALayer *sublayer in [layer.sublayers copy]) {
            if (!sublayer.hidden) {
                sublayer.hidden = YES;
                [visibleSublayers addObject:sublayer];
            }
        }
    }

    UIGraphicsBeginImageContextWithOptions(contextSize, NO, renderScale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    UIImage *image = nil;
    if (context) {
        [layer renderInContext:context];
        image = UIGraphicsGetImageFromCurrentImageContext();
    }
    UIGraphicsEndImageContext();

    for (CALayer *sublayer in visibleSublayers) {
        sublayer.hidden = NO;
    }
    return image;
}

@interface CALayer (IPAPatchLookinScreenshot)
- (UIImage *)il_groupScreenshotWithLowQuality:(BOOL)lowQuality;
- (UIImage *)il_soloScreenshotWithLowQuality:(BOOL)lowQuality;
@end

@implementation CALayer (IPAPatchLookinScreenshot)

- (UIImage *)il_groupScreenshotWithLowQuality:(BOOL)lowQuality
{
    return ILRenderLayerScreenshot(self, lowQuality, NO);
}

- (UIImage *)il_soloScreenshotWithLowQuality:(BOOL)lowQuality
{
    return ILRenderLayerScreenshot(self, lowQuality, YES);
}

@end
#endif

static NSDictionary *ILLoadConfiguration(void)
{
    NSString *path = [[NSBundle mainBundle] pathForResource:ILConfigFileName
                                                    ofType:@"plist"];
    if (!path) {
        return @{};
    }
    NSDictionary *configuration = [NSDictionary dictionaryWithContentsOfFile:path];
    return [configuration isKindOfClass:NSDictionary.class] ? configuration : @{};
}

static NSString *ILRedirectDirectoryName(NSString *groupIdentifier)
{
    if (![groupIdentifier isKindOfClass:NSString.class] ||
        groupIdentifier.length == 0) {
        return nil;
    }

    NSString *directoryName = ILAppGroupRedirects[groupIdentifier];
    if (![directoryName isKindOfClass:NSString.class] ||
        directoryName.length == 0 ||
        [directoryName containsString:@"/"] ||
        [directoryName isEqualToString:@"."] ||
        [directoryName isEqualToString:@".."]) {
        return nil;
    }
    return directoryName;
}

static BOOL ILShouldLogRedirect(
    NSMutableSet<NSString *> *loggedIdentifiers,
    NSString *identifier
)
{
    @synchronized (loggedIdentifiers) {
        if ([loggedIdentifiers containsObject:identifier]) {
            return NO;
        }
        [loggedIdentifiers addObject:identifier];
        return YES;
    }
}

@interface NSFileManager (IPAPatchLookinAppGroup)
- (NSURL *)il_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier;
@end

@implementation NSFileManager (IPAPatchLookinAppGroup)

- (NSURL *)il_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier
{
    NSString *directoryName = ILRedirectDirectoryName(groupIdentifier);
    if (!directoryName) {
        return [self il_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
    }

    NSURL *baseURL = [[self URLsForDirectory:NSLibraryDirectory
                                   inDomains:NSUserDomainMask] firstObject];
    if (!baseURL) {
        baseURL = self.temporaryDirectory;
    }

    NSURL *redirectedURL = [baseURL URLByAppendingPathComponent:directoryName
                                                    isDirectory:YES];
    NSError *error = nil;
    if (![self createDirectoryAtURL:redirectedURL
        withIntermediateDirectories:YES
                         attributes:nil
                              error:&error]) {
        NSLog(@"[IPAPatch-Lookin] Failed to create redirected App Group directory: %@", error);
        return [self il_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
    }

    if (ILShouldLogRedirect(ILLoggedAppGroupRedirects, groupIdentifier)) {
        NSLog(
            @"[IPAPatch-Lookin] Redirected App Group %@ to %@",
            groupIdentifier,
            redirectedURL.path
        );
    }
    return redirectedURL;
}

@end

@interface NSUserDefaults (IPAPatchLookinAppGroup)
- (instancetype)il_initWithSuiteName:(NSString *)suiteName;
@end

@implementation NSUserDefaults (IPAPatchLookinAppGroup)

- (instancetype)il_initWithSuiteName:(NSString *)suiteName
{
    if (!ILRedirectUserDefaultsSuites || !ILRedirectDirectoryName(suiteName)) {
        return [self il_initWithSuiteName:suiteName];
    }

    if (ILShouldLogRedirect(ILLoggedUserDefaultsRedirects, suiteName)) {
        NSLog(
            @"[IPAPatch-Lookin] Redirected UserDefaults suite %@ to the app sandbox",
            suiteName
        );
    }
    return [self il_initWithSuiteName:nil];
}

@end

static BOOL ILExchangeInstanceMethods(Class targetClass, SEL originalSelector, SEL replacementSelector)
{
    Method originalMethod = class_getInstanceMethod(targetClass, originalSelector);
    Method replacementMethod = class_getInstanceMethod(targetClass, replacementSelector);
    if (!originalMethod || !replacementMethod) {
        NSLog(
            @"[IPAPatch-Lookin] Unable to install compatibility hook: %@ / %@",
            NSStringFromSelector(originalSelector),
            NSStringFromSelector(replacementSelector)
        );
        return NO;
    }
    method_exchangeImplementations(originalMethod, replacementMethod);
    return YES;
}

@implementation IPAPatchEntry

+ (void)load
{
    NSDictionary *configuration = ILLoadConfiguration();
    NSDictionary *redirects = configuration[ILAppGroupRedirectsKey];
    ILAppGroupRedirects = [redirects isKindOfClass:NSDictionary.class] ? redirects : @{};
    ILRedirectUserDefaultsSuites =
        [configuration[ILRedirectUserDefaultsSuitesKey] boolValue];
    ILLoggedAppGroupRedirects = [NSMutableSet set];
    ILLoggedUserDefaultsRedirects = [NSMutableSet set];

    if (ILAppGroupRedirects.count > 0) {
        ILExchangeInstanceMethods(
            NSFileManager.class,
            @selector(containerURLForSecurityApplicationGroupIdentifier:),
            @selector(il_containerURLForSecurityApplicationGroupIdentifier:)
        );
        ILExchangeInstanceMethods(
            NSUserDefaults.class,
            @selector(initWithSuiteName:),
            @selector(il_initWithSuiteName:)
        );
    }

#if !TARGET_OS_OSX
    if (@available(iOS 26.0, *)) {
        BOOL installedGroupHook = ILExchangeInstanceMethods(
            CALayer.class,
            NSSelectorFromString(@"lks_groupScreenshotWithLowQuality:"),
            @selector(il_groupScreenshotWithLowQuality:)
        );
        BOOL installedSoloHook = ILExchangeInstanceMethods(
            CALayer.class,
            NSSelectorFromString(@"lks_soloScreenshotWithLowQuality:"),
            @selector(il_soloScreenshotWithLowQuality:)
        );
        if (installedGroupHook && installedSoloHook) {
            NSLog(
                @"[IPAPatch-Lookin] Installed iOS 26 safe screenshot compatibility"
            );
        }
    }
#endif

    NSDictionary *forcedDefaults = configuration[ILForcedBooleanDefaultsKey];
    if ([forcedDefaults isKindOfClass:NSDictionary.class]) {
        [forcedDefaults enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSNumber.class]) {
                [[NSUserDefaults standardUserDefaults] setBool:[value boolValue]
                                                       forKey:key];
            }
        }];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        Class lookinClass = NSClassFromString(@"Lookin");
        NSLog(
            @"[IPAPatch-Lookin] LookinServer %@",
            lookinClass ? @"loaded" : @"not loaded"
        );
    });
}

@end
