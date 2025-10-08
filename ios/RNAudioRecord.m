#import "RNAudioRecord.h"
#import <AVFoundation/AVFoundation.h>

@interface RNAudioRecord () <AVAudioRecorderDelegate>
@property (nonatomic, readwrite, copy) NSString *filePath;
@property (nonatomic, strong) AVAudioRecorder *audioRecorder;
@property (nonatomic, strong) NSTimer *meteringTimer;
@property (nonatomic, assign) BOOL isRecording;
@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, strong) NSMutableData *pcmAccumulatedBuffer;
@property (nonatomic, assign) NSUInteger targetChunkBytes;
@property (nonatomic, assign) double configuredSampleRate;
@property (nonatomic, assign) int configuredChannels;
@property (nonatomic, assign) int configuredBitsPerSample;
@end

@implementation RNAudioRecord {
    BOOL hasListeners;
}

RCT_EXPORT_MODULE();

- (dispatch_queue_t)methodQueue {
    return dispatch_get_main_queue();
}

- (BOOL)setupAudioSession {
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];

    // Request permission first
    if ([session respondsToSelector:@selector(requestRecordPermission:)]) {
        __block BOOL permissionGranted = NO;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        [session requestRecordPermission:^(BOOL granted) {
            permissionGranted = granted;
            dispatch_semaphore_signal(sem);
        }];

        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

        if (!permissionGranted) {
            RCTLogInfo(@"[RNAudioRecord] Record permission denied");
            return NO;
        }
        RCTLogInfo(@"[RNAudioRecord] Record permission granted");
    }

    // Configure session with enhanced audio quality
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                    mode:AVAudioSessionModeDefault
                    options:AVAudioSessionCategoryOptionDefaultToSpeaker |
                            AVAudioSessionCategoryOptionAllowBluetooth |
                            AVAudioSessionCategoryOptionMixWithOthers
                    error:&error]) {
        RCTLogInfo(@"[RNAudioRecord] Failed to set category: %@", error);
        return NO;
    }

    // Activate session
    if (![session setActive:YES error:&error]) {
        RCTLogInfo(@"[RNAudioRecord] Failed to activate session: %@", error);
        return NO;
    }
    RCTLogInfo(@"[RNAudioRecord] Successfully activated audio session");

    // Log session state
    RCTLogInfo(@"[RNAudioRecord] Session state:");
    RCTLogInfo(@"[RNAudioRecord] - Input available: %d", session.isInputAvailable);
    RCTLogInfo(@"[RNAudioRecord] - Sample rate: %f", session.sampleRate);
    RCTLogInfo(@"[RNAudioRecord] - Category: %@", session.category);
    RCTLogInfo(@"[RNAudioRecord] - Mode: %@", session.mode);

    return YES;
}

