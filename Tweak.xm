// MGXFix — 8BitDo Ultimate MGX (BLE HID gamepad) support for iOS
//
// ROOT CAUSE
// ----------
// iOS handles the MGX correctly right up to the last step:
//   * bluetoothd pairs it as BLE HID-over-GATT and enumerates its HID service
//   * BTLEServer publishes an IOHIDUserDevice for it (report IDs 1 and 5)
//   * gamecontrollerd opens it and matches it in the GameController device
//     database by VID/PID:  "Matched com.8BitDo.UltimateMGX.Bluetooth"
//   * ...and then rejects the mapping on a VERSION COMPARISON:
//       "Skipping loading device personality: requires version '11.4.7'"
//
// The MGX mapping ships in a *downloaded* GameController DB asset whose
// personality CompatibilityVersion (11.4.7 / 10.1.36) is newer than the running
// GameControllerFoundation. That is why 8BitDo controllers "gained iOS support"
// in 18.5 — not a new driver, just a runtime new enough for the gate.
//
// A second problem appears once the gate is open: the asset lists
// WithBackButtons.plist first, whose model declares button.p1/p2 paddles. On a
// base MGX that fails driver configuration with GCGenericDeviceError Code=2.
//
// WHAT THIS TWEAK DOES
// --------------------
// Injected into GameControllerConfigService, it patches the plists in memory as
// they load. Nothing on disk is modified.
//
//   1. CompatibilityVersion -> 1.0.0 for any personality.
//   2. The MGX device entry selects Default.plist instead of WithBackButtons.
//   3. The MGX mapping is BUNDLED with this package, so it works even when the
//      installed GameController DB asset has no MGX entry (older assets, and
//      the preinstalled iOS DB, only carry M30/NEOGEOGP/SN30_Pro). If the entry
//      is missing it is synthesised, and its personality is served from the
//      bundled copy.
//
// REQUIREMENTS: the GameController device-database / personality system
// (GameControllerConfigService, GenericGamepadHIDServicePlugin) must exist.
// That system is what iOS 16+ uses; on older releases this tweak is a no-op.

#import <Foundation/Foundation.h>
#import <dlfcn.h>

#define LOG(fmt, ...) NSLog((@"[MGXFix] " fmt), ##__VA_ARGS__)

#define kMGXDeviceIdentifier   @"com.8BitDo.UltimateMGX.Bluetooth"
#define kMGXDefaultPersonality @"Personalities/8BitDo/UltimateMGX/Default.plist"
#define kMGXPersonalitySuffix  @"Personalities/8BitDo/UltimateMGX/Default.plist"

#pragma mark - Bundled resources

// The dylib lives at <jbroot>/Library/MobileSubstrate/DynamicLibraries/, so the
// jailbreak root is everything before that. This works for rootless (/var/jb)
// and RootHide (…/.jbroot-XXXX) without depending on jbroot() being linked.
static NSString *MGXJBRoot(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (dladdr((void *)MGXJBRoot, &info) && info.dli_fname) {
            NSString *path = [NSString stringWithUTF8String:info.dli_fname];
            NSRange range = [path rangeOfString:@"/Library/MobileSubstrate/DynamicLibraries/"];
            if (range.location != NSNotFound) {
                root = [path substringToIndex:range.location];
            }
        }
        if (!root.length) root = @"/var/jb";
    });
    return root;
}

static NSString *MGXBundledPersonalityPath(void) {
    return [MGXJBRoot() stringByAppendingString:
            @"/Library/Application Support/mgxfix/MGXDefault.plist"];
}

// The bundled mapping, used when the installed DB has no MGX personality (or
// has one this runtime refuses to load).
static NSDictionary *MGXBundledPersonality(void) {
    static NSDictionary *personality;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = MGXBundledPersonalityPath();
        NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([loaded isKindOfClass:[NSDictionary class]] && loaded[@"Model"]) {
            personality = loaded;
            LOG(@"loaded bundled personality from %@", path);
        } else {
            LOG(@"bundled personality missing or unreadable at %@", path);
        }
    });
    return personality;
}

