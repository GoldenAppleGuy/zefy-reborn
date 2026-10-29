// ZefyReborn: spotify: and open.spotify.com links that carry a play flag start playback in the Spotify app.
//
//   https://open.spotify.com/playlist/<id>?play=true      spotify:playlist:<id>:play
//   ...?shuffle=true (also starts playback and turns shuffle on)
//
// Quick Play: in SpringBoard, a play press that would go to another player while nothing is playing resumes
// Spotify instead.
//
// Debug log: create an empty file named zefyreborn.debug in Spotify's Documents folder; the log is
// zefyreborn.log next to it. In SpringBoard the same two files live in the jailbreak's tmp folder.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <malloc/malloc.h>
#import <sys/time.h>
#import <sys/sysctl.h>
#import <notify.h>
#import <AudioToolbox/AudioToolbox.h>
#import <substrate.h>
#import <dlfcn.h>
#import <pthread.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#define STRIP(p) ptrauth_strip((p), ptrauth_key_function_pointer)
#else
#define STRIP(p) (p)
#endif

static NSString *const kOrigPrefix = @"spurl_orig_";
static NSString *const kPrefsDomain = @"com.goldenappleguy.zefyreborn";
static NSString *const kSpotifyID = @"com.spotify.client";
static NSString *const kResumeCommand = @"zefyreborn:resume";
static NSString *const kCommandPrefix = @"zefyreborn:cmd ";
static NSString *const kCollectionClass = @"SPTExternalIntegrationCollectionControllerImplementation";
static NSString *const kContentClass = @"SPTExternalIntegrationContentControllerImplementation";
static NSString *const kControllerClass = @"SPTExternalIntegrationPlaybackControllerImplementation";

// ---- jailbreak root -----------------------------------------------------------------------------------------

// Where the jailbreak lives ("" rootful, "/var/jb" rootless, a .jbroot path on roothide), from where this dylib
// was loaded. The tweak's shared files (the SpringBoard command channel, the cover cache, the log) are in its tmp.
static NSString *ZRRoot(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        NSString *path = dladdr((const void *)&ZRRoot, &info) && info.dli_fname ? @(info.dli_fname) : @"";
        root = @"/var/jb";
        for (NSString *marker in @[@"/Library/MobileSubstrate/DynamicLibraries/", @"/usr/lib/TweakInject/"]) {
            NSRange range = [path rangeOfString:marker];
            if (range.location != NSNotFound) {
                root = [path substringToIndex:range.location];
                break;
            }
        }
    });
    return root;
}

static NSString *ZRTmp(void) { return [ZRRoot() stringByAppendingString:@"/tmp"]; }

// ---- debug log --------------------------------------------------------------------------------------------

static BOOL debugEnabled(void) {
    char dir[1024], flag[1100];
    if (!strcmp(getprogname(), "SpringBoard")) snprintf(dir, sizeof dir, "%s", ZRTmp().fileSystemRepresentation);
    else {
        const char *home = getenv("HOME");
        if (!home) return NO;
        snprintf(dir, sizeof dir, "%s/Documents", home);
    }
    snprintf(flag, sizeof flag, "%s/zefyreborn.debug", dir);
    return access(flag, F_OK) == 0;
}

static void SPLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void SPLog(NSString *fmt, ...) {
    static FILE *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char dir[1024], flag[1100], path[1100];
        if (!strcmp(getprogname(), "SpringBoard")) {
            snprintf(dir, sizeof dir, "%s", ZRTmp().fileSystemRepresentation);
        } else {
            const char *home = getenv("HOME");
            if (!home) return;
            snprintf(dir, sizeof dir, "%s/Documents", home);
        }
        snprintf(flag, sizeof flag, "%s/zefyreborn.debug", dir);
        if (access(flag, F_OK) != 0) return;
        snprintf(path, sizeof path, "%s/zefyreborn.log", dir);
        f = fopen(path, "a");
    });
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tmv;
    localtime_r(&tv.tv_sec, &tmv);
    char ts[32];
    strftime(ts, sizeof ts, "%H:%M:%S", &tmv);
    fprintf(f, "%s.%03d %s\n", ts, (int)(tv.tv_usec / 1000), msg.UTF8String);
    fflush(f);
}

// ---- settings ---------------------------------------------------------------------------------------------

// Spotify is sandboxed and cannot read this tweak's preferences domain, so SpringBoard (and the zefy
// command) copy the settings into Documents/zefyreborn.settings, one "key=1" line each, which the app reads.
static NSString *settingsFile(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"zefyreborn.settings"];
}

static BOOL prefBool(NSString *key, BOOL fallback) {
    if (!strcmp(getprogname(), "Spotify")) {
        NSString *text = [NSString stringWithContentsOfFile:settingsFile() encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:[key stringByAppendingString:@"="]]) return [[line substringFromIndex:key.length + 1] boolValue];
        }
        return fallback;
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsDomain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kPrefsDomain));
    return [v isKindOfClass:NSNumber.class] ? [v boolValue] : fallback;
}

// ---- finding the playback controller ----------------------------------------------------------------------
// Spotify creates the controller itself (creating another one traps), so locate the live instance by
// scanning the heap for objects whose class pointer matches. Only the first word of each block is read.

typedef struct { uintptr_t target; id __unsafe_unretained found; unsigned count; } ScanState;
static ScanState *gScan;

static kern_return_t scanReader(task_t t, vm_address_t a, vm_size_t s, void **out) { *out = (void *)a; return KERN_SUCCESS; }
static void scanRecorder(task_t t, void *ctx, unsigned type, vm_range_t *ranges, unsigned count) {
    ScanState *st = gScan;
    for (unsigned i = 0; i < count; i++) {
        if (ranges[i].size < 16 || (ranges[i].address & 7)) continue;
        uintptr_t isa = *(uintptr_t *)ranges[i].address & 0x0000000ffffffff8ULL;
        if (isa != st->target) continue;
        if (!st->count++) st->found = (__bridge id)(void *)ranges[i].address;
    }
}

// All live instances of a class (up to 16), found the same way as the playback controller.
typedef struct { uintptr_t target; void *found[16]; unsigned count; } ScanAll;
static ScanAll *gScanAll;

static void scanRecorderAll(task_t t, void *ctx, unsigned type, vm_range_t *ranges, unsigned count) {
    ScanAll *st = gScanAll;
    for (unsigned i = 0; i < count; i++) {
        if (ranges[i].size < 16 || (ranges[i].address & 7)) continue;
        if ((*(uintptr_t *)ranges[i].address & 0x0000000ffffffff8ULL) != st->target) continue;
        if (st->count < 16) st->found[st->count++] = (void *)ranges[i].address;
    }
}

static NSArray *findAllInstances(NSString *className) {
    Class k = NSClassFromString(className);
    if (!k) return @[];
    ScanAll st = { (uintptr_t)(__bridge void *)k, {0}, 0 };
    gScanAll = &st;
    vm_address_t *zones = NULL;
    unsigned zc = 0;
    malloc_get_all_zones(mach_task_self(), scanReader, &zones, &zc);
    for (unsigned z = 0; z < zc; z++) {
        malloc_zone_t *zone = (malloc_zone_t *)zones[z];
        if (zone && zone->introspect && zone->introspect->enumerator)
            zone->introspect->enumerator(mach_task_self(), NULL, MALLOC_PTR_IN_USE_RANGE_TYPE, (vm_address_t)zone, scanReader, scanRecorderAll);
    }
    gScanAll = NULL;
    NSMutableArray *out = [NSMutableArray array];
    for (unsigned i = 0; i < st.count; i++) [out addObject:(__bridge id)st.found[i]];
    SPLog(@"scan all %@: %lu instance(s)", className, (unsigned long)out.count);
    return out;
}

static id findInstance(NSString *className) {
    Class k = NSClassFromString(className);
    if (!k) return nil;
    ScanState st = { (uintptr_t)(__bridge void *)k, nil, 0 };
    gScan = &st;
    vm_address_t *zones = NULL;
    unsigned zc = 0;
    malloc_get_all_zones(mach_task_self(), scanReader, &zones, &zc);
    for (unsigned z = 0; z < zc; z++) {
        malloc_zone_t *zone = (malloc_zone_t *)zones[z];
        if (zone && zone->introspect && zone->introspect->enumerator)
            zone->introspect->enumerator(mach_task_self(), NULL, MALLOC_PTR_IN_USE_RANGE_TYPE, (vm_address_t)zone, scanReader, scanRecorder);
    }
    gScan = NULL;
    SPLog(@"scan %@: %u instance(s)", className, st.count);
    return st.found;
}

static id findController(void) { return findInstance(kControllerClass); }

// ---- links ------------------------------------------------------------------------------------------------

static BOOL truthy(NSString *v) {
    v = [v stringByTrimmingCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]];
    return v && ([v isEqualToString:@"1"] || [v caseInsensitiveCompare:@"true"] == NSOrderedSame || [v caseInsensitiveCompare:@"yes"] == NSOrderedSame);
}

// Turns a spotify: or open.spotify.com link into a content URI. Returns nil if it carries no play flag.
static NSString *parseLink(NSURL *url, BOOL *shuffle) {
    NSString *type = nil, *ident = nil;
    BOOL play = NO;
    *shuffle = NO;
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *i in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems)
        if (i.name) q[i.name.lowercaseString] = i.value ?: @"1";
    NSString *full = nil;
    if ([url.scheme isEqualToString:@"spotify"]) {
        NSMutableArray *seg = [[[url.resourceSpecifier componentsSeparatedByString:@"?"].firstObject componentsSeparatedByString:@":"] mutableCopy];
        if ([seg.firstObject isEqualToString:@"user"] && seg.count > 3) [seg removeObjectsInRange:NSMakeRange(0, 2)];   // spotify:user:<name>:playlist:<id>
        if (seg.count > 2 && [seg.lastObject isEqualToString:@"play"]) { [seg removeLastObject]; play = YES; }
        if (seg.count >= 2) { type = seg[0]; ident = seg[1]; full = [@"spotify:" stringByAppendingString:[seg componentsJoinedByString:@":"]]; }
    } else if ([url.host hasSuffix:@"open.spotify.com"]) {
        NSMutableArray *seg = [[url.path componentsSeparatedByString:@"/"] mutableCopy];
        [seg removeObject:@""];
        if ([seg.firstObject hasPrefix:@"intl-"]) [seg removeObjectAtIndex:0];
        if (seg.count >= 2) { type = seg[0]; ident = seg[1]; }
    }
    if (!type || !ident) return nil;
    if (truthy(q[@"play"]) || truthy(q[@"autoplay"])) play = YES;
    if (truthy(q[@"shuffle"])) { *shuffle = YES; play = YES; }
    return play ? (full ?: [NSString stringWithFormat:@"spotify:%@:%@", type, ident]) : nil;
}

// Spotify's own CarPlay path plays a content item (a node with its context), which starts the real contents of
// a playlist or album. A bare URI on a free account can start recommended tracks instead, so playlists, albums
// and artists are wrapped in an item first.
static id contentItemForURI(NSString *uri) {
    Class k = NSClassFromString(@"SPTExternalIntegrationContentModel");
    SEL init = NSSelectorFromString(@"initWithTitle:subtitle:URI:viewURI:imageURI:placeholderIcon:container:children:contextURI:skipToTrack:requestOptions:availableOffline:explicitContent:is19PlusContent:playbackProgress:");
    if (!k || ![k instancesRespondToSelector:init]) return nil;
    // Spotify bridges the URL arguments to non-optional Swift URLs, so none of them may be nil; a library item
    // has its own URI as its context and no skip-to-track.
    NSURL *u = [NSURL URLWithString:uri];
    return ((id (*)(id, SEL, id, id, id, id, id, id, BOOL, id, id, id, id, BOOL, BOOL, BOOL, float))objc_msgSend)(
        [k alloc], init, @"", @"", u, u, u, @"", YES, @[], u, nil, nil, NO, NO, NO, 0.0f);
}

