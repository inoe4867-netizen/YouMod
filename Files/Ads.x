#import "Headers.h"
#import <objc/runtime.h>

// YouTube-X (https://github.com/PoomSmart/YouTube-X)
static BOOL isProductList(YTICommand *command) {
    if ([command respondsToSelector:@selector(yt_showEngagementPanelEndpoint)]) {
        YTIShowEngagementPanelEndpoint *endpoint = [command yt_showEngagementPanelEndpoint];
        return [endpoint.identifier.tag isEqualToString:@"PAproduct_list"];
    }
    return NO;
}

NSString *getAdString(NSString *description) {
    for (NSString *str in @[
        @"brand_promo",
        @"carousel_footered_layout",
        @"carousel_headered_layout",
        @"eml.expandable_metadata",
        @"feed_ad_metadata",
        @"full_width_portrait_image_layout",
        @"full_width_square_image_layout",
        @"landscape_image_wide_button_layout",
        @"post_shelf",
        @"product_carousel",
        @"product_engagement_panel",
        @"product_item",
        @"shopping_carousel",
        @"shopping_item_card_list",
        @"statement_banner",
        @"square_image_layout",
        @"text_image_button_layout",
        @"text_search_ad",
        @"video_display_full_layout",
        @"video_display_full_buttoned_layout"
    ])
        if ([description containsString:str]) return str;
    return nil;
}

static BOOL isAdRenderer(YTIElementRenderer *elementRenderer, int kind) {
    if ([elementRenderer respondsToSelector:@selector(hasCompatibilityOptions)] && elementRenderer.hasCompatibilityOptions && elementRenderer.compatibilityOptions.hasAdLoggingData) {
        return YES;
    }
    NSString *description = [elementRenderer description];
    NSString *adString = getAdString(description);
    if (adString) {
        return YES;
    }
    return NO;
}

static NSMutableArray *filteredArray(NSArray *array) {
    NSMutableArray *newArray = [array mutableCopy];
    NSIndexSet *removeIndexes = [newArray indexesOfObjectsPassingTest:^BOOL(YTIItemSectionRenderer *sectionRenderer, NSUInteger idx, BOOL *stop) {
        if ([sectionRenderer isKindOfClass:%c(YTIShelfRenderer)]) {
            YTIShelfSupportedRenderers *content = ((YTIShelfRenderer *)sectionRenderer).content;
            YTIHorizontalListRenderer *horizontalListRenderer = content.horizontalListRenderer;
            NSMutableArray *itemsArray = horizontalListRenderer.itemsArray;
            NSIndexSet *removeItemsArrayIndexes = [itemsArray indexesOfObjectsPassingTest:^BOOL(YTIHorizontalListSupportedRenderers *horizontalListSupportedRenderers, NSUInteger idx2, BOOL *stop2) {
                YTIElementRenderer *elementRenderer = horizontalListSupportedRenderers.elementRenderer;
                return isAdRenderer(elementRenderer, 4);
            }];
            [itemsArray removeObjectsAtIndexes:removeItemsArrayIndexes];
        }
        if (![sectionRenderer isKindOfClass:%c(YTIItemSectionRenderer)])
            return NO;
        NSMutableArray *contentsArray = sectionRenderer.contentsArray;
        if (contentsArray.count > 1) {
            NSIndexSet *removeContentsArrayIndexes = [contentsArray indexesOfObjectsPassingTest:^BOOL(YTIItemSectionSupportedRenderers *sectionSupportedRenderers, NSUInteger idx2, BOOL *stop2) {
                YTIElementRenderer *elementRenderer = sectionSupportedRenderers.elementRenderer;
                return isAdRenderer(elementRenderer, 3);
            }];
            [contentsArray removeObjectsAtIndexes:removeContentsArrayIndexes];
        }
        YTIItemSectionSupportedRenderers *firstObject = [contentsArray firstObject];
        YTIElementRenderer *elementRenderer = firstObject.elementRenderer;
        return isAdRenderer(elementRenderer, 2);
    }];
    [newArray removeObjectsAtIndexes:removeIndexes];
    return newArray;
}

%hook YTPlayerResponse
%new(@@:)
- (NSMutableArray *)playerAdsArray { return [NSMutableArray array]; }
%new(@@:)
- (NSMutableArray *)adSlotsArray { return [NSMutableArray array]; }
%end

%hook YTIClientMdxGlobalConfig
%new(B@:)
- (BOOL)enableSkippableAd { return YES; }
%end

