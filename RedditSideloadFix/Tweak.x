#import <DeviceCheck/DeviceCheck.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import "fishhook/fishhook.h"

#define BUNDLE_NAME @"Reddit"
#define BUNDLE_ID @"com.reddit.Reddit"
#define TEAM_ID @"2TDUX39LX8"

// https://github.com/opa334/IGSideloadFix

static NSString *keychainAccessGroup;
static NSString *originalKeychainAccessGroup;
static NSURL *fakeGroupContainerURL;

static void createDirectoryIfNotExists(NSURL *URL) {
  if (![URL checkResourceIsReachableAndReturnError:nil]) {
    [[NSFileManager defaultManager] createDirectoryAtURL:URL
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
  }
}

%hook NSBundle

- (NSString *)bundleIdentifier {
  NSArray <NSNumber *>*addresses = NSThread.callStackReturnAddresses;
  if (addresses.count < 3) return %orig;
  Dl_info info;
  if (dladdr((void *)[addresses[2] longLongValue], &info) == 0) return %orig;
  NSString *path = [NSString stringWithUTF8String:info.dli_fname];
  if ([path hasPrefix:NSBundle.mainBundle.bundlePath]) return BUNDLE_ID;
  return %orig;
}

- (id)objectForInfoDictionaryKey:(NSString *)key {
  if ([key isEqualToString:@"CFBundleIdentifier"]) return BUNDLE_ID;
  if ([key isEqualToString:@"CFBundleDisplayName"] || [key isEqualToString:@"CFBundleName"])
    return BUNDLE_NAME;
  return %orig;
}

%end

%group SideloadedFixes

%hook NSFileManager

- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
  NSURL *fakeURL = [fakeGroupContainerURL URLByAppendingPathComponent:groupIdentifier];

  createDirectoryIfNotExists(fakeURL);
  createDirectoryIfNotExists([fakeURL URLByAppendingPathComponent:@"Library"]);
  createDirectoryIfNotExists([fakeURL URLByAppendingPathComponent:@"Library/Caches"]);

  return fakeURL;
}

%end

static void loadKeychainAccessGroup() {
  NSDictionary *dummyItem = @{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrAccount : @"dummyItem",
    (__bridge id)kSecAttrService : @"dummyService",
    (__bridge id)kSecReturnAttributes : @YES,
  };

  CFTypeRef result = NULL;
  OSStatus ret = SecItemCopyMatching((__bridge CFDictionaryRef)dummyItem, &result);
  if (ret == errSecItemNotFound) ret = SecItemAdd((__bridge CFDictionaryRef)dummyItem, &result);

  if (ret == errSecSuccess && result && CFGetTypeID(result) == CFDictionaryGetTypeID()) {
    NSDictionary *resultDict = (__bridge id)result;
    NSString *group = resultDict[(__bridge id)kSecAttrAccessGroup];
    // "<team ID>.<bundle ID>": swap in the original team ID.
    if ([group isKindOfClass:NSString.class] && group.length > 10) {
      keychainAccessGroup = group;
      originalKeychainAccessGroup = [group stringByReplacingCharactersInRange:NSMakeRange(0, 10)
                                                                   withString:TEAM_ID];
      NSLog(@"loaded keychainAccessGroup: %@", keychainAccessGroup);
    }
  }
  if (!keychainAccessGroup) NSLog(@"couldn't load keychainAccessGroup (%d)", (int)ret);

  if (result) CFRelease(result);
}

%end

// A copy of dict with its access group set to group, or NULL if it has none (or group is unknown).
// The caller releases the copy.
static CFDictionaryRef copyWithAccessGroup(CFDictionaryRef dict, NSString *group) {
  if (!group || !dict || !CFDictionaryContainsKey(dict, kSecAttrAccessGroup)) return NULL;
  CFMutableDictionaryRef mutableDict = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, dict);
  CFDictionarySetValue(mutableDict, kSecAttrAccessGroup, (__bridge void *)group);
  CFDictionaryRef copy = CFDictionaryCreateCopy(kCFAllocatorDefault, mutableDict);
  CFRelease(mutableDict);
  return copy;
}

// Shows the app the access group it expects in a returned item.
static void fixResult(CFTypeRef *result) {
  if (!result || !*result || CFGetTypeID(*result) != CFDictionaryGetTypeID()) return;
  CFDictionaryRef fixed = copyWithAccessGroup(*result, originalKeychainAccessGroup);
  if (!fixed) return;
  CFRelease(*result);
  *result = fixed;
}

static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus hook_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
  CFDictionaryRef fixed = copyWithAccessGroup(attributes, keychainAccessGroup);
  OSStatus status = orig_SecItemAdd(fixed ?: attributes, result);
  if (fixed) CFRelease(fixed);
  if (status == errSecSuccess) fixResult(result);
  return status;
}

static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus hook_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
  CFDictionaryRef fixed = copyWithAccessGroup(query, keychainAccessGroup);
  OSStatus status = orig_SecItemCopyMatching(fixed ?: query, result);
  if (fixed) CFRelease(fixed);
  if (status == errSecSuccess) fixResult(result);
  return status;
}