RCT_EXPORT_METHOD(init:(NSDictionary *)options) {
    RCTLogInfo(@"[RNAudioRecord] Initializing with options: %@", options);

    // Setup file path
    NSString *fileName = options[@"wavFile"] == nil ? @"audio.wav" : options[@"wavFile"];
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    self.filePath = [NSString stringWithFormat:@"%@/%@", docDir, fileName];

    // Remove existing file
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.filePath]) {
        [[NSFileManager defaultManager] removeItemAtPath:self.filePath error:nil];
    }

    // Setup audio session
    if (![self setupAudioSession]) {
        return;
    }

    // Get desired/actual session sample rate
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSNumber *optSampleRate = options[@"sampleRate"];
    NSNumber *optChannels = options[@"channels"];
    NSNumber *optBits = options[@"bitsPerSample"];
    self.configuredSampleRate = optSampleRate ? [optSampleRate doubleValue] : session.sampleRate;
    self.configuredChannels = optChannels ? [optChannels intValue] : 1;
    self.configuredBitsPerSample = optBits ? [optBits intValue] : 16;
    if (self.configuredSampleRate <= 0) {
        self.configuredSampleRate = 16000.0;
    }
    if (self.configuredChannels <= 0) {
        self.configuredChannels = 1;
    }
    if (self.configuredBitsPerSample != 8 && self.configuredBitsPerSample != 16 && self.configuredBitsPerSample != 32) {
        self.configuredBitsPerSample = 16;
    }
    // Try to prefer the configured sample rate and IO buffer duration (~20ms)
    NSError *prefErr = nil;
    [session setPreferredSampleRate:self.configuredSampleRate error:&prefErr];
    [session setPreferredIOBufferDuration:0.02 error:nil]; // Use 20ms for better real-time performance

    // Force the session to use our configured sample rate
    if (self.configuredSampleRate > 0) {
        [session setPreferredSampleRate:self.configuredSampleRate error:&prefErr];
        // Try to set the actual sample rate
        [session setPreferredSampleRate:self.configuredSampleRate error:&prefErr];
    }
    if (prefErr) {
        RCTLogInfo(@"[RNAudioRecord] setPreferredSampleRate error: %@", prefErr);
    }
    double actualSampleRate = session.sampleRate;

    // Log the actual vs configured sample rates
    RCTLogInfo(@"[RNAudioRecord] Configured sample rate: %.1f, Actual sample rate: %.1f", self.configuredSampleRate, actualSampleRate);

    // Setup audio settings - use configured sample rate for consistency
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(self.configuredSampleRate),
        AVNumberOfChannelsKey: @(self.configuredChannels),
        AVLinearPCMBitDepthKey: @(self.configuredBitsPerSample),
        AVLinearPCMIsFloatKey: @(NO),
        AVLinearPCMIsBigEndianKey: @(NO),
        AVLinearPCMIsNonInterleaved: @(NO)
    };

    RCTLogInfo(@"[RNAudioRecord] Audio settings: %@", settings);

    // Initialize recorder
    NSError *error = nil;
    NSURL *url = [NSURL fileURLWithPath:self.filePath];

    self.audioRecorder = [[AVAudioRecorder alloc] initWithURL:url
                                                    settings:settings
                                                    error:&error];

    if (error || !self.audioRecorder) {
        RCTLogInfo(@"[RNAudioRecord] Failed to initialize recorder: %@", error);
        return;
    }

    self.audioRecorder.delegate = self;
    self.audioRecorder.meteringEnabled = YES;

    BOOL prepared = [self.audioRecorder prepareToRecord];
    RCTLogInfo(@"[RNAudioRecord] Prepare to record result: %d", prepared);

    if (!prepared) {
        RCTLogInfo(@"[RNAudioRecord] Failed to prepare recorder");
        return;
    }

    // Prepare PCM buffer accumulation (emit ~20ms frames by default)
    NSUInteger bytesPerSample = (NSUInteger)(self.configuredBitsPerSample / 8);
    NSUInteger frameSamples20ms = (NSUInteger)(self.configuredSampleRate * 0.02); // Use configured sample rate for 20ms
    self.targetChunkBytes = MAX(1, frameSamples20ms * self.configuredChannels * bytesPerSample);
    self.pcmAccumulatedBuffer = [NSMutableData data];
    self.audioEngine = [AVAudioEngine new];

    RCTLogInfo(@"[RNAudioRecord] Setup complete (targetChunkBytes=%lu, sampleRate=%.1f, channels=%d, bits=%d)", (unsigned long)self.targetChunkBytes, self.configuredSampleRate, self.configuredChannels, self.configuredBitsPerSample);
}