%hook YTAdShieldUtils
+ (id)spamSignalsDictionary { return @{}; }
+ (id)spamSignalsDictionaryWithoutIDFA { return @{}; }
%end

%hook YTDataUtils
+ (id)spamSignalsDictionary { return @{ @"ms": @"" }; }
+ (id)spamSignalsDictionaryWithoutIDFA { return @{}; }
%end

%hook YTAdsInnerTubeContextDecorator
- (void)decorateContext:(id)context { %orig(nil); }
%end

%hook YTAccountScopedAdsInnerTubeContextDecorator
- (void)decorateContext:(id)context { %orig(nil); }
%end

%hook YTLocalPlaybackController
- (id)createAdsPlaybackCoordinator { return nil; }
%end

%hook MDXSession
- (void)adPlaying:(id)ad {}
%end

%hook MDXSessionImpl
- (void)adPlaying:(id)ad {}
%end

// ===== TEMPORARY DIAGNOSTIC - remove after testing =====
static NSMutableDictionary *YMTally;
static UILabel *YMDiagLabel;
static NSInteger YMHitA;
static NSInteger YMHitB;
static NSInteger YMReelClassCount;
static NSInteger YMTicks;

static void YMCountReelClasses(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSInteger found = 0;
    for (unsigned int i = 0; i < count; i++) {
        const char *n = class_getName(classes[i]);
        if (n && (strstr(n, "ReelDataSource") || strstr(n, "ReelInfinite"))) found++;
    }
    free(classes);
    YMReelClassCount = found;
}

static NSString *YMDiagText(void) {
    BOOL clsA = (%c(YTReelDataSource) != nil);
    BOOL clsB = (%c(YTReelInfinitePlaybackDataSource) != nil);
    BOOL selA = clsA && [%c(YTReelDataSource) instancesRespondToSelector:@selector(makeContentModelForEntry:)];
    BOOL selB = clsB && [%c(YTReelInfinitePlaybackDataSource) instancesRespondToSelector:@selector(makeContentModelForEntry:)];

    NSMutableString *text = [NSMutableString stringWithString:@"SHORTS DIAG v5\n"];
    [text appendFormat:@"ticks %ld\n", (long)YMTicks];
    [text appendFormat:@"clsA %@ selA %@ hitA %ld\n", clsA ? @"Y" : @"N", selA ? @"Y" : @"N", (long)YMHitA];
    [text appendFormat:@"clsB %@ selB %@ hitB %ld\n", clsB ? @"Y" : @"N", selB ? @"Y" : @"N", (long)YMHitB];
    [text appendFormat:@"reel-ish classes %ld\n", (long)YMReelClassCount];
    NSInteger total = 0;
    for (NSNumber *k in [[YMTally allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        [text appendFormat:@"type %@ x%@\n", k, YMTally[k]];
        total += [YMTally[k] integerValue];
    }
    [text appendFormat:@"total %ld", (long)total];
    return text;
}

static UIWindow *YMFindWindow(void) {
    NSMutableArray *candidates = [NSMutableArray array];
    for (id scene in [[UIApplication sharedApplication].connectedScenes allObjects]) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in [(UIWindowScene *)scene windows]) {
            if (w && !w.hidden && w.alpha > 0.01) [candidates addObject:w];
        }
    }
    for (UIWindow *w in candidates) {
        if (w.isKeyWindow) return w;
    }
    return [candidates lastObject];
}

static void YMDiagRefresh(void) {
    YMTicks++;
    NSString *text = YMDiagText();

    if (YMTicks % 5 == 0) {
        [UIPasteboard generalPasteboard].string = text;
    }

    UIWindow *window = YMFindWindow();
    if (!window) return;
    if (!YMDiagLabel) {
        YMDiagLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 60, 320, 210)];
        YMDiagLabel.numberOfLines = 0;
        YMDiagLabel.font = [UIFont boldSystemFontOfSize:12];
        YMDiagLabel.textColor = [UIColor yellowColor];
        YMDiagLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        YMDiagLabel.userInteractionEnabled = NO;
        YMDiagLabel.layer.zPosition = 9999;
    }
    if (YMDiagLabel.superview != window) [window addSubview:YMDiagLabel];
    [window bringSubviewToFront:YMDiagLabel];
    YMDiagLabel.text = text;
}

static void YMDiagRecord(NSInteger type) {
    if (!YMTally) YMTally = [NSMutableDictionary dictionary];
    NSNumber *key = @(type);
    YMTally[key] = @([YMTally[key] integerValue] + 1);
}