static void browseChildrenWith(NSString *parent, BOOL entityPages, NSString *locale, void (^completion)(id response, id error));
// Spotify 9.0 asserts that a play request has an origin (9.1 accepts none), so every play call passes one.
static id makePlayOrigin(NSString *viewURI) {
    Class k = NSClassFromString(@"SPTPlayOrigin");
    SEL init = NSSelectorFromString(@"initWithFeatureIdentifier:featureVersion:viewURI:externalReferrer:");
    if (!k || !class_getInstanceMethod(k, init)) return nil;
    return ((id (*)(id, SEL, id, id, id, id))objc_msgSend)([k alloc], init, @"external-integration", @"1.0", [NSURL URLWithString:viewURI ?: @"spotify:home"] ?: [NSURL URLWithString:@"spotify:home"], @"zefyreborn");
}

static id makeLoggingParams(void) {
    Class k = NSClassFromString(@"SPTLoggingParams");
    id p = k ? [[k alloc] init] : nil;
    for (NSString *key in @[@"interactionId", @"commandId", @"pageInstanceId"]) {
        SEL set = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:", [[key substringToIndex:1] uppercaseString], [key substringFromIndex:1]]);
        if ([p respondsToSelector:set]) ((void (*)(id, SEL, id))objc_msgSend)(p, set, NSUUID.UUID.UUIDString);
    }
    return p;
}

// The content browser answers with a response object (9.x) or, in 8.6, with the array of items itself.
static NSArray *contentItems(id response) {
    if ([response isKindOfClass:NSArray.class]) return response;
    return [response respondsToSelector:@selector(items)] ? [response valueForKey:@"items"] : @[];
}

static void playItemEx(id c, id item, NSString *uri, BOOL shuffle, BOOL allowRetry);
static void playItem(id c, id item, NSString *uri, BOOL shuffle) { playItemEx(c, item, uri, shuffle, YES); }

static void playItemEx(id c, id item, NSString *uri, BOOL shuffle, BOOL allowRetry) {
    BOOL container = [uri hasPrefix:@"spotify:playlist:"] || [uri hasPrefix:@"spotify:album:"];
    void (^done)(void *, void *) = ^(void *a, void *b) {
        SPLog(@"play finished (%p %p)", a, b);
        // Spotify refuses to play a context that is already playing. Playing the context's first track as an item
        // (with its context) starts it over, which is what tapping the first song does.
        if (a && allowRetry && container) {
            SPLog(@"play refused, restarting %@ from its first track", uri);
            browseChildrenWith(uri, NO, nil, ^(id response, id error) {
                NSArray *items = contentItems(response);
                if (!items.firstObject) { SPLog(@"restart: no first track (%lu items)", (unsigned long)items.count); return; }
                playItemEx(c, items.firstObject, uri, shuffle, NO);
            });
            return;
        }
        if (shuffle) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                void (^sdone)(void *) = ^(void *x) { SPLog(@"shuffle finished (%p)", x); };
                ((void (*)(id, SEL, id))objc_msgSend)(c, @selector(enableShuffleWithCompletionHandler:), sdone);
            });
        }
    };
    if (![c respondsToSelector:@selector(playContentWithURI:withOptions:origin:loggingParams:completionHandler:)] && ![c respondsToSelector:@selector(playContent:withOptions:origin:loggingParams:completionHandler:)]) {
        SPLog(@"play: this Spotify version has no play call I know");
        return;
    }
    if (item && [c respondsToSelector:@selector(playContent:withOptions:origin:loggingParams:completionHandler:)]) {
        SPLog(@"play item %@", uri);
        ((void (*)(id, SEL, id, id, id, id, id))objc_msgSend)(c, @selector(playContent:withOptions:origin:loggingParams:completionHandler:), item, nil, makePlayOrigin(uri), makeLoggingParams(), done);
    } else if ([c respondsToSelector:@selector(playContentWithURI:withOptions:origin:loggingParams:completionHandler:)]) {
        NSURL *u = [NSURL URLWithString:uri];   // Spotify bridges this argument to a Swift URL, so it must be an NSURL
        ((void (*)(id, SEL, id, id, id, id, id))objc_msgSend)(c, @selector(playContentWithURI:withOptions:origin:loggingParams:completionHandler:), u, nil, makePlayOrigin(uri), makeLoggingParams(), done);
    } else {
        SPLog(@"play: no URI play call in this Spotify version");
    }
}

static void startPlayback(NSString *uri, BOOL shuffle) {
  @try {
    id c = findController();
    if (!c) { SPLog(@"play %@: no playback controller", uri); return; }
    BOOL container = [uri hasPrefix:@"spotify:playlist:"] || [uri hasPrefix:@"spotify:album:"] || [uri hasPrefix:@"spotify:artist:"];
    SPLog(@"play %@ shuffle=%d", uri, shuffle);
    playItem(c, container ? contentItemForURI(uri) : nil, uri, shuffle);
  } @catch (NSException *e) { SPLog(@"play failed: %@", e); }
}

static void handleLink(NSURL *url) {
    if (!url || !prefBool(@"enabled", YES)) return;
    BOOL shuffle;
    NSString *uri = parseLink(url, &shuffle);
    if (!uri) return;
    // The same link can reach more than one delegate (Spotify's and its Branch wrapper); play it once.
    static NSString *lastURI;
    static CFAbsoluteTime lastTime;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if ([uri isEqualToString:lastURI] && now - lastTime < 3) return;
    lastURI = uri;
    lastTime = now;
    SPLog(@"link %@", url);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ startPlayback(uri, shuffle); });
}

// ---- command file -------------------------------------------------------------------------------------------
// The zefy command writes a link to Documents/zefyreborn.cmd. That folder is watched while the app
// runs, and the file is also looked at once after launch for the case where Spotify was not running.

static NSString *commandPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"zefyreborn.cmd"];
}

// Quick Play: SpringBoard launches Spotify in the background and asks it to resume. The controller can take a
// few seconds to exist after a cold launch, so retry for a while.
static void postNote(const char *name, uint64_t state);
static int gResumeTries;
static void resumePlayback(int attempt) {
    id c = findController();
    if (!c) {
        if (attempt < 40) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ resumePlayback(attempt + 1); });
        else SPLog(@"resume: no playback controller");
        return;
    }
    SPLog(@"resume via controller (attempt %d)", attempt);
    __block BOOL answered = NO;
    void (^done)(void *) = ^(void *x) {
        answered = YES;
        SPLog(@"resume finished (%p)", x);
        // Just after Spotify wakes, a resume can be refused while it catches up, so try again a few times.
        if (x && gResumeTries < 3) {
            gResumeTries++;
            SPLog(@"resume refused, trying again (%d)", gResumeTries);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ resumePlayback(0); });
            return;
        }
        if (x) postNote("com.goldenappleguy.zefyreborn.resumefailed", 1);   // still refused: SpringBoard stops saying "Starting"
    };
    ((void (*)(id, SEL, id))objc_msgSend)(c, @selector(resumeWithCompletionHandler:), done);
    // Older Spotify versions (8.6 on iOS 14) drop a resume sent before the player has loaded and never answer it,
    // so a resume that gets no answer is sent again.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (answered || gResumeTries >= 5) return;
        gResumeTries++;
        SPLog(@"resume not answered, trying again (%d)", gResumeTries);
        resumePlayback(0);
    });
}

// ---- playback controls from the command file ---------------------------------------------------------------
// "zefyreborn:cmd <name> [argument]" lines written by the zefy command. Spotify decides what an
// account may do, so a refused control simply has no effect.

static BOOL playerPosition(id c, double *out) {
    id ps = ((id (*)(id, SEL))objc_msgSend)(c, @selector(playerState));
    for (NSString *name in @[@"position", @"currentPosition", @"playbackPosition"]) {
        SEL sel = NSSelectorFromString(name);
        Method m = ps ? class_getInstanceMethod(object_getClass(ps), sel) : NULL;
        if (!m) continue;
        char type = method_getTypeEncoding(m)[0];
        if (type == 'd') *out = ((double (*)(id, SEL))objc_msgSend)(ps, sel);
        else if (type == 'q' || type == 'Q') *out = (double)((long long (*)(id, SEL))objc_msgSend)(ps, sel) / 1000.0;
        else continue;
        SPLog(@"player position via %@: %.2f", name, *out);
        return YES;
    }
    SPLog(@"player position: no accessor on %@", ps ? NSStringFromClass(object_getClass(ps)) : @"(nil state)");
    return NO;
}

static NSURL *webURLForLink(NSString *link) {
    NSURL *u = [NSURL URLWithString:link];
    if ([u.scheme isEqualToString:@"spotify"]) {
        NSArray *seg = [[u.resourceSpecifier componentsSeparatedByString:@"?"].firstObject componentsSeparatedByString:@":"];
        NSUInteger at = [seg.firstObject isEqualToString:@"user"] ? 2 : 0;
        if (seg.count < at + 2) return nil;
        return [NSURL URLWithString:[NSString stringWithFormat:@"https://open.spotify.com/%@/%@", seg[at], seg[at + 1]]];
    }
    return u;
}

// Opens a page in Spotify without playing it, by handing the app a web-link activity as if a link was tapped.
static void navigateTo(NSString *link) {
    NSURL *web = webURLForLink(link);
    if (!web) { SPLog(@"navigate: bad link %@", link); return; }
    NSUserActivity *act = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    act.webpageURL = web;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        id del = scene.delegate;
        if ([del respondsToSelector:@selector(scene:continueUserActivity:)]) {
            SPLog(@"navigate: %@ via %@", web, NSStringFromClass([del class]));
            ((void (*)(id, SEL, id, id))objc_msgSend)(del, @selector(scene:continueUserActivity:), scene, act);
            return;
        }
    }
    SPLog(@"navigate: no scene delegate");
}

static void runControllerCommand(NSString *name, NSString *arg, int attempt) {
    id c = findController();
    if (!c) {
        if (attempt < 40) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ runControllerCommand(name, arg, attempt + 1); });
        else SPLog(@"%@: no playback controller", name);
        return;
    }
    void (^done)(void *) = ^(void *x) { SPLog(@"%@ finished (%p)", name, x); };
    void (^plain)(SEL) = ^(SEL sel) { ((void (*)(id, SEL, id))objc_msgSend)(c, sel, done); };
    SPLog(@"%@ %@", name, arg ?: @"");
    if ([name isEqualToString:@"shuffle"]) {
        int mode = arg.intValue;   // 0 off, 1 on, 2 toggle
        if (mode == 2) {
            id ps = ((id (*)(id, SEL))objc_msgSend)(c, @selector(playerState));
            unsigned long state = ((unsigned long (*)(id, SEL, id))objc_msgSend)(c, @selector(getShuffleStateWithPlayerState:), ps);
            mode = state ? 0 : 1;
        }
        plain(mode ? @selector(enableShuffleWithCompletionHandler:) : @selector(disableShuffleWithCompletionHandler:));
    } else if ([name isEqualToString:@"repeat"]) {
        int mode = arg.intValue;   // 0 off, 1 track, 2 context
        plain(mode == 1 ? @selector(repeatTrackWithCompletionHandler:) : mode == 2 ? @selector(repeatContextWithCompletionHandler:) : @selector(disableRepeatWithCompletionHandler:));
    } else if ([name isEqualToString:@"next"]) {
        plain(@selector(skipToNextTrackWithCompletionHandler:));
    } else if ([name isEqualToString:@"prev"]) {
        plain(@selector(skipToPreviousTrackWithCompletionHandler:));
    } else if ([name isEqualToString:@"pause"]) {
        plain(@selector(pauseWithCompletionHandler:));
    } else if ([name isEqualToString:@"resume"]) {
        gResumeTries = 0;
        resumePlayback(0);   // the same path as Quick Play, so it also retries when a background wake stops the audio
    } else if ([name isEqualToString:@"seek"]) {
        double pos;
        if (!playerPosition(c, &pos)) return;
        double target = MAX(0, pos + arg.doubleValue);
        SPLog(@"seek %.2f -> %.2f", pos, target);
        ((void (*)(id, SEL, double, id))objc_msgSend)(c, @selector(seekTo:completionHandler:), target, done);
    } else if ([name isEqualToString:@"queue"]) {
        NSURL *u = [NSURL URLWithString:arg];   // bridged to a Swift URL like the play call
        ((void (*)(id, SEL, id, id))objc_msgSend)(c, @selector(enqueueTrackWithURI:completionHandler:), u, done);
    } else {
        SPLog(@"unknown command %@", name);
    }
}