RCT_EXPORT_METHOD(start) {
    if (!self.audioRecorder) {
        RCTLogInfo(@"[RNAudioRecord] Recorder not initialized");
        return;
    }

    // Ensure proper session configuration before starting
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;

    // Log pre-start state
    RCTLogInfo(@"[RNAudioRecord] Pre-start session state:");
    RCTLogInfo(@"[RNAudioRecord] - Category: %@", session.category);
    RCTLogInfo(@"[RNAudioRecord] - Mode: %@", session.mode);
    RCTLogInfo(@"[RNAudioRecord] - Is other audio playing: %d", session.isOtherAudioPlaying);

    // Reset session if needed with enhanced settings
    if (![session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        RCTLogInfo(@"[RNAudioRecord] Resetting session category to PlayAndRecord");

        if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                        mode:AVAudioSessionModeDefault
                        options:AVAudioSessionCategoryOptionDefaultToSpeaker |
                                AVAudioSessionCategoryOptionAllowBluetooth |
                                AVAudioSessionCategoryOptionMixWithOthers
                        error:&error]) {
            RCTLogInfo(@"[RNAudioRecord] Failed to reset category: %@", error);
            return;
        }

        if (![session setActive:YES error:&error]) {
            RCTLogInfo(@"[RNAudioRecord] Failed to reactivate session: %@", error);
            return;
        }
    }

    // Verify final session state
    RCTLogInfo(@"[RNAudioRecord] Final session state before recording:");
    RCTLogInfo(@"[RNAudioRecord] - Category: %@", session.category);
    RCTLogInfo(@"[RNAudioRecord] - Mode: %@", session.mode);
    RCTLogInfo(@"[RNAudioRecord] - Is other audio playing: %d", session.isOtherAudioPlaying);

    // Start recording
    BOOL started = [self.audioRecorder record];
    RCTLogInfo(@"[RNAudioRecord] Record start result: %d", started);

    if (!started) {
        RCTLogInfo(@"[RNAudioRecord] Failed to start recording");
        return;
    }

    self.isRecording = YES;

    // Start audio engine tap to capture PCM and buffer before emitting
    if (!self.audioEngine) {
        self.audioEngine = [AVAudioEngine new];
    }
    AVAudioInputNode *inputNode = self.audioEngine.inputNode;
    // Use the input node's native format to avoid format mismatch
    AVAudioFormat *inputFormat = [inputNode outputFormatForBus:0];
    RCTLogInfo(@"[RNAudioRecord] Using input format: %.1f Hz, %d channels", inputFormat.sampleRate, inputFormat.channelCount);

    // Install tap
    __weak typeof(self) weakSelf = self;
    [inputNode removeTapOnBus:0];
    [inputNode installTapOnBus:0 bufferSize:1024 format:inputFormat block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->hasListeners || !strongSelf.isRecording) return;
        // Convert Float32 PCM to Int16 LE mono (take channel 0 if multi-channel)
        AVAudioChannelCount channelCount = buffer.format.channelCount;
        AVAudioFrameCount frameLength = buffer.frameLength;
        double inputSampleRate = buffer.format.sampleRate;
        float * const *floatChannels = buffer.floatChannelData;
        if (!floatChannels || frameLength == 0) return;

        // Convert to mono first
        NSMutableData *monoData = [NSMutableData dataWithLength:frameLength * sizeof(float)];
        float *monoFloat = (float *)monoData.mutableBytes;
        float *left = floatChannels[0];
        if (channelCount == 1) {
            memcpy(monoFloat, left, frameLength * sizeof(float));
        } else {
            float *right = floatChannels[1];
            for (AVAudioFrameCount i = 0; i < frameLength; i++) {
                monoFloat[i] = 0.5f * (left[i] + right[i]);
            }
        }

        // Resample if needed
        NSMutableData *resampledData = monoData;
        if (inputSampleRate != strongSelf.configuredSampleRate) {
            resampledData = [strongSelf resampleAudioData:monoData
                                            fromSampleRate:inputSampleRate
                                            toSampleRate:strongSelf.configuredSampleRate];
        }

        // Convert to Int16
        NSUInteger resampledLength = resampledData.length / sizeof(float);
        NSMutableData *chunk = [NSMutableData dataWithLength:resampledLength * sizeof(int16_t)];
        int16_t *monoOut = (int16_t *)chunk.mutableBytes;
        float *resampledFloat = (float *)resampledData.mutableBytes;

        for (NSUInteger i = 0; i < resampledLength; i++) {
            float s = resampledFloat[i];
            if (s > 1.0f) s = 1.0f; else if (s < -1.0f) s = -1.0f;
            monoOut[i] = (int16_t)lrintf(s * 32767.0f);
        }

        @synchronized (strongSelf) {
            [strongSelf.pcmAccumulatedBuffer appendData:chunk];
            // Emit in configured chunk sizes while enough data is available
            while (strongSelf.pcmAccumulatedBuffer.length >= strongSelf.targetChunkBytes) {
                NSData *toSend = [strongSelf.pcmAccumulatedBuffer subdataWithRange:NSMakeRange(0, strongSelf.targetChunkBytes)];
                // Remove consumed bytes
                NSRange remainRange = NSMakeRange(strongSelf.targetChunkBytes, strongSelf.pcmAccumulatedBuffer.length - strongSelf.targetChunkBytes);
                NSData *remaining = remainRange.length > 0 ? [strongSelf.pcmAccumulatedBuffer subdataWithRange:remainRange] : [NSData data];
                strongSelf.pcmAccumulatedBuffer = [remaining mutableCopy];
                // Emit base64 on main queue to align with RN expectations
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (strongSelf->hasListeners && strongSelf.isRecording) {
                        [strongSelf sendEventWithName:@"data" body:[toSend base64EncodedStringWithOptions:0]];
                    }
                });
            }
        }
    }];
    if (!self.audioEngine.isRunning) {
        NSError *engErr = nil;
        [self.audioEngine prepare];
        BOOL startedEngine = [self.audioEngine startAndReturnError:&engErr];
        RCTLogInfo(@"[RNAudioRecord] AudioEngine start result: %d (%@)", startedEngine, engErr);
    }

    // Start metering timer
    dispatch_async(dispatch_get_main_queue(), ^{
        self.meteringTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                        target:self
                                        selector:@selector(updateMeters)
                                        userInfo:nil
                                        repeats:YES];
    });

    RCTLogInfo(@"[RNAudioRecord] Recording started successfully");
}

