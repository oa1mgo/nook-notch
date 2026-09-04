#import "NookSystemAudioCapture.h"

#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>

#include <array>
#include <atomic>
#include <cctype>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr size_t kRingCapacity = 1 << 17;
constexpr size_t kRingMask = kRingCapacity - 1;
NSString *const NookAudioCaptureErrorDomain = @"com.oaimgo.nook.audio-capture";

struct CaptureState {
    std::array<float, kRingCapacity> samples {};
    std::atomic<size_t> readIndex { 0 };
    std::atomic<size_t> writeIndex { 0 };
    std::atomic<bool> running { false };
    AudioObjectID tapID = kAudioObjectUnknown;
    AudioObjectID aggregateDeviceID = kAudioObjectUnknown;
    AudioDeviceIOProcID ioProcID = nullptr;
    AudioStreamBasicDescription format {};

    void resetBuffer() noexcept {
        readIndex.store(0, std::memory_order_relaxed);
        writeIndex.store(0, std::memory_order_relaxed);
    }

    void push(float sample) noexcept {
        const size_t write = writeIndex.load(std::memory_order_relaxed);
        const size_t next = (write + 1) & kRingMask;
        if (next == readIndex.load(std::memory_order_acquire)) {
            return;
        }
        samples[write] = sample;
        writeIndex.store(next, std::memory_order_release);
    }

    size_t read(float *destination, size_t capacity) noexcept {
        size_t read = readIndex.load(std::memory_order_relaxed);
        const size_t write = writeIndex.load(std::memory_order_acquire);
        size_t count = 0;
        while (read != write && count < capacity) {
            destination[count++] = samples[read];
            read = (read + 1) & kRingMask;
        }
        readIndex.store(read, std::memory_order_release);
        return count;
    }
};

AudioObjectPropertyAddress PropertyAddress(
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
    AudioObjectPropertyElement element = kAudioObjectPropertyElementMain
) noexcept {
    return { selector, scope, element };
}

NSString *StatusDescription(OSStatus status) {
    UInt32 value = CFSwapInt32HostToBig(static_cast<UInt32>(status));
    char characters[5] = {};
    memcpy(characters, &value, 4);
    bool printable = true;
    for (int index = 0; index < 4; ++index) {
        printable = printable && isprint(characters[index]);
    }
    if (printable) {
        return [NSString stringWithFormat:@"'%s'", characters];
    }
    return [NSString stringWithFormat:@"%d", static_cast<int>(status)];
}

NSError *CaptureError(OSStatus status, NSString *operation) {
    NSString *description = [NSString stringWithFormat:
        @"%@ failed with Core Audio status %@.", operation, StatusDescription(status)];
    return [NSError errorWithDomain:NookAudioCaptureErrorDomain
                               code:status
                           userInfo:@{ NSLocalizedDescriptionKey: description }];
}

bool HasInputStreams(AudioObjectID deviceID) noexcept {
    auto address = PropertyAddress(
        kAudioDevicePropertyStreams,
        kAudioDevicePropertyScopeInput
    );
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(
        deviceID, &address, 0, nullptr, &size);
    return status == kAudioHardwareNoError && size >= sizeof(AudioObjectID);
}

bool WaitForInputStreams(AudioObjectID deviceID) noexcept {
    // Aggregate-device composition is applied asynchronously by the HAL. An
    // immediate AudioDeviceStart can otherwise fail with 'nope' even though
    // the tap and permission are both valid.
    constexpr int kMaximumAttempts = 200;
    constexpr useconds_t kPollIntervalMicroseconds = 10'000;
    for (int attempt = 0; attempt < kMaximumAttempts; ++attempt) {
        if (HasInputStreams(deviceID)) {
            return true;
        }
        usleep(kPollIntervalMicroseconds);
    }
    return false;
}

OSStatus StartDeviceWhenReady(
    AudioObjectID deviceID,
    AudioDeviceIOProcID ioProcID
) noexcept {
    // The first start is also the system-audio TCC trigger. While the native
    // prompt is pending, Core Audio can return IllegalOperation immediately;
    // retry the same configured device long enough for a normal user response.
    constexpr int kMaximumAttempts = 60;
    constexpr useconds_t kRetryIntervalMicroseconds = 250'000;
    OSStatus status = kAudioHardwareNoError;
    for (int attempt = 0; attempt < kMaximumAttempts; ++attempt) {
        status = AudioDeviceStart(deviceID, ioProcID);
        if (status == kAudioHardwareNoError
                || status != kAudioHardwareIllegalOperationError) {
            return status;
        }
        usleep(kRetryIntervalMicroseconds);
    }
    return status;
}

