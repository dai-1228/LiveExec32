#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <stdio.h>

static unsigned imageDeallocations;
static char imageLifetimeKey;

@interface LC32ImageLifetimeProbe : NSObject
@end

@implementation LC32ImageLifetimeProbe
- (void)dealloc {
    ++imageDeallocations;
    [super dealloc];
}
@end

static BOOL report(const char *name, BOOL passed) {
    printf("%s: %s\n", name, passed ? "PASS" : "FAIL");
    return passed;
}

static void observeImageLifetime(UIImage *image) {
    if(!image) return;
    LC32ImageLifetimeProbe *probe = [LC32ImageLifetimeProbe new];
    objc_setAssociatedObject(image, &imageLifetimeKey, probe,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [probe release];
}

static BOOL testCGImageInitializers(void) {
    UIImage *plain = nil;
    UIImage *scaled = nil;
    BOOL passed = YES;
    @autoreleasepool {
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = colorSpace ? CGBitmapContextCreate(
            NULL, 8, 6, 8, 32, colorSpace,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
        if(context) {
            CGContextSetRGBFillColor(context, 1.0f, 0.0f, 0.0f, 1.0f);
            CGContextFillRect(context, CGRectMake(0, 0, 8, 6));
        }
        CGImageRef source = context ? CGBitmapContextCreateImage(context) : NULL;
        passed &= report("image-init-cgimage-source", source != NULL);
        if(source) {
            plain = [[UIImage alloc] initWithCGImage:source];
            scaled = [[UIImage alloc] initWithCGImage:source scale:2.0f
                                        orientation:UIImageOrientationDownMirrored];
            observeImageLifetime(plain);
            observeImageLifetime(scaled);
            CGImageRelease(source);
        }
        if(context) CGContextRelease(context);
        if(colorSpace) CGColorSpaceRelease(colorSpace);
    }

    /* Both init methods return +1 objects, not autoreleased bridge results.
     * They must also preserve the image data after releasing every source
     * CoreGraphics object and draining the initializer's autorelease pool. */
    passed &= report("image-init-cgimage-owned", plain && plain.CGImage &&
        plain.size.width == 8.0f && plain.size.height == 6.0f &&
        plain.scale == 1.0f && plain.imageOrientation == UIImageOrientationUp &&
        CGImageGetWidth(plain.CGImage) == 8 && CGImageGetHeight(plain.CGImage) == 6);
    passed &= report("image-init-cgimage-scale-orientation", scaled && scaled.CGImage &&
        scaled.size.width == 4.0f && scaled.size.height == 3.0f &&
        scaled.scale == 2.0f && scaled.imageOrientation == UIImageOrientationDownMirrored &&
        CGImageGetWidth(scaled.CGImage) == 8 && CGImageGetHeight(scaled.CGImage) == 6);
    passed &= report("image-init-cgimage-lifetime", imageDeallocations == 0 &&
        UIImageJPEGRepresentation(plain, 0.75f).length > 0 &&
        UIImageJPEGRepresentation(scaled, 0.75f).length > 0);
    [plain release];
    [scaled release];
    passed &= report("image-init-cgimage-release", imageDeallocations == 2);
    return passed;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        UIGraphicsBeginImageContextWithOptions(
            CGSizeMake(4.0f, 3.0f), YES, 2.0f);
        UIRectFill(CGRectMake(0.0f, 0.0f, 4.0f, 3.0f));
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        const BOOL imagePassed = image != nil &&
            image.size.width == 4.0f && image.size.height == 3.0f;
        printf("image-context-options: %s (%g,%g)\n",
               imagePassed ? "PASS" : "FAIL",
               image.size.width, image.size.height);

        NSData *jpeg = UIImageJPEGRepresentation(image, 0.75f);
        const BOOL jpegPassed = jpeg.length > 0;
        printf("image-jpeg-representation: %s (%lu bytes)\n",
               jpegPassed ? "PASS" : "FAIL",
               (unsigned long)jpeg.length);
        const BOOL initializersPassed = testCGImageInitializers();
        return imagePassed && jpegPassed && initializersPassed ? 0 : 1;
    }
}