static BOOL MGXIsMGXPersonalityPath(NSString *path) {
    return [path isKindOfClass:[NSString class]] &&
           [path hasSuffix:kMGXPersonalitySuffix];
}

#pragma mark - Patching

static BOOL MGXIsPersonality(id plist) {
    if (![plist isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *d = plist;
    return d[@"CompatibilityVersion"] != nil && d[@"Model"] != nil;
}

// The entry the GameController DB uses for this pad. Reproduced so the tweak
// does not depend on a downloaded asset containing it.
static NSDictionary *MGXDeviceEntry(void) {
    return @{
        @"CompatibilityVersion": @"10.1.36",
        @"IOPropertyMatch": @{
            @"ProductID": @8203,      // 0x200B
            @"VendorID": @11720,      // 0x2DC8
            @"VersionNumber": @1,
        },
        @"Identifier": kMGXDeviceIdentifier,
        @"Personalities": @[ kMGXDefaultPersonality ],
    };
}

static NSDictionary *MGXPatchDeviceDB(NSDictionary *db) {
    NSArray *devices = db[@"Devices"];
    if (![devices isKindOfClass:[NSArray class]]) {
        // Not a GameController device database. On releases that predate the
        // device-database/personality system (iOS 15 and earlier) this tweak
        // cannot do anything, so say so once instead of failing silently.
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            LOG(@"no GameController device database in this process — this iOS "
                @"release predates the personality system MGXFix needs");
        });
        return nil;
    }

    BOOL found = NO;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:devices.count + 1];
    for (id dev in devices) {
        if ([dev isKindOfClass:[NSDictionary class]] &&
            [((NSDictionary *)dev)[@"Identifier"] isEqualToString:kMGXDeviceIdentifier]) {
            NSMutableDictionary *m = [dev mutableCopy];
            m[@"Personalities"] = @[ kMGXDefaultPersonality ];
            [out addObject:m];
            found = YES;
        } else {
            [out addObject:dev];
        }
    }
    if (!found) {
        // The installed DB predates this controller; add the entry ourselves.
        [out addObject:MGXDeviceEntry()];
        LOG(@"device DB has no %@ entry — added bundled one", kMGXDeviceIdentifier);
    } else {
        LOG(@"device DB entry for %@ selects Default personality", kMGXDeviceIdentifier);
    }

    NSMutableDictionary *patched = [db mutableCopy];
    patched[@"Devices"] = out;
    return patched;
}

// Returns a patched copy, or nil when nothing needed changing.
static id MGXPatchAnyPlist(id plist) {
    if (![plist isKindOfClass:[NSDictionary class]]) return nil;

    if (MGXIsPersonality(plist)) {
        NSMutableDictionary *patched = [plist mutableCopy];
        patched[@"CompatibilityVersion"] = @"1.0.0";
        return patched;
    }

    return MGXPatchDeviceDB(plist);
}

// Serve the bundled personality. Used when the DB references the MGX mapping by
// path but the asset on disk has no such file (or the runtime rejects it).
static id MGXPersonalityForPath(NSString *path) {
    if (!MGXIsMGXPersonalityPath(path)) return nil;

    NSDictionary *bundled = MGXBundledPersonality();
    if (!bundled) return nil;

    NSMutableDictionary *patched = [bundled mutableCopy];
    patched[@"CompatibilityVersion"] = @"1.0.0";
    LOG(@"serving bundled personality for %@", path.lastPathComponent);
    return patched;
}

#pragma mark - CF layer (what NSBundle / NSDictionary ultimately use)

typedef CFPropertyListRef (*CFPLWithData_t)(CFAllocatorRef, CFDataRef, CFOptionFlags,
                                            CFPropertyListFormat *, CFErrorRef *);
