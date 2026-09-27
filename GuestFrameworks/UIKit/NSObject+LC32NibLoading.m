#import <LC32/LC32.h>
#import <UIKit/UIKit.h>

/* UINibLoadingAdditions belongs to NSObject, not a UIKit class. The captured
 * UIKit class methods therefore omit this inherited implementation, leaving
 * ordinary objects and controls unable to receive awakeFromNib or complete
 * a guest subclass's [super awakeFromNib]. */
@implementation NSObject (LC32NibLoading)

- (void)awakeFromNib {
    static uint64_t hostSelector __attribute__((aligned(8)));
    const uint64_t selector = LC32CachedHostSelector(
        &hostSelector, _cmd, NO);
    LC32InvokeHostSelector(self.host_self, selector, (uint64_t)0);
}

@end
