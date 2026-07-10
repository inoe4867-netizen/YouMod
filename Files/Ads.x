#import "Headers.h"

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
        @"brand_video_shelf",
        @"carousel_footered_layout",
        @"carousel_headered_layout",
        @"eml.expandable_metadata",
        @"feed_ad_metadata",
        @"full_width_portrait_image_layout",
        @"full_width_square_image_layout",
        @"grid_ads_image_layout",
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
    ]) {
        if ([description containsString:str]) return str;
    }
    return nil;
}

static BOOL isAdRenderer(YTIElementRenderer *elementRenderer, int kind) {
    if ([elementRenderer respondsToSelector:@selector(hasCompatibilityOptions)] &&
        elementRenderer.hasCompatibilityOptions &&
        elementRenderer.compatibilityOptions.hasAdLoggingData) {
        return YES;
    }

    NSString *description = [elementRenderer description];
    return getAdString(description) != nil;
}

static BOOL YouModIsStrongShortsAdMarker(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) {
        return NO;
    }

    NSString *normalized = [[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];

    if ([normalized hasPrefix:@"sponsored"] ||
        [normalized containsString:@"visit advertiser"] ||
        [normalized containsString:@"advertiser website"]) {
        return YES;
    }

    if ([normalized containsString:@"ad_badge"] ||
        [normalized containsString:@"adbadge"] ||
        [normalized containsString:@"shorts_ad"] ||
        [normalized containsString:@"shorts.ad"] ||
        [normalized containsString:@"reel_ad"] ||
        [normalized containsString:@"reel.ad"] ||
        [normalized containsString:@"promoted"] ||
        [normalized containsString:@"sponsored"]) {
        return YES;
    }

    return NO;
}

static UIViewController *YouModFindShortsAdvanceController(UIView *view) {
    UIViewController *controller = [view _viewControllerForAncestor];
    SEL advanceSelector = @selector(reelContentViewRequestsAdvanceToNextVideo:);

    while (controller) {
        if ([controller respondsToSelector:advanceSelector]) {
            return controller;
        }
        controller = controller.parentViewController;
    }

    return nil;
}

static void YouModTrySeamlessShortsAdSkip(UIView *view, NSString *additionalText) {
    if (!view || !view.window) {
        return;
    }

    BOOL hasAdMarker = YouModIsStrongShortsAdMarker(additionalText) ||
        YouModIsStrongShortsAdMarker(view.accessibilityLabel) ||
        YouModIsStrongShortsAdMarker(view.accessibilityIdentifier);

    if (!hasAdMarker) {
        return;
    }

    UIViewController *controller = YouModFindShortsAdvanceController(view);
    if (!controller) {
        return;
    }

    static NSTimeInterval lastSkipTime = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    // Prevent multiple labels belonging to one ad from causing multiple advances.
    if (now - lastSkipTime < 0.85) {
        return;
    }
    lastSkipTime = now;

    SEL advanceSelector = @selector(reelContentViewRequestsAdvanceToNextVideo:);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (![controller respondsToSelector:advanceSelector] || !controller.view.window) {
            return;
        }

        [UIView performWithoutAnimation:^{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [controller performSelector:advanceSelector withObject:nil];
#pragma clang diagnostic pop
        }];
    });
}

// Globally remove element renderers identified as ads.
// Adapted from the YouTube Plus/YTLite filtering strategy.
%hook YTIElementRenderer
- (NSData *)elementData {
    if ([self respondsToSelector:@selector(hasCompatibilityOptions)] &&
        self.hasCompatibilityOptions &&
        self.compatibilityOptions.hasAdLoggingData) {
        return nil;
    }

    if (getAdString([self description])) {
        return [NSData data];
    }

    return %orig;
}
%end

// Fallback for ad labels rendered as ordinary UIKit labels.
%hook UILabel
- (void)setText:(NSString *)text {
    %orig;
    YouModTrySeamlessShortsAdSkip(self, text);
}

- (void)didMoveToWindow {
    %orig;
    YouModTrySeamlessShortsAdSkip(self, self.text);
}
%end

static NSMutableArray *filteredArray(NSArray *array) {
    NSMutableArray *newArray = [array mutableCopy];
    NSIndexSet *removeIndexes = [newArray indexesOfObjectsPassingTest:^BOOL(YTIItemSectionRenderer *sectionRenderer, NSUInteger idx, BOOL *stop) {
        if ([sectionRenderer isKindOfClass:%c(YTIShelfRenderer)]) {
            YTIShelfSupportedRenderers *content = ((YTIShelfRenderer *)sectionRenderer).content;
            YTIHorizontalListRenderer *horizontalListRenderer = content.horizontalListRenderer;
            NSMutableArray *itemsArray = horizontalListRenderer.itemsArray;
            NSIndexSet *removeItemsArrayIndexes = [itemsArray indexesOfObjectsPassingTest:^BOOL(YTIHorizontalListSupportedRenderers *horizontalListSupportedRenderers, NSUInteger idx2, BOOL *stop2) {
                return isAdRenderer(horizontalListSupportedRenderers.elementRenderer, 4);
            }];
            [itemsArray removeObjectsAtIndexes:removeItemsArrayIndexes];
        }

        if (![sectionRenderer isKindOfClass:%c(YTIItemSectionRenderer)]) {
            return NO;
        }

        NSMutableArray *contentsArray = sectionRenderer.contentsArray;
        if (contentsArray.count > 1) {
            NSIndexSet *removeContentsArrayIndexes = [contentsArray indexesOfObjectsPassingTest:^BOOL(YTIItemSectionSupportedRenderers *sectionSupportedRenderers, NSUInteger idx2, BOOL *stop2) {
                return isAdRenderer(sectionSupportedRenderers.elementRenderer, 3);
            }];
            [contentsArray removeObjectsAtIndexes:removeContentsArrayIndexes];
        }

        YTIItemSectionSupportedRenderers *firstObject = [contentsArray firstObject];
        return isAdRenderer(firstObject.elementRenderer, 2);
    }];

    [newArray removeObjectsAtIndexes:removeIndexes];
    return newArray;
}