NSArray<NSNumber *> *AudioProcessIDs(NSString * _Nullable bundleIdentifier, bool matchTarget) {
    auto address = PropertyAddress(kAudioHardwarePropertyProcessObjectList);
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(
        kAudioObjectSystemObject, &address, 0, nullptr, &size);
    if (status != kAudioHardwareNoError || size == 0) {
        return @[];
    }

    const size_t count = size / sizeof(AudioObjectID);
    std::unique_ptr<AudioObjectID[]> processIDs(new AudioObjectID[count]);
    status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &address, 0, nullptr, &size, processIDs.get());
    if (status != kAudioHardwareNoError) {
        return @[];
    }

    NSMutableArray<NSNumber *> *matches = [NSMutableArray array];
    const pid_t ownPID = getpid();
    for (size_t index = 0; index < count; ++index) {
        const AudioObjectID processID = processIDs[index];

        if (!matchTarget) {
            auto pidAddress = PropertyAddress(kAudioProcessPropertyPID);
            pid_t pid = 0;
            UInt32 pidSize = sizeof(pid);
            if (AudioObjectGetPropertyData(processID, &pidAddress, 0, nullptr, &pidSize, &pid)
                    == kAudioHardwareNoError && pid == ownPID) {
                [matches addObject:@(processID)];
            }
            continue;
        }

        if (bundleIdentifier.length == 0) {
            continue;
        }

        auto bundleAddress = PropertyAddress(kAudioProcessPropertyBundleID);
        CFStringRef processBundleID = nullptr;
        UInt32 bundleSize = sizeof(processBundleID);
        status = AudioObjectGetPropertyData(
            processID, &bundleAddress, 0, nullptr, &bundleSize, &processBundleID);
        if (status != kAudioHardwareNoError || processBundleID == nullptr) {
            continue;
        }

        NSString *resolvedBundleID = (__bridge NSString *)processBundleID;
        BOOL isMatch = [resolvedBundleID isEqualToString:bundleIdentifier]
            || [resolvedBundleID hasPrefix:[bundleIdentifier stringByAppendingString:@"."]];
        CFRelease(processBundleID);
        if (isMatch) {
            auto runningOutputAddress = PropertyAddress(kAudioProcessPropertyIsRunningOutput);
            UInt32 isRunningOutput = 0;
            UInt32 runningOutputSize = sizeof(isRunningOutput);
            if (AudioObjectGetPropertyData(
                    processID,
                    &runningOutputAddress,
                    0,
                    nullptr,
                    &runningOutputSize,
                    &isRunningOutput) == kAudioHardwareNoError
                    && isRunningOutput != 0) {
                [matches addObject:@(processID)];
            }
        }
    }
    return matches;
}

OSStatus AudioIOProc(
    AudioObjectID,
    const AudioTimeStamp *,
    const AudioBufferList *inputData,
    const AudioTimeStamp *,
    AudioBufferList *,
    const AudioTimeStamp *,
    void *clientData
) noexcept {
    auto *state = static_cast<CaptureState *>(clientData);
    if (state == nullptr || inputData == nullptr || !state->running.load(std::memory_order_relaxed)) {
        return kAudioHardwareNoError;
    }

    for (UInt32 bufferIndex = 0; bufferIndex < inputData->mNumberBuffers; ++bufferIndex) {
        const AudioBuffer &buffer = inputData->mBuffers[bufferIndex];
        if (buffer.mData == nullptr || buffer.mDataByteSize == 0) {
            continue;
        }

        const UInt32 channels = MAX(buffer.mNumberChannels, 1u);
        const UInt32 frameCount = buffer.mDataByteSize / (sizeof(float) * channels);
        const float *source = static_cast<const float *>(buffer.mData);
        for (UInt32 frame = 0; frame < frameCount; ++frame) {
            float mono = 0;
            for (UInt32 channel = 0; channel < channels; ++channel) {
                mono += source[frame * channels + channel];
            }
            state->push(mono / static_cast<float>(channels));
        }
    }

    return kAudioHardwareNoError;
}

} // namespace

@implementation NookSystemAudioCapture {
    std::unique_ptr<CaptureState> _state;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _state = std::make_unique<CaptureState>();
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)isRunning {
    return _state->running.load(std::memory_order_acquire);
}

- (double)sampleRate {
    return _state->format.mSampleRate;
}

