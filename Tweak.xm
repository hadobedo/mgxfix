// MGXFix — 8BitDo Ultimate MGX (BLE HID gamepad) support on iOS 17.1.1
//
// ROOT CAUSE (established from a live capture, not inference)
// ----------------------------------------------------------
// iOS 17.1.1 handles the MGX correctly right up to the last step:
//   * bluetoothd pairs it as BLE HID-over-GATT and enumerates its HID service
//   * BTLEServer publishes an IOHIDUserDevice for it (report IDs 1 and 5)
//   * gamecontrollerd opens it and matches it in the GameController device
//     database by VID/PID:  "Matched com.8BitDo.UltimateMGX.Bluetooth"
//   * ...and then rejects the mapping on a VERSION COMPARISON:
//       "Skipping loading device personality: requires version '11.4.7'"
//
// The MGX mapping ships in a *downloaded* GameController DB asset
// (/var/MobileAsset/.../com_apple_MobileAsset_GameController_DB1) whose
// personality CompatibilityVersion (11.4.7 / 10.1.36) is newer than
// iOS 17.1.1's GameControllerFoundation. iOS 18.5 has a new enough runtime,
// which is why 8BitDo controllers "gained iOS support" there — not a new
// driver, just a version gate that finally passes.
//
// A second problem appears once the gate is open: the asset lists
// WithBackButtons.plist first, whose model declares button.p1/p2 paddles.
// Loading it against a base MGX fails driver configuration with
// GCGenericDeviceError Code=2. Selecting Default.plist fixes that.
//
// FIX: patch both in memory as GameControllerConfigService loads the plists.
// Nothing on disk is modified.

#import <Foundation/Foundation.h>
#import <dlfcn.h>

#define LOG(fmt, ...) NSLog((@"[MGXFix] " fmt), ##__VA_ARGS__)

#define kMGXDeviceIdentifier   @"com.8BitDo.UltimateMGX.Bluetooth"
#define kMGXDefaultPersonality @"Personalities/8BitDo/UltimateMGX/Default.plist"

// A personality is a dict with exactly these two top-level keys.
static BOOL MGXIsPersonality(id plist) {
    if (![plist isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *d = plist;
    return d[@"CompatibilityVersion"] != nil && d[@"Model"] != nil;
}

// The device database: force Default.plist for the MGX (see above).
static NSDictionary *MGXPatchDeviceDB(NSDictionary *db) {
    NSArray *devices = db[@"Devices"];
    if (![devices isKindOfClass:[NSArray class]]) return nil;

    BOOL changed = NO;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:devices.count];
    for (id dev in devices) {
        if ([dev isKindOfClass:[NSDictionary class]] &&
            [((NSDictionary *)dev)[@"Identifier"] isEqualToString:kMGXDeviceIdentifier]) {
            NSMutableDictionary *m = [dev mutableCopy];
            m[@"Personalities"] = @[kMGXDefaultPersonality];
            [out addObject:m];
            changed = YES;
        } else {
            [out addObject:dev];
        }
    }
    if (!changed) return nil;

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
    return MGXPatchCF(orig_CFPropertyListCreateWithURL(alloc, url, opts, fmt, err));
}

#pragma mark - Foundation layer

%group PersonalityPatch
%hook NSDictionary
+ (instancetype)dictionaryWithContentsOfFile:(NSString *)path {
    return MGXPatchAnyPlist(%orig) ?: %orig;
}
+ (instancetype)dictionaryWithContentsOfURL:(NSURL *)url {
    return MGXPatchAnyPlist(%orig) ?: %orig;
}
- (instancetype)initWithContentsOfFile:(NSString *)path {
    id result = %orig;
    id patched = MGXPatchAnyPlist(result);
    return patched ?: result;
}
- (instancetype)initWithContentsOfURL:(NSURL *)url {
    id result = %orig;
    id patched = MGXPatchAnyPlist(result);
    return patched ?: result;
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

    LOG(@"loaded in %@ — MGX personality patch active", [[NSProcessInfo processInfo] processName]);
}