%hook YTPlayerResponse
%new(@@:)
- (NSMutableArray *)playerAdsArray {
    return [NSMutableArray array];
}

%new(@@:)
- (NSMutableArray *)adSlotsArray {
    return [NSMutableArray array];
}
%end

%hook YTIClientMdxGlobalConfig
%new(B@:)
- (BOOL)enableSkippableAd {
    return YES;
}
%end

%hook YTAdShieldUtils
+ (id)spamSignalsDictionary {
    return @{};
}

+ (id)spamSignalsDictionaryWithoutIDFA {
    return @{};
}
%end

%hook YTDataUtils
+ (id)spamSignalsDictionary {
    return @{ @"ms": @"" };
}

+ (id)spamSignalsDictionaryWithoutIDFA {
    return @{};
}
%end

%hook YTAdsInnerTubeContextDecorator
- (void)decorateContext:(id)context {
    %orig(nil);
}
%end

%hook YTAccountScopedAdsInnerTubeContextDecorator
- (void)decorateContext:(id)context {
    %orig(nil);
}
%end

%hook YTLocalPlaybackController
- (id)createAdsPlaybackCoordinator {
    return nil;
}
%end

%hook MDXSession
- (void)adPlaying:(id)ad {}
%end

%hook MDXSessionImpl
- (void)adPlaying:(id)ad {}
%end

%hook YTReelDataSource
- (YTReelModel *)makeContentModelForEntry:(id)entry {
    YTReelModel *model = %orig;
    if ([model respondsToSelector:@selector(videoType)] && model.videoType == 3) {
        return nil;
    }
    return model;
}
%end

%hook YTReelContentModel
+ (YTReelModel *)makeContentModelForEntry:(id)entry {
    YTReelModel *model = %orig;
    if ([model respondsToSelector:@selector(videoType)] && model.videoType == 3) {
        return nil;
    }
    return model;
}
%end

%hook YTReelInfinitePlaybackDataSource
- (YTReelModel *)makeContentModelForEntry:(id)entry {
    YTReelModel *model = %orig;
    if ([model respondsToSelector:@selector(videoType)] && model.videoType == 3) {
        return nil;
    }
    return model;
}

- (void)setReels:(NSMutableOrderedSet *)reels {
    [reels removeObjectsAtIndexes:[reels indexesOfObjectsPassingTest:^BOOL(YTReelModel *obj, NSUInteger idx, BOOL *stop) {
        return [obj respondsToSelector:@selector(videoType)] ? obj.videoType == 3 : NO;
    }]];
    %orig;
}
%end

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

    if (isProductList(onUiReady)) {
        model.onUiReady = nil;
    }

    %orig;
}
%end

%hook YTMainAppVideoPlayerOverlayViewController
- (void)playerOverlayProvider:(YTPlayerOverlayProvider *)provider didInsertPlayerOverlay:(YTPlayerOverlay *)overlay {
    if ([[overlay overlayIdentifier] isEqualToString:@"player_overlay_product_in_video"]) {
        return;
    }
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

    if ([self.accessibilityIdentifier isEqualToString:@"eml.expandable_metadata.vpp"]) {
        [self removeFromSuperview];
    }

    if ([self.accessibilityIdentifier isEqualToString:@"eml.ad_layout.full_width_square_image_layout"]) {
        self.hidden = YES;
    }

    // AsyncDisplayKit-backed Shorts labels often expose ad status through accessibility metadata.
    YouModTrySeamlessShortsAdSkip(self, nil);
}
%end

// NoYTPremium - @PoomSmart https://github.com/PoomSmart/NoYTPremium
%hook YTCommerceEventGroupHandler
- (void)addEventHandlers {}
%end

%hook YTInterstitialPromoEventGroupHandler
- (void)addEventHandlers {}
%end

%hook YTPromosheetEventGroupHandler
- (void)addEventHandlers {}
%end

%hook YTPromoThrottleController
- (BOOL)canShowThrottledPromo {
    return NO;
}

- (BOOL)canShowThrottledPromoWithFrequencyCap:(id)arg1 {
    return NO;
}

- (BOOL)canShowThrottledPromoWithFrequencyCaps:(id)arg1 {
    return NO;
}
%end

%hook YTPromoThrottleControllerImpl
- (BOOL)canShowThrottledPromo {
    return NO;
}

- (BOOL)canShowThrottledPromoWithFrequencyCap:(id)arg1 {
    return NO;
}

- (BOOL)canShowThrottledPromoWithFrequencyCaps:(id)arg1 {
    return NO;
}
%end

%hook YTIShowFullscreenInterstitialCommand
- (BOOL)shouldThrottleInterstitial {
    if (self.hasModalClientThrottlingRules) {
        self.modalClientThrottlingRules.oncePerTimeWindow = YES;
    }
    return %orig;
}
%end

%hook YTSettingsSectionItemManager
- (void)updatePremiumEarlyAccessSectionWithEntry:(id)arg1 {}
%end

%hook YTSurveyController
- (void)showSurveyWithRenderer:(id)arg1 surveyParentResponder:(id)arg2 {}
%end