// Debug aid: lists the classes in Spotify that implement the given selectors, with live instance counts.
static void dumpClass(Class c) {
    if (!c) return;
    SPLog(@"class %s : %s", class_getName(c), class_getName(class_getSuperclass(c)));
    unsigned mc = 0;
    Method *ms = class_copyMethodList(c, &mc);
    for (unsigned j = 0; j < mc; j++) SPLog(@"  - %s  %s", sel_getName(method_getName(ms[j])), method_getTypeEncoding(ms[j]));
    free(ms);
}

static void runProbe(NSString *list) {
    if ([list hasPrefix:@"classes:"]) {
        NSString *needle = [list substringFromIndex:8];
        unsigned n = 0;
        Class *all = objc_copyClassList(&n);
        for (unsigned i = 0; i < n; i++) {
            const char *img = class_getImageName(all[i]);
            if (img && strstr(img, "/Spotify.app/") && [NSStringFromClass(all[i]) rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound)
                SPLog(@"class %@", NSStringFromClass(all[i]));
        }
        free(all);
        return;
    }
    if ([list hasPrefix:@"class:"]) { for (NSString *cn in [[list substringFromIndex:6] componentsSeparatedByString:@","]) dumpClass(NSClassFromString(cn)); return; }
    if ([list isEqualToString:@"queue"]) {
        id c = findController();
        void (^done)(id, id) = ^(id queue, id error) {
            SPLog(@"queue: %@ error %@", queue ? NSStringFromClass(object_getClass(queue)) : @"nil", error);
            for (id item in (NSArray *)queue) SPLog(@"queue item | %@ | %@ | %@", [item valueForKey:@"title"], [item valueForKey:@"subtitle"], [item valueForKey:@"URI"]);
        };
        if (c) ((void (*)(id, SEL, id))objc_msgSend)(c, @selector(getFilteredPlayQueueWithCompletionHandler:), done);
        return;
    }
    if ([list isEqualToString:@"state"]) {
        id c = findController();
        id ps = c ? ((id (*)(id, SEL))objc_msgSend)(c, @selector(playerState)) : nil;
        SPLog(@"playerState %@", ps ? NSStringFromClass(object_getClass(ps)) : @"nil");
        if (ps) {
            id track = [ps valueForKey:@"track"];
            BOOL has = [track respondsToSelector:NSSelectorFromString(@"spt_isAutoplayEnabled")];
            for (NSString *key in @[@"restrictions", @"options"]) {
                @try { SPLog(@"state.%@ = %@", key, [ps valueForKey:key]); } @catch (NSException *e) {}
            }
            SPLog(@"track %@ autoplay flag %@", [track description], has ? @(((BOOL (*)(id, SEL))objc_msgSend)(track, NSSelectorFromString(@"spt_isAutoplayEnabled"))) : @"(no selector)");
            for (NSString *key in @[@"metadata", @"title", @"name", @"trackTitle", @"albumTitle", @"artistName", @"spt_artistsString", @"spt_subtitle"]) {
                @try { SPLog(@"track.%@ = %@", key, [track valueForKey:key]); } @catch (NSException *e) { SPLog(@"track.%@ n/a", key); }
            }
        }
        return;
    }
    NSArray *sels = [list componentsSeparatedByString:@","];
    unsigned count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned i = 0; i < count; i++) {
        const char *img = class_getImageName(classes[i]);
        if (!img || !strstr(img, "/Spotify.app/")) continue;
        for (NSString *name in sels) {
            Method m = class_getInstanceMethod(classes[i], NSSelectorFromString(name));
            if (m) SPLog(@"probe %s -%@ %s", class_getName(classes[i]), name, method_getTypeEncoding(m));
        }
    }
    free(classes);
}

// ---- library controls on the playing track ---------------------------------------------------------------

// The playing track's URI, read from the player state's description ("SPTPlayerTrack:spotify:track:<id>").
static NSURL *currentTrackURI(id playback) {
    id ps = ((id (*)(id, SEL))objc_msgSend)(playback, @selector(playerState));
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"spotify:track:[A-Za-z0-9]+" options:0 error:nil];
    NSString *desc = [ps description] ?: @"";
    NSTextCheckingResult *m = [re firstMatchInString:desc options:0 range:NSMakeRange(0, desc.length)];
    return m ? [NSURL URLWithString:[desc substringWithRange:m.range]] : nil;
}

static void runCollectionCommand(NSString *name, NSString *arg, int attempt) {
    id playback = findController(), coll = findInstance(kCollectionClass);
    if (!playback || !coll) {
        if (attempt < 40) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ runCollectionCommand(name, arg, attempt + 1); });
        else SPLog(@"%@: controllers not found", name);
        return;
    }
    NSURL *track = currentTrackURI(playback);
    if (!track) { SPLog(@"%@: nothing is playing", name); return; }
    void (^done)(void *) = ^(void *x) { SPLog(@"%@ finished (%p)", name, x); };
    SPLog(@"%@ %@ track %@", name, arg ?: @"", track);
    if ([name isEqualToString:@"like"]) {
        int mode = arg.intValue;   // 0 unlike, 1 like, 2 toggle
        void (^apply)(int) = ^(int m) {
            if (m) ((void (*)(id, SEL, id, id, id))objc_msgSend)(coll, @selector(addContentToCollectionWithURI:fromContext:completionHandler:), track, nil, done);
            else ((void (*)(id, SEL, id, id))objc_msgSend)(coll, @selector(removeContentFromCollectionWithURI:completionHandler:), track, done);
        };
        if (mode == 2) {
            void (^check)(BOOL, void *) = ^(BOOL liked, void *err) { SPLog(@"liked=%d (%p)", liked, err); apply(!liked); };
            ((void (*)(id, SEL, id, id))objc_msgSend)(coll, @selector(collectionContainsContentWithURI:completionHandler:), track, check);
        } else {
            apply(mode);
        }
    } else if ([name isEqualToString:@"liked"]) {
        void (^check)(BOOL, void *) = ^(BOOL liked, void *err) { SPLog(@"liked=%d (%p)", liked, err); };
        ((void (*)(id, SEL, id, id))objc_msgSend)(coll, @selector(collectionContainsContentWithURI:completionHandler:), track, check);
    } else if ([name isEqualToString:@"playlist-has"]) {
        NSURL *playlist = [NSURL URLWithString:arg];
        void (^has)(BOOL, void *) = ^(BOOL yes, void *err) { SPLog(@"in playlist=%d (%p)", yes, err); };
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(coll, @selector(isCuratedWithURI:contextURI:completionHandler:), track, playlist, has);
    } else if ([name isEqualToString:@"playlist-add"] || [name isEqualToString:@"playlist-remove"]) {
        // curateWithURI:contextURI: toggles, so look first and only change what needs changing.
        NSURL *playlist = [NSURL URLWithString:arg];
        BOOL want = [name isEqualToString:@"playlist-add"];
        void (^has)(BOOL, void *) = ^(BOOL yes, void *err) {
            if (yes == want) { SPLog(@"%@: track is already %@", name, want ? @"in the playlist" : @"out of the playlist"); return; }
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(coll, @selector(curateWithURI:contextURI:completionHandler:), track, playlist, done);
        };
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(coll, @selector(isCuratedWithURI:contextURI:completionHandler:), track, playlist, has);
    }
}

// ---- browsing Spotify's own content tree (the one CarPlay uses) -------------------------------------------

// Resolves the children of a node such as spotify:collection:playlists and hands back the response object.
static void browseChildrenWith(NSString *parent, BOOL entityPages, NSString *locale, void (^completion)(id response, id error)) {
    id cc = findInstance(kContentClass);
    if (!cc) { SPLog(@"browse: no content controller"); completion(nil, nil); return; }
    // Other Spotify versions name or shape these calls differently; skip quietly instead of crashing the app.
    // The option builder's name differs in every Spotify version (the tail after enableEntityPages: changes). The
    // versions checked so far are called with their exact argument lists; for an unknown one, the method with the
    // longest name that starts the same way is called with the leading arguments, which are plain registers.
    NSString *head = @"makeContentRequestOptions:offlineOnly:enableEntityPages:debugLogTags:spacesLocaleOverride:libraryCollectionRootFormat:browseGenreFormat:overrideRecentlyPlayedPlaceholder:synchronize:";
    SEL makeNew = NSSelectorFromString([head stringByAppendingString:@"libraryContentPreferences:"]);   // 9.1
    SEL makeTags = NSSelectorFromString([head stringByAppendingString:@"tags:"]);                        // 9.0
    SEL makeShort = NSSelectorFromString(head);                                                           // 9.0, shorter
    SEL makeLiked = NSSelectorFromString(@"makeContentRequestOptions:offlineOnly:enableEntityPages:debugLogTags:spacesLocaleOverride:likedSongsInPlayLists:");   // 8.6
    SEL resolve = @selector(resolveChildContentOfParentWithURI:options:requestOrigin:withCompletionHandler:);
    SEL makeSel = NULL;
    for (NSValue *v in @[[NSValue valueWithPointer:makeNew], [NSValue valueWithPointer:makeTags], [NSValue valueWithPointer:makeShort], [NSValue valueWithPointer:makeLiked]]) {
        if ([cc respondsToSelector:v.pointerValue]) { makeSel = v.pointerValue; break; }
    }
    BOOL known = makeSel != NULL;
    if (!makeSel) {
        unsigned methodCount = 0;
        Method *methods = class_copyMethodList(object_getClass(cc), &methodCount);
        for (unsigned i = 0; i < methodCount; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if ([name hasPrefix:@"makeContentRequestOptions:offlineOnly:enableEntityPages:"] && (!makeSel || name.length > NSStringFromSelector(makeSel).length)) makeSel = method_getName(methods[i]);
        }
        free(methods);
    }
    if (!makeSel || ![cc respondsToSelector:@selector(canResolveChildContentWithParentURI:)] || ![cc respondsToSelector:resolve]) {
        SPLog(@"browse: this Spotify version has no content browser API");
        completion(nil, nil);
        return;
    }
    if (!known) SPLog(@"browse: unknown option builder %@", NSStringFromSelector(makeSel));
    id opts;
    if (makeSel == makeShort) {
        opts = ((id (*)(id, SEL, unsigned long long, BOOL, BOOL, id, id, long long, long long, BOOL, BOOL))objc_msgSend)(cc, makeSel, 100, NO, entityPages, nil, locale, 0, 0, NO, NO);
    } else if (makeSel == makeLiked) {
        opts = ((id (*)(id, SEL, unsigned long long, BOOL, BOOL, id, id, BOOL))objc_msgSend)(cc, makeSel, 100, NO, entityPages, nil, locale, NO);
    } else {
        opts = ((id (*)(id, SEL, unsigned long long, BOOL, BOOL, id, id, long long, long long, BOOL, BOOL, id))objc_msgSend)(cc, makeSel, 100, NO, entityPages, nil, locale, 0, 0, NO, NO, nil);
    }
    BOOL can = ((BOOL (*)(id, SEL, id))objc_msgSend)(cc, @selector(canResolveChildContentWithParentURI:), [NSURL URLWithString:parent]);
    SPLog(@"browse %@ canResolve=%d options %@", parent, can, opts ? NSStringFromClass(object_getClass(opts)) : @"nil");
    void (^done)(id, id) = ^(id response, id error) { completion(response, error); };
    ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(cc, @selector(resolveChildContentOfParentWithURI:options:requestOrigin:withCompletionHandler:), [NSURL URLWithString:parent], opts, nil, done);
}

static NSString *playableURI(NSString *uri);