- (void)updateMeters {
    if (!self.isRecording || !hasListeners || !self.audioRecorder) return;

    [self.audioRecorder updateMeters];

    float averagePower = [self.audioRecorder averagePowerForChannel:0];
    float peakPower = [self.audioRecorder peakPowerForChannel:0];

    // Convert audio levels to linear scale (0-1)
    float normalizedAverage = powf(10.0f, 0.05f * averagePower);
    float normalizedPeak = powf(10.0f, 0.05f * peakPower);

    // Create small data packet
    NSMutableData *data = [NSMutableData dataWithLength:4];
    float values[2] = {normalizedAverage, normalizedPeak};
    [data appendBytes:values length:sizeof(values)];

    // Send metering data
    [self sendEventWithName:@"data"
            body:[data base64EncodedStringWithOptions:0]];
}

RCT_EXPORT_METHOD(stop:(RCTPromiseResolveBlock)resolve
                    rejecter:(RCTPromiseRejectBlock)reject) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.meteringTimer invalidate];
        self.meteringTimer = nil;
    });

    if (self.audioRecorder && self.audioRecorder.recording) {
        [self.audioRecorder stop];
    }

    self.isRecording = NO;

    // Stop audio engine and clear tap/buffers
    if (self.audioEngine) {
        @try {
            [self.audioEngine.inputNode removeTapOnBus:0];
        } @catch (__unused NSException *e) {}
        if (self.audioEngine.isRunning) {
            [self.audioEngine stop];
        }
    }
    @synchronized (self) {
        self.pcmAccumulatedBuffer = [NSMutableData data];
    }

    // Deactivate session
    NSError *error = nil;
    [[AVAudioSession sharedInstance] setActive:NO
                                        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                        error:&error];

    if ([[NSFileManager defaultManager] fileExistsAtPath:self.filePath]) {
        resolve(self.filePath);
    } else {
        reject(@"no_file", @"Recording file not found", nil);
    }
}

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder
                        successfully:(BOOL)flag {
    RCTLogInfo(@"[RNAudioRecord] Recording finished - Success: %d", flag);
}

- (void)audioRecorderEncodeErrorDidOccur:(AVAudioRecorder *)recorder
                                  error:(NSError *)error {
    RCTLogInfo(@"[RNAudioRecord] Encoding error: %@", error);
}

- (void)startObserving {
    hasListeners = YES;
}

- (void)stopObserving {
    hasListeners = NO;
}

- (NSArray<NSString *> *)supportedEvents {
    return @[@"data"];
}

- (NSMutableData *)resampleAudioData:(NSMutableData *)inputData
                    fromSampleRate:(double)inputRate
                    toSampleRate:(double)outputRate {
    if (inputRate == outputRate) {
        return inputData;
    }

    NSUInteger inputLength = inputData.length / sizeof(float);
    NSUInteger outputLength = (NSUInteger)(inputLength * outputRate / inputRate);

    NSMutableData *outputData = [NSMutableData dataWithLength:outputLength * sizeof(float)];
    float *inputSamples = (float *)inputData.mutableBytes;
    float *outputSamples = (float *)outputData.mutableBytes;

    double ratio = inputRate / outputRate;

    for (NSUInteger i = 0; i < outputLength; i++) {
        double inputIndex = i * ratio;
        NSUInteger index = (NSUInteger)inputIndex;
        double fraction = inputIndex - index;

        if (index >= inputLength - 1) {
            outputSamples[i] = inputSamples[inputLength - 1];
        } else {
            float s0 = inputSamples[index];
            float s1 = inputSamples[index + 1];
            outputSamples[i] = s0 + (s1 - s0) * fraction;
        }
    }

    return outputData;
}

@end