typedef CFPropertyListRef (*CFPLWithURL_t)(CFAllocatorRef, CFURLRef, CFOptionFlags,
                                           CFPropertyListFormat *, CFErrorRef *);

static CFPLWithData_t orig_CFPropertyListCreateWithData;
static CFPLWithURL_t  orig_CFPropertyListCreateWithURL;

static CFPropertyListRef MGXPatchCF(CFPropertyListRef plist) {
    if (!plist || CFGetTypeID(plist) != CFDictionaryGetTypeID()) return plist;

    id patched = MGXPatchAnyPlist((__bridge id)plist);
    if (!patched) return plist;

    CFRelease(plist);
    return (CFPropertyListRef)CFBridgingRetain(patched);
}

static CFPropertyListRef hook_CFPropertyListCreateWithData(CFAllocatorRef alloc, CFDataRef data,
                                                           CFOptionFlags opts, CFPropertyListFormat *fmt,
                                                           CFErrorRef *err) {
    return MGXPatchCF(orig_CFPropertyListCreateWithData(alloc, data, opts, fmt, err));
}

static CFPropertyListRef hook_CFPropertyListCreateWithURL(CFAllocatorRef alloc, CFURLRef url,
                                                          CFOptionFlags opts, CFPropertyListFormat *fmt,
                                                          CFErrorRef *err) {
    NSString *path = url ? (__bridge_transfer NSString *)CFURLCopyFileSystemPath(url, kCFURLPOSIXPathStyle) : nil;
    if (MGXIsMGXPersonalityPath(path)) {
        id bundled = MGXPersonalityForPath(path);
        if (bundled) return (CFPropertyListRef)CFBridgingRetain(bundled);
    }
    return MGXPatchCF(orig_CFPropertyListCreateWithURL(alloc, url, opts, fmt, err));
}

#pragma mark - Foundation layer

%group PersonalityPatch
%hook NSDictionary
+ (instancetype)dictionaryWithContentsOfFile:(NSString *)path {
    id bundled = MGXPersonalityForPath(path);
    if (bundled) return bundled;
    return MGXPatchAnyPlist(%orig) ?: %orig;
}
+ (instancetype)dictionaryWithContentsOfURL:(NSURL *)url {
    id bundled = MGXPersonalityForPath(url.path);
    if (bundled) return bundled;
    return MGXPatchAnyPlist(%orig) ?: %orig;
}
- (instancetype)initWithContentsOfFile:(NSString *)path {
    id bundled = MGXPersonalityForPath(path);
    if (bundled) return bundled;
    id result = %orig;
    return MGXPatchAnyPlist(result) ?: result;
}
- (instancetype)initWithContentsOfURL:(NSURL *)url {
    id bundled = MGXPersonalityForPath(url.path);
    if (bundled) return bundled;
    id result = %orig;
    return MGXPatchAnyPlist(result) ?: result;
}
%end

%hook NSPropertyListSerialization
+ (id)propertyListWithData:(NSData *)data
                   options:(NSPropertyListReadOptions)opt
                    format:(NSPropertyListFormat *)format
                     error:(NSError **)error {
    return MGXPatchAnyPlist(%orig) ?: %orig;
}
%end
%end // PersonalityPatch

#pragma mark - Constructor

%ctor {
    %init(PersonalityPatch);

    void *cfData = dlsym(RTLD_DEFAULT, "CFPropertyListCreateWithData");
    void *cfURL  = dlsym(RTLD_DEFAULT, "CFPropertyListCreateWithURL");
    if (cfData) MSHookFunction(cfData, (void *)hook_CFPropertyListCreateWithData,
                               (void **)&orig_CFPropertyListCreateWithData);
    if (cfURL) MSHookFunction(cfURL, (void *)hook_CFPropertyListCreateWithURL,
                              (void **)&orig_CFPropertyListCreateWithURL);

    LOG(@"loaded in %@ (jbroot %@)", [[NSProcessInfo processInfo] processName], MGXJBRoot());
}