// Plays a random item from one of Spotify's own lists: recent, library (playlists) or albums.
static void playRandom(NSString *source) {
    NSDictionary *parents = @{@"recent": @"spotify:recently-played", @"library": @"spotify:playlists", @"albums": @"spotify:collection:albums"};
    NSString *parent = parents[source];
    if (!parent) { SPLog(@"random: unknown source %@", source); return; }
    browseChildrenWith(parent, NO, nil, ^(id response, id error) {
        NSArray *items = contentItems(response);
        NSMutableArray *playable = [NSMutableArray array];
        for (id item in items) {
            NSString *uri = playableURI([[item valueForKey:@"URI"] description]);
            if ([uri hasPrefix:@"spotify:playlist:"] || [uri hasPrefix:@"spotify:album:"] || [uri hasPrefix:@"spotify:artist:"]) [playable addObject:item];
        }
        if (!playable.count) { SPLog(@"random %@: nothing to pick (%lu items, error %@)", source, (unsigned long)items.count, error); return; }
        // Asking Spotify to play what is already playing does nothing, so leave out the last pick when there is a choice.
        static NSString *lastPick;
        NSMutableArray *choices = [playable mutableCopy];
        if (choices.count > 1) [choices filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id item, NSDictionary *b) { return ![[[item valueForKey:@"URI"] description] isEqualToString:lastPick]; }]];
        id pick = choices[arc4random_uniform((uint32_t)choices.count)];
        lastPick = [[pick valueForKey:@"URI"] description];
        SPLog(@"random %@: %lu to choose from, picked %@", source, (unsigned long)playable.count, [pick valueForKey:@"title"]);
        id c = findController();
        NSString *pickURI = [[pick valueForKey:@"URI"] description];
        if ([pickURI containsString:@":collection:artist:"]) startPlayback(playableURI(pickURI), NO);
        else if (c) playItem(c, pick, playableURI(pickURI), NO);
    });
}

// ---- results for the zefy command ------------------------------------------------------------------
// Commands that answer (play by name, status) write the answer to Documents/zefyreborn.result, which the
// zefy command waits for and prints.

static void writeResult(NSString *text) {
    NSString *path = [[settingsFile() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"zefyreborn.result"];
    [[text stringByAppendingString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// ---- play by name ---------------------------------------------------------------------------------------------

static NSString *normalized(NSString *text) {
    NSString *folded = [text stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:nil];
    NSMutableString *out = [NSMutableString string];
    for (NSString *word in [folded componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]])
        if (word.length) [out appendFormat:@"%@%@", out.length ? @" " : @"", word];
    return out;
}

// 100 exact, 80 starts with, 60 has every word, 40 contains the whole text, 0 no match.
static int matchScore(NSString *title, NSString *query) {
    NSString *t = normalized(title), *q = normalized(query);
    if (!q.length || !t.length) return 0;
    if ([t isEqualToString:q]) return 100;
    if ([t hasPrefix:q]) return 80;
    BOOL all = YES;
    for (NSString *w in [q componentsSeparatedByString:@" "]) if ([t rangeOfString:w].location == NSNotFound) { all = NO; break; }
    if (all) return 60;
    return [t containsString:q] ? 40 : 0;
}

static void browseChildrenWith(NSString *parent, BOOL entityPages, NSString *locale, void (^completion)(id response, id error));

static void collectItems(NSArray *parents, NSUInteger index, NSMutableArray *found, void (^done)(NSArray *)) {
    if (index >= parents.count) { done(found); return; }
    browseChildrenWith(parents[index], NO, nil, ^(id response, id error) {
        for (id item in contentItems(response)) [found addObject:item];
        collectItems(parents, index + 1, found, done);
    });
}

// A library artist is listed as spotify:user:<name>:collection:artist:<id>, which Spotify cannot play; the
// artist's own URI can.
static NSString *playableURI(NSString *uri) {
    NSRange r = [uri rangeOfString:@":collection:artist:"];
    if (r.location != NSNotFound) return [@"spotify:artist:" stringByAppendingString:[uri substringFromIndex:NSMaxRange(r)]];
    // Spotify 8.6 lists saved albums as spotify:user:<name>:collection:album:<id>.
    r = [uri rangeOfString:@":collection:album:"];
    if (r.location != NSNotFound) return [@"spotify:album:" stringByAppendingString:[uri substringFromIndex:NSMaxRange(r)]];
    return uri;
}

static void playByName(NSString *kind, NSString *query) {
    NSDictionary *sources = @{@"playlist": @[@"spotify:playlists"], @"album": @[@"spotify:collection:albums"], @"artist": @[@"spotify:collection:artists"],
                              @"any": @[@"spotify:playlists", @"spotify:collection:albums", @"spotify:collection:artists", @"spotify:recently-played"]};
    NSArray *parents = sources[kind];
    if (!parents || !query.length) { writeResult(@"usage: zefy --playlist|--album|--artist|--find <name>"); return; }
    collectItems(parents, 0, [NSMutableArray array], ^(NSArray *items) {
        id best = nil;
        int bestScore = 0;
        for (id item in items) {
            int score = matchScore([[item valueForKey:@"title"] description], query);
            if (score > bestScore) { best = item; bestScore = score; }
        }
        id c = findController();
        if (!best || !c) { writeResult([NSString stringWithFormat:@"No match for \"%@\" in your library", query]); SPLog(@"by name %@: no match", query); return; }
        NSString *uri = [[best valueForKey:@"URI"] description];
        NSString *subtitle = [[best valueForKey:@"subtitle"] description];
        SPLog(@"by name %@: %@ (%d)", query, [best valueForKey:@"title"], bestScore);
        writeResult([NSString stringWithFormat:@"Playing %@%@", [best valueForKey:@"title"], subtitle.length && ![subtitle isEqualToString:@"(null)"] ? [@" - " stringByAppendingString:subtitle] : @""]);
        if ([uri containsString:@":collection:artist:"]) startPlayback(playableURI(uri), NO);
        else playItem(c, best, playableURI(uri), NO);
    });
}

static void runCommandLineUnsafe(NSString *line);

static void runCommandLine(NSString *line) {
    @try { runCommandLineUnsafe(line); }
    @catch (NSException *e) { SPLog(@"command failed (%@): %@", line, e); }
}

static void runCommandLineUnsafe(NSString *line) {
    NSString *rest = [line substringFromIndex:kCommandPrefix.length];
    NSRange sp = [rest rangeOfString:@" "];
    NSString *name = sp.location == NSNotFound ? rest : [rest substringToIndex:sp.location];
    NSString *arg = sp.location == NSNotFound ? nil : [rest substringFromIndex:sp.location + 1];
    if ([@[@"probe", @"instances", @"browse", @"resolve", @"playcontent", @"playraw"] containsObject:name] && !debugEnabled()) { SPLog(@"%@: debug commands need the debug flag", name); return; }
    if ([name isEqualToString:@"navigate"]) { navigateTo(arg); return; }
    if ([name isEqualToString:@"playraw"]) {
        // Debug: start a URI directly, without the tweak's own handling.
        id c = findController();
        void (^done)(void *, void *) = ^(void *a, void *b) { SPLog(@"playraw finished (%p %p)", a, b); };
        if (c) ((void (*)(id, SEL, id, id, id, id, id))objc_msgSend)(c, @selector(playContentWithURI:withOptions:origin:loggingParams:completionHandler:), [NSURL URLWithString:arg], nil, makePlayOrigin(arg), makeLoggingParams(), done);
        return;
    }
    if ([name isEqualToString:@"playcontent"]) {
        // Debug: browse a node and play its item at an index through the content-item play call.
        NSArray *parts = [arg componentsSeparatedByString:@" "];
        NSUInteger index = parts.count > 1 ? (NSUInteger)[parts[1] integerValue] : 0;
        browseChildrenWith(parts[0], NO, nil, ^(id response, id error) {
            NSArray *items = contentItems(response);
            if (index >= items.count) { SPLog(@"playcontent: no item %lu of %lu", (unsigned long)index, (unsigned long)items.count); return; }
            id item = items[index], c = findController();
            SPLog(@"playcontent: %@ (%@)", [item valueForKey:@"title"], [item valueForKey:@"URI"]);
            void (^done)(void *, void *) = ^(void *a, void *b) { SPLog(@"playcontent finished (%p %p)", a, b); };
            ((void (*)(id, SEL, id, id, id, id, id))objc_msgSend)(c, @selector(playContent:withOptions:origin:loggingParams:completionHandler:), item, nil, makePlayOrigin(parts[0]), makeLoggingParams(), done);
        });
        return;
    }
    if ([name isEqualToString:@"resolve"]) {
        id cc = findInstance(kContentClass);
        id opts = ((id (*)(id, SEL, unsigned long long, BOOL, BOOL, id, id, long long, long long, BOOL, BOOL, id))objc_msgSend)(
            cc, @selector(makeContentRequestOptions:offlineOnly:enableEntityPages:debugLogTags:spacesLocaleOverride:libraryCollectionRootFormat:browseGenreFormat:overrideRecentlyPlayedPlaceholder:synchronize:libraryContentPreferences:), 100, NO, NO, nil, nil, 0, 0, NO, NO, nil);
        void (^done)(id, id) = ^(id response, id error) {
            NSArray *items = contentItems(response);
            SPLog(@"resolve result: %lu items, error %@", (unsigned long)items.count, error);
            for (id item in items) SPLog(@"resolved | %@ | %@ | %@ | context=%@ skipTo=%@", [item valueForKey:@"title"], [item valueForKey:@"subtitle"], [item valueForKey:@"URI"], [item valueForKey:@"contextURI"], [item valueForKey:@"skipToTrack"]);
        };
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(cc, @selector(resolveContentWithURI:options:withCompletionHandler:), [NSURL URLWithString:arg], opts, done);
        return;
    }
    if ([name isEqualToString:@"random"]) { playRandom(arg); return; }
    if ([name isEqualToString:@"by-name"]) {
        NSRange sp = [arg rangeOfString:@" "];
        playByName(sp.location == NSNotFound ? arg : [arg substringToIndex:sp.location], sp.location == NSNotFound ? @"" : [arg substringFromIndex:sp.location + 1]);
        return;
    }
    if ([name isEqualToString:@"probe"]) { runProbe(arg); return; }
    if ([name isEqualToString:@"browse"]) {
        NSArray *parts = [arg componentsSeparatedByString:@" "];   // uri [entity] [locale]
        browseChildrenWith(parts[0], parts.count > 1 && [parts[1] isEqualToString:@"entity"], parts.count > 2 ? parts[2] : nil, ^(id response, id error) {
            SPLog(@"browse result: %@ / error %@", response ? NSStringFromClass(object_getClass(response)) : @"nil", error);
            NSString *d = [response description] ?: @"";
            SPLog(@"%@", d.length > 6000 ? [d substringToIndex:6000] : d);
            NSArray *items = contentItems(response);
            SPLog(@"items: %lu", (unsigned long)items.count);
            for (id item in [items subarrayWithRange:NSMakeRange(0, MIN(items.count, 40))])
                SPLog(@"item | %@ | %@ | %@ | container=%@ children=%lu context=%@ skipTo=%@ view=%@ image=%@ icon=%@", [item valueForKey:@"title"], [item valueForKey:@"subtitle"], [item valueForKey:@"URI"], [item valueForKey:@"isContainer"], (unsigned long)[[item valueForKey:@"children"] count], [item valueForKey:@"contextURI"], [item valueForKey:@"skipToTrack"], [item valueForKey:@"viewURI"], [item valueForKey:@"imageURI"], [item valueForKey:@"placeholderIcon"]);
        });
        return;
    }
    if ([name isEqualToString:@"likedsongs"]) {
        // Liked Songs is listed in the library like a playlist, with its own URI.
        browseChildrenWith(@"spotify:playlists", NO, nil, ^(id response, id error) {
            for (id item in contentItems(response)) {
                if ([[item valueForKey:@"title"] isEqualToString:@"Liked Songs"]) { startPlayback([[item valueForKey:@"URI"] description], NO); return; }
            }
            SPLog(@"liked songs: not found in the library list (error %@)", error);
        });
        return;
    }
    if ([name isEqualToString:@"radio"]) {
        // Radio from the given track, album, artist or playlist URI, else from the playing track.
        NSString *uri = arg.length ? arg : currentTrackURI(findController()).absoluteString;
        if (![uri hasPrefix:@"spotify:"]) { SPLog(@"radio: no source"); return; }
        startPlayback([@"spotify:station:" stringByAppendingString:[uri substringFromIndex:8]], NO);
        return;
    }
    if ([name isEqualToString:@"like"] || [name isEqualToString:@"liked"] || [name isEqualToString:@"playlist-has"] || [name isEqualToString:@"playlist-add"] || [name isEqualToString:@"playlist-remove"]) { runCollectionCommand(name, arg, 0); return; }
    if ([name isEqualToString:@"instances"]) { for (NSString *cn in [arg componentsSeparatedByString:@","]) findInstance(cn); return; }
    runControllerCommand(name, arg, 0);
}

static void checkCommandFile(void) {
    NSString *path = commandPath();
    NSDate *written = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
    NSString *link = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!link.length) return;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    SPLog(@"command file: %@ (written %.0f ms earlier)", link, written ? -[written timeIntervalSinceNow] * 1000 : -1.0);
    // A command left behind while Spotify was not running (a sleep-timer pause, say) must not fire at the next launch.
    if (written && -[written timeIntervalSinceNow] > 30) { SPLog(@"ignored a stale command"); return; }
    if (![link hasPrefix:@"zefyreborn:"] && !prefBool(@"enabled", YES)) return;
    if ([link isEqualToString:kResumeCommand]) { if (prefBool(@"enabled", YES)) { gResumeTries = 0; resumePlayback(0); } return; }
    if ([link hasPrefix:kCommandPrefix]) { if (prefBool(@"enabled", YES)) runCommandLine(link); return; }
    handleLink([NSURL URLWithString:link]);
}

static dispatch_source_t gWatch;   // must stay referenced or the watch is cancelled

static void watchCommandFile(void) {
    int fd = open(commandPath().stringByDeletingLastPathComponent.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) return;
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd, DISPATCH_VNODE_WRITE, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{ checkCommandFile(); });
    dispatch_source_set_cancel_handler(src, ^{ close(fd); });
    gWatch = src;
    dispatch_resume(src);
}

// ---- hooks on the scene delegate --------------------------------------------------------------------------
// Each delegate method is replaced by a wrapper that looks at the link, then calls the original, which is
// kept under a prefixed selector.

static SEL origOf(SEL sel) { return NSSelectorFromString([kOrigPrefix stringByAppendingString:NSStringFromSelector(sel)]); }

static void wrap(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m || class_getInstanceMethod(cls, origOf(sel))) return;
    class_addMethod(cls, origOf(sel), method_getImplementation(m), method_getTypeEncoding(m));
    method_setImplementation(m, imp);
}