%hook YTReelDataSource
- (YTReelModel *)makeContentModelForEntry:(id)entry {
    YTReelModel *model = %orig;
    YMHitA++;
    if (model && [model respondsToSelector:@selector(videoType)])
        YMDiagRecord((NSInteger)model.videoType);
    return model;
}
%end

%hook YTReelInfinitePlaybackDataSource
- (YTReelModel *)makeContentModelForEntry:(id)entry {
    YTReelModel *model = %orig;
    YMHitB++;
    if (model && [model respondsToSelector:@selector(videoType)])
        YMDiagRecord((NSInteger)model.videoType);
    return model;
}
%end

%ctor {
    %init;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIPasteboard generalPasteboard].string = @"SHORTS DIAG v5\nctor ran, timer not yet started";
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YMCountReelClasses();
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
            YMDiagRefresh();
        }];
    });
}
// ===== END TEMPORARY DIAGNOSTIC =====

%hook YTWatchNextResponseViewController
- (void)loadWithModel:(YTIWatchNextResponse *)model {
    YTICommand *onUiReady = model.onUiReady;
    if ([onUiReady respondsToSelector:@selector(yt_commandExecutorCommand)]) {
        YTICommandExecutorCommand *commandExecutorCommand = [onUiReady yt_commandExecutorCommand];
        NSMutableArray *commandsArray = commandExecutorCommand.commandsArray;
        [commandsArray removeObjectsAtIndexes:[commandsArray indexesOfObjectsPassingTest:^BOOL(YTICommand *command, NSUInteger idx, BOOL *stop) {
            return isProductList(command);
        }]];
    }
    if (isProductList(onUiReady))
        model.onUiReady = nil;
    %orig;
}
%end

%hook YTMainAppVideoPlayerOverlayViewController
- (void)playerOverlayProvider:(YTPlayerOverlayProvider *)provider didInsertPlayerOverlay:(YTPlayerOverlay *)overlay {
    if ([[overlay overlayIdentifier] isEqualToString:@"player_overlay_product_in_video"]) return;
    %orig;
}
%end

%hook YTInnerTubeCollectionViewController
- (void)displaySectionsWithReloadingSectionControllerByRenderer:(id)renderer {
    NSMutableArray *sectionRenderers = [self valueForKey:@"_sectionRenderers"];
    [self setValue:filteredArray(sectionRenderers) forKey:@"_sectionRenderers"];
    %orig;
}
- (void)addSectionsFromArray:(NSArray *)array {
    %orig(filteredArray(array));
}
%end

%hook _ASDisplayView
- (void)didMoveToWindow {
    %orig;
    if ([self.accessibilityIdentifier isEqualToString:@"eml.expandable_metadata.vpp"]) [self removeFromSuperview];
    if ([self.accessibilityIdentifier isEqualToString:@"eml.ad_layout.full_width_square_image_layout"]) self.hidden = YES;
}
%end

// NoYTPremium - @PoomSmart https://github.com/PoomSmart/NoYTPremium
// Alert
%hook YTCommerceEventGroupHandler
- (void)addEventHandlers {}
%end

// Full-screen
%hook YTInterstitialPromoEventGroupHandler
- (void)addEventHandlers {}
%end

%hook YTPromosheetEventGroupHandler
- (void)addEventHandlers {}
%end

%hook YTPromoThrottleController
- (BOOL)canShowThrottledPromo { return NO; }
- (BOOL)canShowThrottledPromoWithFrequencyCap:(id)arg1 { return NO; }
- (BOOL)canShowThrottledPromoWithFrequencyCaps:(id)arg1 { return NO; }
%end

%hook YTPromoThrottleControllerImpl
- (BOOL)canShowThrottledPromo { return NO; }
- (BOOL)canShowThrottledPromoWithFrequencyCap:(id)arg1 { return NO; }
- (BOOL)canShowThrottledPromoWithFrequencyCaps:(id)arg1 { return NO; }
%end

%hook YTIShowFullscreenInterstitialCommand
- (BOOL)shouldThrottleInterstitial {
    if (self.hasModalClientThrottlingRules)
        self.modalClientThrottlingRules.oncePerTimeWindow = YES;
    return %orig;
}
%end

// "Try new features" in settings
%hook YTSettingsSectionItemManager
- (void)updatePremiumEarlyAccessSectionWithEntry:(id)arg1 {}
%end

// Survey
%hook YTSurveyController
- (void)showSurveyWithRenderer:(id)arg1 surveyParentResponder:(id)arg2 {}
%end