- (NSError * _Nullable)startForBundleIdentifier:(NSString * _Nullable)bundleIdentifier {
    [self stop];
    _state->resetBuffer();

    NSArray<NSNumber *> *targetProcesses = AudioProcessIDs(bundleIdentifier, true);
    CATapDescription *tapDescription;
    if (targetProcesses.count > 0) {
        tapDescription = [[CATapDescription alloc] initMonoMixdownOfProcesses:targetProcesses];
    } else {
        // Browser helpers don't always expose the same bundle identifier as
        // MediaRemote. Falling back to the system mix keeps the feature useful;
        // Nook itself is excluded to prevent feedback from notification sounds.
        tapDescription = [[CATapDescription alloc]
            initMonoGlobalTapButExcludeProcesses:AudioProcessIDs(nil, false)];
    }
    tapDescription.name = @"Nook Music Glow";
    tapDescription.privateTap = YES;
    tapDescription.muteBehavior = CATapUnmuted;

    OSStatus status = AudioHardwareCreateProcessTap(tapDescription, &_state->tapID);
    if (status != kAudioHardwareNoError) {
        NSError *error = CaptureError(status, @"Creating the system audio tap");
        [self stop];
        return error;
    }

    auto formatAddress = PropertyAddress(kAudioTapPropertyFormat);
    UInt32 formatSize = sizeof(_state->format);
    status = AudioObjectGetPropertyData(
        _state->tapID, &formatAddress, 0, nullptr, &formatSize, &_state->format);
    const bool isFloat32PCM = status == kAudioHardwareNoError
        && _state->format.mFormatID == kAudioFormatLinearPCM
        && (_state->format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        && _state->format.mBitsPerChannel == 32;
    if (!isFloat32PCM) {
        NSError *error = status == kAudioHardwareNoError
            ? [NSError errorWithDomain:NookAudioCaptureErrorDomain
                                  code:-1
                              userInfo:@{ NSLocalizedDescriptionKey:
                                  @"The system audio tap did not provide Float32 PCM audio." }]
            : CaptureError(status, @"Reading the system audio format");
        [self stop];
        return error;
    }

    auto uidAddress = PropertyAddress(kAudioTapPropertyUID);
    CFStringRef tapUID = nullptr;
    UInt32 uidSize = sizeof(tapUID);
    status = AudioObjectGetPropertyData(
        _state->tapID, &uidAddress, 0, nullptr, &uidSize, &tapUID);
    if (status != kAudioHardwareNoError || tapUID == nullptr) {
        NSError *error = status == kAudioHardwareNoError
            ? [NSError errorWithDomain:NookAudioCaptureErrorDomain
                                  code:-2
                              userInfo:@{ NSLocalizedDescriptionKey:
                                  @"The system audio tap did not provide an identifier." }]
            : CaptureError(status, @"Reading the system audio tap identifier");
        [self stop];
        return error;
    }

    NSString *aggregateUID = [NSString stringWithFormat:@"com.oaimgo.nook.music-glow.%@",
        NSUUID.UUID.UUIDString];
    NSDictionary *aggregateDescription = @{
        @kAudioAggregateDeviceNameKey: @"Nook Music Glow Audio",
        @kAudioAggregateDeviceUIDKey: aggregateUID,
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceTapListKey: @[
            @{
                @kAudioSubTapUIDKey: (__bridge NSString *)tapUID,
                @kAudioSubTapDriftCompensationKey: @NO
            }
        ]
    };
    status = AudioHardwareCreateAggregateDevice(
        (__bridge CFDictionaryRef)aggregateDescription, &_state->aggregateDeviceID);
    CFRelease(tapUID);
    if (status != kAudioHardwareNoError) {
        NSError *error = CaptureError(status, @"Creating the private audio device");
        [self stop];
        return error;
    }

    if (!WaitForInputStreams(_state->aggregateDeviceID)) {
        NSError *error = [NSError errorWithDomain:NookAudioCaptureErrorDomain
                                              code:kAudioHardwareIllegalOperationError
                                          userInfo:@{ NSLocalizedDescriptionKey:
                                              @"The system audio device did not expose an input stream." }];
        [self stop];
        return error;
    }

    status = AudioDeviceCreateIOProcID(
        _state->aggregateDeviceID, AudioIOProc, _state.get(), &_state->ioProcID);
    if (status != kAudioHardwareNoError) {
        NSError *error = CaptureError(status, @"Preparing system audio analysis");
        [self stop];
        return error;
    }

    _state->running.store(true, std::memory_order_release);
    status = StartDeviceWhenReady(_state->aggregateDeviceID, _state->ioProcID);
    if (status != kAudioHardwareNoError) {
        _state->running.store(false, std::memory_order_release);
        NSError *error = CaptureError(status, @"Starting system audio analysis");
        [self stop];
        return error;
    }

    return nil;
}

- (void)stop {
    if (_state == nullptr) {
        return;
    }

    _state->running.store(false, std::memory_order_release);
    if (_state->ioProcID != nullptr && _state->aggregateDeviceID != kAudioObjectUnknown) {
        AudioDeviceStop(_state->aggregateDeviceID, _state->ioProcID);
        AudioDeviceDestroyIOProcID(_state->aggregateDeviceID, _state->ioProcID);
        _state->ioProcID = nullptr;
    }
    if (_state->aggregateDeviceID != kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(_state->aggregateDeviceID);
        _state->aggregateDeviceID = kAudioObjectUnknown;
    }
    if (_state->tapID != kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(_state->tapID);
        _state->tapID = kAudioObjectUnknown;
    }
    memset(&_state->format, 0, sizeof(_state->format));
    _state->resetBuffer();
}

- (NSUInteger)readSamplesIntoBuffer:(float *)buffer capacity:(NSUInteger)capacity {
    if (buffer == nullptr || capacity == 0) {
        return 0;
    }
    return _state->read(buffer, capacity);
}

@end