static void spOpenURLContexts(id self, SEL _cmd, UIScene *scene, NSSet *contexts) {
    for (UIOpenURLContext *c in contexts) handleLink(c.URL);
    ((void (*)(id, SEL, id, id))objc_msgSend)(self, origOf(_cmd), scene, contexts);
}

static void spWillConnect(id self, SEL _cmd, UIScene *scene, UISceneSession *session, UISceneConnectionOptions *opts) {
    for (UIOpenURLContext *c in opts.URLContexts) handleLink(c.URL);
    for (NSUserActivity *a in opts.userActivities) handleLink(a.webpageURL);
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(self, origOf(_cmd), scene, session, opts);
}

static void spContinue(id self, SEL _cmd, UIScene *scene, NSUserActivity *act) {
    handleLink(act.webpageURL);
    ((void (*)(id, SEL, id, id))objc_msgSend)(self, origOf(_cmd), scene, act);
}

static void wrapSceneDelegate(Class c) {
    wrap(c, @selector(scene:openURLContexts:), (IMP)spOpenURLContexts);
    wrap(c, @selector(scene:willConnectToSession:options:), (IMP)spWillConnect);
    wrap(c, @selector(scene:continueUserActivity:), (IMP)spContinue);
}

// ---- recents file for the Control Center row ---------------------------------------------------------------
// Documents/zefyreborn.recents holds Spotify's recently played list (uri, title, subtitle, image), one tab-separated
// line each, so SpringBoard can show it while Spotify is closed.

static CFAbsoluteTime gRecentsWritten;

static void writeRecents(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gRecentsWritten < 20) return;
    gRecentsWritten = now;
    browseChildrenWith(@"spotify:recently-played", NO, nil, ^(id response, id error) {
      @try {
        NSMutableString *text = [NSMutableString string];
        for (id item in contentItems(response)) {
            NSString *uri = [[item valueForKey:@"URI"] description];
            if (![uri hasPrefix:@"spotify:playlist:"] && ![uri hasPrefix:@"spotify:album:"] && ![uri hasPrefix:@"spotify:artist:"]) continue;
            NSString *(^clean)(id) = ^NSString *(id v) { NSString *t = v ? [v description] : @""; return [[t stringByReplacingOccurrencesOfString:@"\t" withString:@" "] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]; };
            [text appendFormat:@"%@\t%@\t%@\t%@\n", uri, clean([item valueForKey:@"title"]), clean([item valueForKey:@"subtitle"]), clean([item valueForKey:@"imageURI"])];
        }
        if (!text.length) return;
        NSString *path = [[settingsFile() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"zefyreborn.recents"];
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        SPLog(@"recents written (%lu lines)", (unsigned long)[text componentsSeparatedByString:@"\n"].count - 1);
      } @catch (NSException *e) { SPLog(@"recents failed: %@", e); }
    });
}

// ---- Now Playing: a status file and notifications for RC ------------------------------------------------
// The playback controller is told about every player state change. When the track or the paused state changes,
// Documents/zefyreborn.nowplaying is rewritten and Darwin notifications are posted:
//   com.goldenappleguy.zefyreborn.trackchanged  (state 1)
//   com.goldenappleguy.zefyreborn.playstate     (state 1 playing, 0 paused)

// The state of a notification lives only while a registration for it stays open, so the tokens are kept.
static void postNote(const char *name, uint64_t state) {
    static NSMutableDictionary *tokens;
    if (!tokens) tokens = [NSMutableDictionary dictionary];
    NSString *key = @(name);
    NSNumber *t = tokens[key];
    if (!t) {
        int token;
        if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) return;
        t = @(token);
        tokens[key] = t;
    }
    notify_set_state(t.intValue, state);
    notify_post(name);
}

static NSString *gNowURI;
static int gNowPlaying = -1;

static void writeNowPlaying(id state, NSString *liked) {
    id track = [state valueForKey:@"track"];
    NSMutableString *text = [NSMutableString string];
    for (NSArray *pair in @[@[@"title", @"trackTitle"], @[@"artist", @"artistName"], @[@"album", @"albumTitle"]]) {
        id v = nil;
        @try { v = [track valueForKey:pair[1]]; } @catch (NSException *e) {}
        [text appendFormat:@"%@=%@\n", pair[0], v ?: @""];
    }
    [text appendFormat:@"uri=%@\nplaying=%d\nliked=%@\nupdated=%.0f\n", gNowURI ?: @"", gNowPlaying > 0, liked ?: @"", [NSDate date].timeIntervalSince1970];
    NSString *path = [[settingsFile() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"zefyreborn.nowplaying"];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void onPlayerStateUnsafe(id state);

static void onPlayerState(id state) {
    @try { onPlayerStateUnsafe(state); }
    @catch (NSException *e) { SPLog(@"player state failed: %@", e); }
}

static void onPlayerStateUnsafe(id state) {
    if (!state) return;
    NSString *desc = [state description] ?: @"";
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"spotify:track:[A-Za-z0-9]+|spotify:episode:[A-Za-z0-9]+" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:desc options:0 range:NSMakeRange(0, desc.length)];
    NSString *uri = m ? [desc substringWithRange:m.range] : @"";
    id pausedValue = nil;
    @try { pausedValue = [state valueForKey:@"paused"]; } @catch (NSException *e) {}
    int playing = [pausedValue boolValue] ? 0 : 1;
    BOOL trackChanged = ![uri isEqualToString:gNowURI ?: @""], stateChanged = playing != gNowPlaying;
    if (!trackChanged && !stateChanged) return;
    // A background wake used to lose the audio about 0.2 s after a resume. Launching Spotify clean from SpringBoard is
    // meant to prevent that, so this only notes it (it no longer resumes again, which fought a pause by the user).
    static CFAbsoluteTime playStartedAt;
    if (playing && stateChanged) playStartedAt = CFAbsoluteTimeGetCurrent();
    if (!playing && stateChanged && gNowPlaying == 1 && CFAbsoluteTimeGetCurrent() - playStartedAt < 0.8)
        SPLog(@"NOTE: playback stopped %.2f s after starting", CFAbsoluteTimeGetCurrent() - playStartedAt);
    gNowURI = uri;
    gNowPlaying = playing;
    writeNowPlaying(state, nil);
    if (trackChanged) postNote("com.goldenappleguy.zefyreborn.trackchanged", 1);
    if (stateChanged) postNote("com.goldenappleguy.zefyreborn.playstate", playing);
    SPLog(@"now playing: %@ playing=%d", uri, playing);
    if (trackChanged) writeRecents();
    if (trackChanged && uri.length) {
        id coll = findInstance(kCollectionClass);
        if (coll) {
            void (^check)(BOOL, void *) = ^(BOOL liked, void *err) { if ([gNowURI isEqualToString:uri]) writeNowPlaying(state, liked ? @"1" : @"0"); };
            ((void (*)(id, SEL, id, id))objc_msgSend)(coll, @selector(collectionContainsContentWithURI:completionHandler:), [NSURL URLWithString:uri], check);
        }
    }
}

static void spPlayerStateChanged(id self, SEL _cmd, id player, id newState, id oldState) {
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(self, origOf(_cmd), player, newState, oldState);
    onPlayerState(newState);
}

static void installPlayerObserver(void) {
    Class k = NSClassFromString(kControllerClass);
    if (k) wrap(k, @selector(player:stateDidChange:fromState:), (IMP)spPlayerStateChanged);
}

%group SpotifyApp
%hook UIScene
- (void)setDelegate:(id)delegate {
    %orig;
    if (delegate) wrapSceneDelegate(object_getClass(delegate));
}
%end
%end

static void startSpotifySide(void) {
    %init(SpotifyApp);
    // Spotify's scene delegates are Swift classes living in the app; wrap them once the app has launched.
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        unsigned count = 0;
        Class *list = objc_copyClassList(&count);
        for (unsigned i = 0; i < count; i++) {
            const char *img = class_getImageName(list[i]);
            if (!img || !strstr(img, "/Spotify.app/")) continue;
            if (class_getInstanceMethod(list[i], @selector(scene:openURLContexts:)) || class_getInstanceMethod(list[i], @selector(scene:continueUserActivity:)))
                wrapSceneDelegate(list[i]);
        }
        free(list);
        installPlayerObserver();
        // A background launch (Quick Play) can be suspended again before the waiting command is read, which left it
        // unanswered on iOS 14. A background task keeps the app running for a short while.
        UIApplication *app = UIApplication.sharedApplication;
        __block UIBackgroundTaskIdentifier hold = UIBackgroundTaskInvalid;
        void (^release)(void) = ^{ if (hold != UIBackgroundTaskInvalid) { [app endBackgroundTask:hold]; hold = UIBackgroundTaskInvalid; } };
        hold = [app beginBackgroundTaskWithName:@"zefyreborn" expirationHandler:release];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), release);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ writeRecents(); });
        watchCommandFile();
        // The first check comes quickly: a Quick Play or link request is usually already waiting when Spotify starts.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ checkCommandFile(); });
        SPLog(@"ready");
    }];
}

// ---- SpringBoard: Quick Play --------------------------------------------------------------------------------
// Control Center, the lock screen and headsets send play through MRMediaRemoteSendCommandToPlayerWithResult
// (command 0 play, 1 pause, 2 toggle). When Quick Play is on, nothing is playing and the command would go to
// Apple's Music app (or to no app), the command is dropped and Spotify is started instead.

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isPlaying;
- (id)nowPlayingApplication;
@end

static long (*orig_sendToPlayer)(long, long, long, long, long, long);

static NSString *spotifyDocumentsPath(void);
static NSString *spotifyDocumentsPath(void) {
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    id proxy = proxyClass ? ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, NSSelectorFromString(@"applicationProxyForIdentifier:"), kSpotifyID) : nil;
    NSURL *container = [proxy respondsToSelector:NSSelectorFromString(@"dataContainerURL")] ? [proxy valueForKey:@"dataContainerURL"] : nil;
    return [container.path stringByAppendingPathComponent:@"Documents"];
}

