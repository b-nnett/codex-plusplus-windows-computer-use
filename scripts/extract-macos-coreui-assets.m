#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <CoreServices/CoreServices.h>

@interface NSObject (CoreUIPrivate)
- (id)initWithURL:(NSURL *)url error:(NSError **)error;
- (NSArray *)allImageNames;
- (id)imageWithName:(NSString *)name scaleFactor:(double)scale;
- (id)image;
@end

static NSString *safeFileName(NSString *name) {
  NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>"];
  NSArray *parts = [name componentsSeparatedByCharactersInSet:bad];
  return [parts componentsJoinedByString:@"_"];
}

static BOOL writeCGPNG(CGImageRef cg, NSURL *url, NSError **error) {
  if (!cg) {
    if (error) {
      *error = [NSError errorWithDomain:@"ExtractCoreUI"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: @"Missing CGImage"}];
    }
    return NO;
  }

  CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
    (__bridge CFURLRef)url,
    kUTTypePNG,
    1,
    NULL
  );
  if (!dest) {
    if (error) {
      *error = [NSError errorWithDomain:@"ExtractCoreUI"
                                   code:2
                               userInfo:@{NSLocalizedDescriptionKey: @"Could not create PNG destination"}];
    }
    return NO;
  }

  CGImageDestinationAddImage(dest, cg, NULL);
  BOOL ok = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  if (!ok && error) {
    *error = [NSError errorWithDomain:@"ExtractCoreUI"
                                 code:3
                             userInfo:@{NSLocalizedDescriptionKey: @"Could not finalize PNG"}];
  }
  return ok;
}

static CGImageRef cgImageFromObject(id imageObj) {
  if ([imageObj isKindOfClass:[NSImage class]]) {
    return [(NSImage *)imageObj CGImageForProposedRect:NULL context:nil hints:nil];
  }
  CFTypeID typeID = CFGetTypeID((__bridge CFTypeRef)imageObj);
  if (typeID == CGImageGetTypeID()) {
    return (__bridge CGImageRef)imageObj;
  }
  return nil;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 3) {
      fprintf(stderr, "usage: extract-macos-coreui-assets <Assets.car> <outdir>\n");
      return 2;
    }

    [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/CoreUI.framework"] load];
    Class CUICatalog = NSClassFromString(@"CUICatalog");
    if (!CUICatalog) {
      fprintf(stderr, "CUICatalog unavailable\n");
      return 3;
    }

    NSURL *carURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
    NSURL *outURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]] isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:outURL
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];

    NSError *err = nil;
    id catalog = [[CUICatalog alloc] initWithURL:carURL error:&err];
    if (!catalog) {
      fprintf(stderr, "catalog init failed: %s\n", err.localizedDescription.UTF8String ?: "unknown");
      return 4;
    }

    NSArray *names = [catalog allImageNames] ?: @[];
    NSMutableArray *manifest = [NSMutableArray array];
    for (NSString *name in names) {
      id named = [catalog imageWithName:name scaleFactor:1.0];
      id imageObj = [named respondsToSelector:@selector(image)] ? [named image] : nil;
      CGImageRef cg = cgImageFromObject(imageObj);
      if (!cg) {
        fprintf(stderr, "skip %s: image object is %s\n",
                name.UTF8String,
                NSStringFromClass([imageObj class]).UTF8String);
        continue;
      }

      NSString *fileName = [[safeFileName(name) stringByAppendingString:@".png"] copy];
      NSURL *dest = [outURL URLByAppendingPathComponent:fileName];
      NSError *writeErr = nil;
      if (!writeCGPNG(cg, dest, &writeErr)) {
        fprintf(stderr, "write failed %s: %s\n",
                name.UTF8String,
                writeErr.localizedDescription.UTF8String ?: "unknown");
        continue;
      }

      [manifest addObject:@{
        @"name": name,
        @"file": fileName,
        @"class": NSStringFromClass([named class]) ?: @"",
        @"imageClass": NSStringFromClass([imageObj class]) ?: @"",
        @"width": @(CGImageGetWidth(cg)),
        @"height": @(CGImageGetHeight(cg))
      }];
      printf("extracted %s -> %s\n", name.UTF8String, fileName.UTF8String);
    }

    NSData *json = [NSJSONSerialization dataWithJSONObject:manifest
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    [json writeToURL:[outURL URLByAppendingPathComponent:@"manifest.json"] atomically:YES];
    return 0;
  }
}