static OSStatus (*orig_SecItemDelete)(CFDictionaryRef);
static OSStatus hook_SecItemDelete(CFDictionaryRef query) {
  CFDictionaryRef fixed = copyWithAccessGroup(query, keychainAccessGroup);
  OSStatus status = orig_SecItemDelete(fixed ?: query);
  if (fixed) CFRelease(fixed);
  return status;
}

static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus hook_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
  CFDictionaryRef fixed = copyWithAccessGroup(query, keychainAccessGroup);
  OSStatus status = orig_SecItemUpdate(fixed ?: query, attributesToUpdate);
  if (fixed) CFRelease(fixed);
  return status;
}

static void initSideloadedFixes() {
  fakeGroupContainerURL =
      [NSURL fileURLWithPath:[NSHomeDirectory()
                                 stringByAppendingPathComponent:@"Documents/FakeGroupContainers"]
                 isDirectory:YES];
  loadKeychainAccessGroup();
  rebind_symbols(
      (struct rebinding[]){
          {"SecItemAdd", (void *)hook_SecItemAdd, (void **)&orig_SecItemAdd},
          {"SecItemCopyMatching", (void *)hook_SecItemCopyMatching,
           (void **)&orig_SecItemCopyMatching},
          {"SecItemDelete", (void *)hook_SecItemDelete, (void **)&orig_SecItemDelete},
          {"SecItemUpdate", (void *)hook_SecItemUpdate, (void **)&orig_SecItemUpdate},
      },
      4);
  %init(SideloadedFixes);
}

// App Attest and DeviceCheck prove to Reddit that the app is its own build, signed by its own team.
// A re-signed app can only prove it's someone else's, and Reddit refuses to log that in. Devices
// that can't do App Attest at all are still allowed, so report it as unsupported on this one.
static NSError *deviceCheckUnsupported(void) {
  return [NSError errorWithDomain:DCErrorDomain code:DCErrorFeatureUnsupported userInfo:nil];
}

%group AttestFixes

%hook DCAppAttestService
- (BOOL)isSupported {
  return NO;
}
- (void)generateKeyWithCompletionHandler:(void (^)(NSString *, NSError *))completionHandler {
  if (completionHandler) completionHandler(nil, deviceCheckUnsupported());
}
- (void)attestKey:(NSString *)keyId
     clientDataHash:(NSData *)clientDataHash
  completionHandler:(void (^)(NSData *, NSError *))completionHandler {
  if (completionHandler) completionHandler(nil, deviceCheckUnsupported());
}
- (void)generateAssertion:(NSString *)keyId
           clientDataHash:(NSData *)clientDataHash
        completionHandler:(void (^)(NSData *, NSError *))completionHandler {
  if (completionHandler) completionHandler(nil, deviceCheckUnsupported());
}
%end

%hook DCDevice
- (BOOL)isSupported {
  return NO;
}
- (void)generateTokenWithCompletionHandler:(void (^)(NSData *, NSError *))completionHandler {
  if (completionHandler) completionHandler(nil, deviceCheckUnsupported());
}
%end

%end

static void initAttestFixes(void) {
  %init(AttestFixes);
}

static NSString *originalBundleIdentifier;

static void recaptcha_hook(id self, SEL _cmd, id arg) {
  Class cls = object_getClass(self);
  SEL orig_name = NSSelectorFromString([@"orig_" stringByAppendingString:NSStringFromSelector(_cmd)]);
  void (*orig_imp)(id, SEL, id);
  Method method = class_getInstanceMethod(cls, orig_name);

  if (!method) {
    method = class_getClassMethod(cls, orig_name);
    if (method) {
      orig_imp = (void (*)(id, SEL, id))method_getImplementation(method);
      orig_imp(self, orig_name, arg);
    }
    // In case there is no method (is this possible? idk)
    return;
  }

  if ([arg isKindOfClass:NSString.class] && [(NSString *)arg isEqualToString:originalBundleIdentifier])
    arg = BUNDLE_ID;

  orig_imp = (void (*)(id, SEL, id))method_getImplementation(method);
  orig_imp(self, orig_name, arg);
}

static BOOL (*orig_class_addMethod)(Class, SEL, IMP, const char *);
static BOOL hook_class_addMethod(Class cls, SEL name, IMP imp, const char *types) {
  NSString *methodEncoding = [@(types) stringByReplacingOccurrencesOfString:@"[0-9]+" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, strlen(types))];
  if ([class_getSuperclass(cls) isEqual:objc_getClass("RCAx_GPBMessage")] && [methodEncoding isEqualToString:@"v@:@"]) {
    if (!orig_class_addMethod(cls, NSSelectorFromString([@"orig_" stringByAppendingString:NSStringFromSelector(name)]), imp, types))
      return orig_class_addMethod(cls, name, imp, types);
    imp = (IMP)recaptcha_hook;
  }

  return orig_class_addMethod(cls, name, imp, types);
}

static void initRecaptchaFix() {
  rebind_symbols((struct rebinding[]){{
    "class_addMethod", (void *)hook_class_addMethod, (void **)&orig_class_addMethod,
  }}, 1);
}

%ctor {
  originalBundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
  %init;
  initSideloadedFixes();
  initRecaptchaFix();
  initAttestFixes();
}