static void launchSpotifyInBackground(void) {
    // FBSSystemService opens the app; ActivateSuspended starts it without bringing it to the front.
    Class svc = NSClassFromString(@"FBSSystemService");
    id shared = svc ? ((id (*)(id, SEL))objc_msgSend)(svc, NSSelectorFromString(@"sharedService")) : nil;
    SEL open = NSSelectorFromString(@"openApplication:options:withResult:");
    if (!shared || ![shared respondsToSelector:open]) { SPLog(@"quick play: FBSSystemService unavailable"); return; }
    NSDictionary *opts = @{@"__ActivateSuspended": @YES};
    void (^result)(id) = ^(id err) { SPLog(@"quick play: launch result %@", err); };
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(shared, open, kSpotifyID, opts, result);
}

static void syncSettings(void) {
    NSString *docs = spotifyDocumentsPath();
    if (!docs.length) return;
    NSString *text = [NSString stringWithFormat:@"enabled=%d\n", prefBool(@"enabled", YES)];
    [text writeToFile:[docs stringByAppendingPathComponent:@"zefyreborn.settings"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    SPLog(@"settings synced: %@", [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "]);
}

// Sends one command line to Spotify through its command file, starting it in the background if needed.
static void sendSpotifyCommandEx(NSString *line, BOOL launch);
static void sendSpotifyCommand(NSString *line) { sendSpotifyCommandEx(line, YES); }

// Waking a Spotify that is suspended in the background often loses the audio a moment after it starts, while a fresh
// launch is reliable. So when a request starts playback, nothing is playing, and Spotify is still running (suspended),
// it is closed first and launched clean.
@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (id)applicationWithBundleIdentifier:(NSString *)bundleIdentifier;
@end

static BOOL commandStartsPlayback(NSString *line) {
    if (![line hasPrefix:@"zefyreborn:"]) {   // a link only restarts Spotify when it carries a play flag
        BOOL shuffle;
        return parseLink([NSURL URLWithString:line], &shuffle) != nil;
    }
    if ([line isEqualToString:kResumeCommand]) return YES;
    for (NSString *name in @[@"resume", @"by-name", @"random", @"radio", @"likedsongs"])
        if ([line hasPrefix:[kCommandPrefix stringByAppendingString:name]]) return YES;
    return NO;
}

// The process ID of the running Spotify, found by name in the process table (0 when it is not running).
static pid_t spotifyPID(void) {
    int mib[3] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || !size) return 0;
    struct kinfo_proc *procs = malloc(size);
    pid_t found = 0;
    if (procs && sysctl(mib, 3, procs, &size, NULL, 0) == 0) {
        for (size_t i = 0; i < size / sizeof(struct kinfo_proc); i++) {
            if (!strcmp(procs[i].kp_proc.p_comm, "Spotify")) { found = procs[i].kp_proc.p_pid; break; }
        }
    }
    free(procs);
    return found;
}

static void sendSpotifyCommandNow(NSString *line, BOOL launch);

static void sendSpotifyCommandEx(NSString *line, BOOL launch) {
    if (launch && commandStartsPlayback(line)) {
        pid_t pid = spotifyPID();
        id mc = NSClassFromString(@"SBMediaController") ? [NSClassFromString(@"SBMediaController") sharedInstance] : nil;
        if (pid > 1 && ![mc isPlaying]) {
            SPLog(@"Spotify is running but not playing (pid %d): closing it so it launches clean", pid);
            kill(pid, SIGKILL);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ sendSpotifyCommandNow(line, launch); });
            return;
        }
    }
    sendSpotifyCommandNow(line, launch);
}

static void sendSpotifyCommandNow(NSString *line, BOOL launch) {
    syncSettings();
    NSString *docs = spotifyDocumentsPath();
    if (!docs.length) { SPLog(@"quick play: Spotify data folder not found"); return; }
    NSString *tmp = [docs stringByAppendingPathComponent:@"zefyreborn.cmd.tmp"], *cmd = [docs stringByAppendingPathComponent:@"zefyreborn.cmd"];
    NSError *err;
    if (![line writeToFile:tmp atomically:NO encoding:NSUTF8StringEncoding error:&err]) { SPLog(@"quick play: cannot write command: %@", err); return; }
    [NSFileManager.defaultManager removeItemAtPath:cmd error:nil];
    [NSFileManager.defaultManager moveItemAtPath:tmp toPath:cmd error:nil];
    SPLog(@"sent to Spotify: %@", line);
    if (launch) launchSpotifyInBackground();
}

static void showStartingFeedback(void);
static void quickPlay(void) { sendSpotifyCommand(kResumeCommand); }

// Reads the media state on the main thread. The press can arrive on any queue, so wait briefly for the main
// thread and let the press through untouched if it does not answer.
static BOOL shouldRedirect(long cmd) {
    __block BOOL redirect = NO;
    void (^decide)(void) = ^{
        SBMediaController *mc = NSClassFromString(@"SBMediaController") ? [NSClassFromString(@"SBMediaController") sharedInstance] : nil;
        BOOL playing = [mc isPlaying];
        id app = [mc nowPlayingApplication];
        NSString *bid = [app respondsToSelector:NSSelectorFromString(@"bundleIdentifier")] ? [app valueForKey:@"bundleIdentifier"] : nil;
        SPLog(@"play press cmd=%ld playing=%d nowPlaying=%@", cmd, playing, bid);
        // Only take over when nothing owns the media session or Apple's Music app does (the default player). A paused
        // session from another app (a video, a podcast) keeps its own play press.
        BOOL appleDefault = !bid.length || [bid isEqualToString:@"com.apple.Music"] || [bid isEqualToString:@"com.apple.mobileipod"];
        redirect = !playing && appleDefault;
    };
    if (pthread_main_np()) {
        decide();
    } else {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{ decide(); dispatch_semaphore_signal(sem); });
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)))) {
            SPLog(@"play press: main thread did not answer, passing through");
            return NO;
        }
    }
    return redirect;
}

static long hook_sendToPlayer(long cmd, long a, long b, long c, long d, long e) {
    if (cmd != 0 && cmd != 2) SPLog(@"media command %ld", cmd);
    if ((cmd == 0 || cmd == 2) && prefBool(@"enabled", YES) && prefBool(@"quickPlay", NO) && shouldRedirect(cmd)) {
        SPLog(@"quick play: redirecting to Spotify");
        dispatch_async(dispatch_get_main_queue(), ^{ quickPlay(); showStartingFeedback(); });
        return 1;
    }
    return orig_sendToPlayer(cmd, a, b, c, d, e);
}

// ---- "Starting Spotify" feedback in Control Center ------------------------------------------------------------
// Starting Spotify from nothing takes a few seconds, so after a redirected play press the media module's
// placeholder text ("Not Playing") says "Starting Spotify" until playback begins (or 10 seconds pass).

static NSString *const kStartingText = @"Starting Spotify";
static NSHashTable *gLabelViews;
static NSString *gOriginalPlaceholder;
static BOOL gStarting;
static NSUInteger gStartingToken;

// On iOS 15 the module's `placeholder` property is empty and the visible "Not Playing" is a plain label inside the
// view, so that label's text is changed directly, and remembered so it can be put back.
static NSMapTable *gChangedLabels;   // UILabel -> its original text

static void setStarting(BOOL on) {
    gStarting = on;
    NSString *text = on ? kStartingText : (gOriginalPlaceholder ?: @"Not Playing");
    for (id view in gLabelViews.allObjects) {
        id current = [view respondsToSelector:@selector(placeholder)] ? [view valueForKey:@"placeholder"] : nil;
        if (current) {
            if ([view respondsToSelector:@selector(setPlaceholder:)]) [view setPlaceholder:text];   // iOS 17: the placeholder is the text
        } else if (on) {
            if (!gChangedLabels) gChangedLabels = [NSMapTable weakToStrongObjectsMapTable];
            for (UIView *sub in ((UIView *)view).subviews) {
                UILabel *label = [sub isKindOfClass:UILabel.class] ? (UILabel *)sub : nil;
                if (label && label.text.length && !label.hidden && ![gChangedLabels objectForKey:label]) {
                    [gChangedLabels setObject:label.text forKey:label];
                    CGFloat needed = [kStartingText sizeWithAttributes:@{NSFontAttributeName: label.font ?: [UIFont systemFontOfSize:17]}].width;
                    label.text = needed <= label.bounds.size.width ? kStartingText : @"Starting\u2026";   // a narrow label gets the short form
                }
            }
        }
    }
    if (!on) {
        for (UILabel *label in gChangedLabels.keyEnumerator.allObjects) label.text = [gChangedLabels objectForKey:label];
        [gChangedLabels removeAllObjects];
    }
    SPLog(@"starting feedback %@ (%lu label view(s), %lu direct label(s) changed)", on ? @"on" : @"off", (unsigned long)gLabelViews.allObjects.count, (unsigned long)gChangedLabels.count);
}

// "Playing" arrives with state 1; a paused report at launch must not end the feedback. A failed resume also ends it.
static int gPlayStateToken = -1;

static void playbackChanged(CFNotificationCenterRef c, void *o, CFNotificationName n, const void *obj, CFDictionaryRef u) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gStarting) return;
        if (gPlayStateToken < 0) notify_register_check("com.goldenappleguy.zefyreborn.playstate", &gPlayStateToken);
        uint64_t state = 0;
        notify_get_state(gPlayStateToken, &state);
        if (state == 1) setStarting(NO);
    });
}

static void resumeFailed(CFNotificationCenterRef c, void *o, CFNotificationName n, const void *obj, CFDictionaryRef u) {
    dispatch_async(dispatch_get_main_queue(), ^{ if (gStarting) { SPLog(@"resume failed, ending the feedback"); setStarting(NO); } });
}

static void showStartingFeedback(void) {
    AudioServicesPlaySystemSound(1519);   // a light tap
    NSUInteger token = ++gStartingToken;
    // On iOS 15 the module's labels were created before the hook existed and are not told again, so find them directly.
    {
        if (!gLabelViews) gLabelViews = [NSHashTable weakObjectsHashTable];
        for (id view in findAllInstances(@"MRUNowPlayingLabelView")) {
            [gLabelViews addObject:view];
            if (!gOriginalPlaceholder) {
                id current = [view respondsToSelector:@selector(placeholder)] ? [view valueForKey:@"placeholder"] : nil;
                if ([current isKindOfClass:NSString.class] && ![current isEqualToString:kStartingText]) gOriginalPlaceholder = current;
            }
        }
    }
    setStarting(YES);
    // Where the media module has no label to change (iOS 15), RC's add-on banner shows the message instead.
    if (!gLabelViews.allObjects.count) postNote("com.goldenappleguy.zefyreborn.starting", 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (gStarting && token == gStartingToken) setStarting(NO); });
}

%group CCLabel
%hook MRUNowPlayingLabelView
- (void)setPlaceholder:(id)placeholder {
    if ([placeholder isKindOfClass:NSString.class] && ![placeholder isEqualToString:kStartingText]) gOriginalPlaceholder = placeholder;
    if (!gLabelViews) gLabelViews = [NSHashTable weakObjectsHashTable];
    [gLabelViews addObject:self];
    %orig(gStarting ? kStartingText : placeholder);
}
%end
%end

// ---- SpringBoard: Quick Actions on Spotify's icon ------------------------------------------------------------
// Items are added to the icon's long-press menu; a tap is handled here and never reaches the app.

@interface SBSApplicationShortcutItem : NSObject
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *localizedTitle;
@property (nonatomic, copy) NSString *localizedSubtitle;
@property (nonatomic, copy) NSString *bundleIdentifierToLaunch;
@property (nonatomic, retain) id icon;
@end

@interface SBIconView : NSObject
- (NSArray *)applicationShortcutItems;
- (NSString *)applicationBundleIdentifierForShortcuts;
@end

static NSString *const kQuickActionPrefix = @"com.goldenappleguy.zefyreborn.";

static NSArray *spotifyQuickActions(void) {
    NSArray *defs = @[@[@"like", @"Like Playing Track", @"heart"],
                      @[@"radio", @"Start Radio", @"dot.radiowaves.left.and.right"],
                      @[@"myplaylist", @"My Playlist", @"music.note.list"]];
    NSMutableArray *items = [NSMutableArray array];
    Class itemClass = NSClassFromString(@"SBSApplicationShortcutItem"), iconClass = NSClassFromString(@"SBSApplicationShortcutSystemPrivateIcon");
    for (NSArray *d in defs) {
        SBSApplicationShortcutItem *item = [[itemClass alloc] init];
        item.type = [kQuickActionPrefix stringByAppendingString:d[0]];
        item.localizedTitle = d[1];
        SEL initIcon = NSSelectorFromString(@"initWithSystemImageName:");
        if (iconClass && [iconClass instancesRespondToSelector:initIcon]) item.icon = ((id (*)(id, SEL, id))objc_msgSend)([iconClass alloc], initIcon, d[2]);
        [items addObject:item];
    }
    return items;
}

