#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A narrow Core Audio bridge. The HAL callback only writes Float32 samples
/// into a lock-free ring buffer; analysis happens outside the realtime thread.
@interface NookSystemAudioCapture : NSObject

@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) double sampleRate;

- (nullable NSError *)startForBundleIdentifier:(nullable NSString *)bundleIdentifier
    NS_SWIFT_NAME(start(bundleIdentifier:));
- (void)stop;

- (NSUInteger)readSamplesIntoBuffer:(float *)buffer
                           capacity:(NSUInteger)capacity
    NS_SWIFT_NAME(readSamples(into:capacity:));

@end

NS_ASSUME_NONNULL_END