static void runQuickAction(NSString *which) {
    SPLog(@"quick action: %@", which);
    if ([which isEqualToString:@"like"]) sendSpotifyCommand(@"zefyreborn:cmd like 2");
    else if ([which isEqualToString:@"radio"]) sendSpotifyCommand(@"zefyreborn:cmd radio");
    else if ([which isEqualToString:@"myplaylist"]) {
        CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsDomain);
        NSString *uri = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("myPlaylist"), (__bridge CFStringRef)kPrefsDomain));
        if ([uri isKindOfClass:NSString.class] && uri.length) sendSpotifyCommand([uri stringByAppendingString:@":play"]);
        else SPLog(@"quick action: no saved playlist");
    }
}

%group SBMediaLog
%hook SBMediaController
- (BOOL)playForEventSource:(long long)source {
    SPLog(@"SBMediaController playForEventSource:%lld", source);
    return %orig;
}
- (BOOL)togglePlayPauseForEventSource:(long long)source {
    SPLog(@"SBMediaController togglePlayPauseForEventSource:%lld", source);
    return %orig;
}
%end
%end

%group SpringBoardIcons
%hook SBIconView
- (NSArray *)applicationShortcutItems {
    NSArray *items = %orig;
    if (![[self applicationBundleIdentifierForShortcuts] isEqualToString:kSpotifyID] || !prefBool(@"enabled", YES) || !prefBool(@"quickActions", YES)) return items;
    SPLog(@"quick actions: adding to %lu stock item(s)", (unsigned long)items.count);
    return [(items ?: @[]) arrayByAddingObjectsFromArray:spotifyQuickActions()];
}

- (BOOL)shouldActivateApplicationShortcutItem:(SBSApplicationShortcutItem *)item atIndex:(unsigned long long)index {
    if ([item.type hasPrefix:kQuickActionPrefix]) {
        runQuickAction([item.type substringFromIndex:kQuickActionPrefix.length]);
        return NO;
    }
    return %orig;
}
%end
%end

// ---- SpringBoard command channel: sleep timer and debug probes -----------------------------------------------
// The zefy command writes zefyreborn.sbcmd in the tmp folder; SpringBoard watches for it, runs it and writes
// the answer to zefyreborn.sbresult next to it.

#define kSBCommandPath [ZRTmp() stringByAppendingPathComponent:@"zefyreborn.sbcmd"]
#define kSBResultPath [ZRTmp() stringByAppendingPathComponent:@"zefyreborn.sbresult"]
static dispatch_source_t gSBWatch, gSleepTimer;
static NSDate *gSleepEnd;

static void sbResult(NSString *text) {
    [[text stringByAppendingString:@"\n"] writeToFile:kSBResultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void cancelSleep(void) {
    if (gSleepTimer) { dispatch_source_cancel(gSleepTimer); gSleepTimer = nil; }
    gSleepEnd = nil;
}

static void handleSleep(NSString *arg) {
    if ([arg isEqualToString:@"status"]) {
        if (!gSleepEnd) { sbResult(@"Sleep timer is off"); return; }
        sbResult([NSString stringWithFormat:@"Sleep timer: %.0f minutes left", MAX(1.0, ceil(-[[NSDate date] timeIntervalSinceDate:gSleepEnd] / 60))]);
        return;
    }
    cancelSleep();
    if ([arg isEqualToString:@"off"]) { sbResult(@"Sleep timer off"); return; }
    double minutes = arg.doubleValue;
    if (minutes <= 0 || minutes > 720) { sbResult(@"usage: zefy --sleep <minutes 1-720>|off|status"); return; }
    gSleepEnd = [NSDate dateWithTimeIntervalSinceNow:minutes * 60];
    gSleepTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    // A wall-clock time: the monotonic clock behind DISPATCH_TIME_NOW stops while the phone naps, so the timer was late.
    dispatch_source_set_timer(gSleepTimer, dispatch_walltime(NULL, (int64_t)(minutes * 60 * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, NSEC_PER_SEC);
    dispatch_source_set_event_handler(gSleepTimer, ^{
        SPLog(@"sleep timer: pausing");
        sendSpotifyCommandEx(@"zefyreborn:cmd pause", NO);
        cancelSleep();
    });
    dispatch_resume(gSleepTimer);
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm";
    sbResult([NSString stringWithFormat:@"Sleep timer set: pauses at %@", [f stringFromDate:gSleepEnd]]);
}

// Debug probes (only with the debug flag): list classes by name part, dump one class.
static void probeClasses(NSString *part) {
    unsigned n = 0, shown = 0;
    Class *list = objc_copyClassList(&n);
    for (unsigned i = 0; i < n && shown < 300; i++) {
        const char *name = class_getName(list[i]);
        if (strcasestr(name, part.UTF8String)) { SPLog(@"class %s", name); shown++; }
    }
    free(list);
}

static void probeClass(NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) { SPLog(@"no class %@", name); return; }
    SPLog(@"class %@ : %s", name, class_getSuperclass(c) ? class_getName(class_getSuperclass(c)) : "-");
    for (int meta = 0; meta < 2; meta++) {
        unsigned n = 0;
        Method *ms = class_copyMethodList(meta ? object_getClass(c) : c, &n);
        for (unsigned i = 0; i < n; i++) SPLog(@"  %c %s  %s", meta ? '+' : '-', sel_getName(method_getName(ms[i])), method_getTypeEncoding(ms[i]));
        free(ms);
    }
}

static void probeIvars(NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) { SPLog(@"no class %@", name); return; }
    unsigned n = 0;
    Ivar *iv = class_copyIvarList(c, &n);
    for (unsigned i = 0; i < n; i++) SPLog(@"ivar %@.%s  %s", name, ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i]));
    free(iv);
}

// ---- relay for iOS 15, where the shell user cannot reach Spotify's data folder -------------------------------
// The zefy command sends its request to SpringBoard, which can write into the folder. "relay" passes a
// command line on, "relay-wait" also waits for the reply file Spotify writes, and "nowplaying" returns the status file.

static NSString *spotifyFile(NSString *name) {
    NSString *docs = spotifyDocumentsPath();
    return docs.length ? [docs stringByAppendingPathComponent:name] : nil;
}

static void relayWait(NSString *line, int attempt) {
    NSString *path = spotifyFile(@"zefyreborn.result");
    NSString *reply = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
    if (reply.length) { sbResult([reply stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]); return; }
    if (attempt >= 40) { sbResult(@"No answer from Spotify"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ relayWait(line, attempt + 1); });
}

static void handleRelay(NSString *name, NSString *arg) {
    if ([name isEqualToString:@"relay"]) {
        sendSpotifyCommandEx(arg, YES);
        sbResult(@"ok");
    } else if ([name isEqualToString:@"relay-wait"]) {
        NSString *path = spotifyFile(@"zefyreborn.result");
        if (path) [NSFileManager.defaultManager removeItemAtPath:path error:nil];   // a stale reply must not answer this request
        sendSpotifyCommandEx(arg, YES);
        relayWait(arg, 0);
    } else if (debugEnabled() && [name isEqualToString:@"spotify-debug"]) {
        // Debug: switch Spotify's own debug log on or off from SpringBoard (the shell cannot reach the folder on iOS 15).
        NSString *flag = spotifyFile(@"zefyreborn.debug");
        if ([arg isEqualToString:@"on"]) [@"" writeToFile:flag atomically:YES encoding:NSUTF8StringEncoding error:nil];
        else [NSFileManager.defaultManager removeItemAtPath:flag error:nil];
        sbResult([NSString stringWithFormat:@"Spotify debug log %@", arg]);
    } else if (debugEnabled() && [name isEqualToString:@"spotify-log"]) {
        NSString *text = [NSString stringWithContentsOfFile:spotifyFile(@"zefyreborn.log") encoding:NSUTF8StringEncoding error:nil] ?: @"(no log)";
        NSArray *lines = [text componentsSeparatedByString:@"\n"];
        NSUInteger n = MIN(lines.count, (NSUInteger)(arg.integerValue ?: 40));
        sbResult([[lines subarrayWithRange:NSMakeRange(lines.count - n, n)] componentsJoinedByString:@"\n"]);
    } else if ([name isEqualToString:@"nowplaying"]) {
        NSString *path = spotifyFile(@"zefyreborn.nowplaying");
        NSString *text = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
        sbResult(text.length ? [text stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] : @"none");
    }
}

// Debug: describe every media-module label view (text, visibility, parents) to find the one that shows "Not Playing".
static void logLabelTexts(UIView *v, int depth) {
    if (depth > 6) return;
    for (UIView *sub in v.subviews) {
        if ([sub isKindOfClass:UILabel.class]) SPLog(@"      %*s UILabel \"%@\" hidden=%d alpha=%.2f", depth * 2, "", ((UILabel *)sub).text, sub.hidden, sub.alpha);
        else if ([sub respondsToSelector:@selector(text)] && [[sub valueForKey:@"text"] isKindOfClass:NSString.class]) SPLog(@"      %*s %@ text \"%@\" hidden=%d", depth * 2, "", NSStringFromClass([sub class]), [sub valueForKey:@"text"], sub.hidden);
        logLabelTexts(sub, depth + 1);
    }
}

static void probeLabels(void) {
    for (id view in findAllInstances(@"MRUNowPlayingLabelView")) {
        UIView *v = view;
        NSMutableString *chain = [NSMutableString string];
        for (UIView *p = v.superview; p && chain.length < 400; p = p.superview) [chain appendFormat:@"%@ > ", NSStringFromClass([p class])];
        id placeholder = [view respondsToSelector:@selector(placeholder)] ? [view valueForKey:@"placeholder"] : nil;
        id title = [view respondsToSelector:@selector(title)] ? [view valueForKey:@"title"] : nil;
        id showPlaceholder = [view respondsToSelector:@selector(showPlaceholder)] ? [view valueForKey:@"showPlaceholder"] : nil;
        SPLog(@"label %p: window=%@ hidden=%d alpha=%.2f frame=%@ placeholder=%@ showPlaceholder=%@ title=%@", view, v.window ? NSStringFromClass([v.window class]) : @"none", v.hidden, v.alpha, NSStringFromCGRect(v.frame), placeholder, showPlaceholder, title);
        SPLog(@"   parents: %@", chain);
        logLabelTexts(v, 0);
    }
}

static void handleSBCommand(NSString *line) {
    NSRange sp = [line rangeOfString:@" "];
    NSString *name = sp.location == NSNotFound ? line : [line substringToIndex:sp.location];
    NSString *arg = sp.location == NSNotFound ? @"" : [line substringFromIndex:sp.location + 1];
    SPLog(@"sb command: %@", line);
    if ([name isEqualToString:@"ping"]) sbResult(@"pong");
    else if ([name isEqualToString:@"sleep"]) handleSleep(arg);
    else if ([name isEqualToString:@"relay"] || [name isEqualToString:@"relay-wait"] || [name isEqualToString:@"nowplaying"] || [name isEqualToString:@"spotify-debug"] || [name isEqualToString:@"spotify-log"]) handleRelay(name, arg);
    else if (debugEnabled() && [name isEqualToString:@"probe-classes"]) probeClasses(arg);
    else if (debugEnabled() && [name isEqualToString:@"probe-class"]) probeClass(arg);
    else if (debugEnabled() && [name isEqualToString:@"probe-ivars"]) probeIvars(arg);
    else if (debugEnabled() && [name isEqualToString:@"probe-labels"]) probeLabels();
    else if (debugEnabled() && [name isEqualToString:@"probe-sym"]) {
        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        NSMutableString *out = [NSMutableString string];
        for (NSString *n in [arg componentsSeparatedByString:@","]) [out appendFormat:@"%@: %@\n", n, mr && dlsym(mr, n.UTF8String) ? @"yes" : @"no"];
        sbResult(out);
    }
    else sbResult(@"unknown command");
}

static void checkSBCommandFile(void) {
    NSString *line = [[NSString stringWithContentsOfFile:kSBCommandPath encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!line.length) return;
    [NSFileManager.defaultManager removeItemAtPath:kSBCommandPath error:nil];
    handleSBCommand(line);
}

static void watchSBCommands(void) {
    int fd = open(ZRTmp().fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) return;
    gSBWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd, DISPATCH_VNODE_WRITE, dispatch_get_main_queue());
    dispatch_source_set_event_handler(gSBWatch, ^{ checkSBCommandFile(); });
    dispatch_source_set_cancel_handler(gSBWatch, ^{ close(fd); });
    dispatch_resume(gSBWatch);
}

// ---- SpringBoard: Spotify in Control Center's media suggestions ----------------------------------------------
// With nothing playing, the media module shows a row of recently played albums (Apple Music's). The row is
// MRUMediaSuggestionsController's `mediaSuggestions`, an array of MRMediaSuggestion built from "play media"
// intents. Spotify's recently played items (from the recents file) are turned into the same kind of object and
// put first; a tap on one is played through Spotify instead of being handed to the media framework.

@interface MRUMediaSuggestionsController : NSObject
- (NSArray *)mediaSuggestions;
- (void)refreshMediaSuggestions;
@end

static const NSUInteger kRowSize = 8;   // how many recents the Control Center row asks for
static NSArray *gOurSuggestions;
static NSDate *gOurSuggestionsDate;
static __weak MRUMediaSuggestionsController *gSuggestionsController;
static NSMutableSet *gArtFetching;

static NSString *artPath(NSString *uri) {
    NSString *dir = [ZRTmp() stringByAppendingPathComponent:@"zefyreborn-art"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:[[uri stringByReplacingOccurrencesOfString:@":" withString:@"_"] stringByAppendingString:@".img"]];
}

// spotify:image:<id>, spotify:mosaic:<id>:... (first image) or a web link -> a web link.
static NSURL *artURL(NSString *image) {
    if ([image hasPrefix:@"http"]) return [NSURL URLWithString:image];
    NSArray *parts = [image componentsSeparatedByString:@":"];
    if (parts.count >= 3 && ([parts[1] isEqualToString:@"image"] || [parts[1] isEqualToString:@"mosaic"])) return [NSURL URLWithString:[@"https://i.scdn.co/image/" stringByAppendingString:parts[2]]];
    return nil;
}

static NSArray *spotifyRecents(void) {
    NSString *docs = spotifyDocumentsPath();
    NSString *text = docs.length ? [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"zefyreborn.recents"] encoding:NSUTF8StringEncoding error:nil] : nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSArray *f = [line componentsSeparatedByString:@"\t"];
        if (f.count >= 4) [out addObject:@{@"uri": f[0], @"title": f[1], @"subtitle": f[2], @"image": f[3]}];
    }
    return out;
}

// Liked Songs has no cover of its own, so draw a heart tile for it.
static void writePlaceholderArt(NSString *uri) {
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(300, 300)];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGFloat colors[8] = {0.31, 0.20, 0.92, 1, 0.64, 0.74, 0.88, 1};
        CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)@[(id)[UIColor colorWithRed:colors[0] green:colors[1] blue:colors[2] alpha:1].CGColor, (id)[UIColor colorWithRed:colors[4] green:colors[5] blue:colors[6] alpha:1].CGColor], NULL);
        CGContextDrawLinearGradient(ctx.CGContext, g, CGPointZero, CGPointMake(300, 300), 0);
        CGGradientRelease(g);
        CGColorSpaceRelease(cs);
        UIImage *heart = [[UIImage systemImageNamed:@"heart.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:130]] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        [heart drawInRect:CGRectMake((300 - heart.size.width) / 2, (300 - heart.size.height) / 2, heart.size.width, heart.size.height)];
    }];
    [UIImagePNGRepresentation(img) writeToFile:artPath(uri) atomically:YES];
}

// Downloads a cover once, then asks the row to rebuild (an entry only joins the row once its cover is on disk).
static void fetchArt(NSString *uri, NSString *image) {
    NSURL *url = artURL(image);
    if (!url || [NSFileManager.defaultManager fileExistsAtPath:artPath(uri)]) return;
    if (!gArtFetching) gArtFetching = [NSMutableSet set];
    if ([gArtFetching containsObject:uri]) return;
    [gArtFetching addObject:uri];
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [gArtFetching removeObject:uri];
            if (!data.length || e) { SPLog(@"art for %@ failed: %@", uri, e); return; }
            [data writeToFile:artPath(uri) atomically:YES];
            SPLog(@"art for %@ saved (%lu bytes)", uri, (unsigned long)data.length);
            gOurSuggestionsDate = nil;   // rebuild so the entry can join the row
            [gSuggestionsController refreshMediaSuggestions];
        });
    }] resume];
}

static id makeSuggestion(NSDictionary *r) {
    Class itemClass = NSClassFromString(@"INMediaItem"), intentClass = NSClassFromString(@"INPlayMediaIntent"), suggestionClass = NSClassFromString(@"MRMediaSuggestion");
    SEL itemInit = NSSelectorFromString(@"initWithIdentifier:title:type:artwork:artist:");
    SEL intentInit = NSSelectorFromString(@"initWithMediaItems:mediaContainer:playShuffled:playbackRepeatMode:resumePlayback:playbackQueueLocation:playbackSpeed:mediaSearch:");
    if (!itemClass || !intentClass || !suggestionClass || ![itemClass instancesRespondToSelector:itemInit] || ![intentClass instancesRespondToSelector:intentInit]) { SPLog(@"suggestions: Intents API not as expected"); return nil; }
    NSString *uri = r[@"uri"], *sub = r[@"subtitle"];
    if (![NSFileManager.defaultManager fileExistsAtPath:artPath(uri)]) {
        if (artURL(r[@"image"])) { fetchArt(uri, r[@"image"]); return nil; }   // joins the row once the cover is downloaded
        writePlaceholderArt(uri);
    }
    NSInteger type = [uri hasPrefix:@"spotify:album:"] ? 2 : [uri hasPrefix:@"spotify:artist:"] ? 3 : 5;   // INMediaItemType
    NSRange by = [sub rangeOfString:@" by "];
    NSString *artist = by.location != NSNotFound ? [sub substringFromIndex:NSMaxRange(by)] : nil;
    id item = ((id (*)(id, SEL, id, id, NSInteger, id, id))objc_msgSend)([itemClass alloc], itemInit, uri, r[@"title"], type, nil, artist);
    id intent = ((id (*)(id, SEL, id, id, id, NSInteger, id, NSInteger, id, id))objc_msgSend)([intentClass alloc], intentInit, @[item], item, nil, 0, nil, 0, nil, nil);
    id suggestion = ((id (*)(id, SEL, id))objc_msgSend)([suggestionClass alloc], NSSelectorFromString(@"initWithIntent:"), intent);
    if (!suggestion) return nil;
    object_setIvar(suggestion, class_getInstanceVariable(suggestionClass, "_bundleID"), kSpotifyID);
    return suggestion;
}

// Our suggestions, rebuilt only when the recents file changes so the same objects come back each time.
static NSArray *ourSuggestions(void) {
    NSString *docs = spotifyDocumentsPath();
    NSDate *date = docs.length ? [NSFileManager.defaultManager attributesOfItemAtPath:[docs stringByAppendingPathComponent:@"zefyreborn.recents"] error:nil].fileModificationDate : nil;
    if (!date) return @[];
    if (gOurSuggestions && [date isEqualToDate:gOurSuggestionsDate]) return gOurSuggestions;
    NSMutableArray *list = [NSMutableArray array];
    // Albums first, like the row Apple Music fills, then playlists and artists, each in the order they were played.
    NSMutableArray *ordered = [NSMutableArray array];
    for (NSString *kind in @[@"spotify:album:", @"spotify:playlist:", @"spotify:artist:"])
        for (NSDictionary *r in spotifyRecents()) if ([r[@"uri"] hasPrefix:kind]) [ordered addObject:r];
    for (NSDictionary *r in ordered) {
        if (list.count >= kRowSize) break;
        id s = makeSuggestion(r);
        if (s) { [list addObject:s]; SPLog(@"suggestion built: %@ | %@ | %@", [s valueForKey:@"title"], [s valueForKey:@"artist"], [s valueForKey:@"identifier"]); }
    }
    gOurSuggestions = list;
    gOurSuggestionsDate = date;
    return list;
}

static BOOL isSpotifySuggestion(id suggestion) {
    return [[suggestion valueForKey:@"bundleID"] isEqual:kSpotifyID];
}

%group CCSuggestions
%hook MRUMediaSuggestionsController
- (NSArray *)mediaSuggestions {
    NSArray *items = %orig;
    gSuggestionsController = self;
    if (!prefBool(@"enabled", YES) || !prefBool(@"ccRecents", YES)) return items;
    @try {
        NSArray *ours = ourSuggestions();
        if (!ours.count) return items;
        NSMutableArray *merged = [ours mutableCopy];
        for (id apple in items) { if (merged.count >= kRowSize) break; if (!isSpotifySuggestion(apple)) [merged addObject:apple]; }
        return merged;
    } @catch (NSException *e) {
        SPLog(@"suggestions: %@", e);
        return items;
    }
}
- (void)playSuggestion:(id)suggestion completion:(id)completion {
    SPLog(@"playSuggestion: %@ (%@)", [suggestion valueForKey:@"title"], [suggestion valueForKey:@"bundleID"]);
    if (isSpotifySuggestion(suggestion)) {
        sendSpotifyCommand([[[suggestion valueForKey:@"identifier"] description] stringByAppendingString:@":play"]);
        if (completion) ((void (^)(id))completion)(nil);
        return;
    }
    %orig;
}
%end

%hook MRUMediaSuggestionsCache
- (id)artworkForMediaSuggestion:(id)suggestion {
    if (isSpotifySuggestion(suggestion)) {
        UIImage *image = [UIImage imageWithContentsOfFile:artPath([[suggestion valueForKey:@"identifier"] description])];
        SPLog(@"artwork requested for %@: %@", [suggestion valueForKey:@"title"], image ? @"cached" : @"not ready");
        if (image) return image;
    }
    return %orig;
}
%end
%end

static void initCCSuggestions(int attempt) {
    if (objc_getClass("MRUNowPlayingLabelView")) {
        %init(CCLabel);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, playbackChanged, CFSTR("com.goldenappleguy.zefyreborn.playstate"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, resumeFailed, CFSTR("com.goldenappleguy.zefyreborn.resumefailed"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        SPLog(@"starting feedback hook installed");
    }
    if (objc_getClass("MRUMediaSuggestionsController")) { %init(CCSuggestions); SPLog(@"suggestion hooks installed"); return; }
    if (attempt < 30) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ initCCSuggestions(attempt + 1); });
}

static void settingsChanged(CFNotificationCenterRef c, void *o, CFNotificationName n, const void *obj, CFDictionaryRef u) { syncSettings(); }

static void startSpringBoardSide(void) {
    %init(SpringBoardIcons);
    %init(SBMediaLog);
    watchSBCommands();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ initCCSuggestions(0); });
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, settingsChanged, CFSTR("com.goldenappleguy.zefyreborn.prefschanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ syncSettings(); });
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    // iOS 14 has no ...WithResult variant; its play presses go through MRMediaRemoteSendCommandToPlayer, which
    // takes the command first as well.
    void *fn = mr ? STRIP(dlsym(mr, "MRMediaRemoteSendCommandToPlayerWithResult")) : NULL;
    if (!fn && mr) fn = STRIP(dlsym(mr, "MRMediaRemoteSendCommandToPlayer"));
    if (!fn) { SPLog(@"quick play: send function not found"); return; }
    MSHookFunction(fn, (void *)hook_sendToPlayer, (void **)&orig_sendToPlayer);
    SPLog(@"quick play: hooked %p", fn);
}

%ctor {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if ([bid isEqualToString:kSpotifyID]) startSpotifySide();
    else if ([bid isEqualToString:@"com.apple.springboard"]) startSpringBoardSide();
}
