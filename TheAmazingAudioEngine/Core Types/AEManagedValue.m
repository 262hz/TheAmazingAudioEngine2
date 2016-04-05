//
//  AEManagedValue.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 30/03/2016.
//  Copyright © 2016 A Tasty Pixel. All rights reserved.
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//     claim that you wrote the original software. If you use this software
//     in a product, an acknowledgment in the product documentation would be
//     appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//     misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
//

#import "AEManagedValue.h"
#import <libkern/OSAtomic.h>
#import <pthread.h>

typedef struct __linkedlistitem_t {
    void * data;
    struct __linkedlistitem_t * next;
} linkedlistitem_t;

static int __atomicUpdateCounter = 0;
static pthread_mutex_t __atomicUpdateMutex = PTHREAD_MUTEX_INITIALIZER;
static NSMutableSet * __atomicUpdatedValues = nil;

@interface AEManagedValue () {
    void *      _value;
    BOOL        _valueSet;
    void *      _atomicBatchUpdateLastValue;
    BOOL        _isObjectValue;
    OSQueueHead _pendingReleaseQueue;
    int         _pendingReleaseCount;
    OSQueueHead _releaseQueue;
}
@property (nonatomic, strong) NSTimer * pollTimer;
@end

@interface AEManagedValueProxy : NSProxy
@property (nonatomic, weak) AEManagedValue * target;
@end

@implementation AEManagedValue
@dynamic objectValue, pointerValue;

+ (void)performAtomicBatchUpdate:(void(^)())block {
    if ( __atomicUpdateCounter == 0 ) {
        __atomicUpdatedValues = [NSMutableSet set];
        
        pthread_mutex_lock(&__atomicUpdateMutex);
    }
    
    __atomicUpdateCounter++;
    
    block();
    
    __atomicUpdateCounter--;
    
    if ( __atomicUpdateCounter == 0 ) {
        pthread_mutex_unlock(&__atomicUpdateMutex);
        
        // Complete the update by telling the updated values the atomic operation has ended
        for ( AEManagedValue * value in __atomicUpdatedValues ) {
            value->_atomicBatchUpdateLastValue = value->_value;
        }
        __atomicUpdatedValues = nil;
    }
}

- (instancetype)init {
    if ( !(self = [super init]) ) return nil;
    return self;
}

- (void)dealloc {
    [self releaseOldValue:_value];
    linkedlistitem_t * release;
    while ( (release = OSAtomicDequeue(&_pendingReleaseQueue, offsetof(linkedlistitem_t, next))) ) {
        OSAtomicEnqueue(&_releaseQueue, release, offsetof(linkedlistitem_t, next));
    }
    [self pollReleaseList];
}

- (id)objectValue {
    NSAssert(!_valueSet || _isObjectValue, @"You can use objectValue or pointerValue, but not both");
    return (__bridge id)_value;
}

- (void)setObjectValue:(id)objectValue {
    NSAssert(!_valueSet || _isObjectValue, @"You can use objectValue or pointerValue, but not both");
    _isObjectValue = YES;
    [self setValue:(__bridge_retained void*)objectValue];
}

- (void *)pointerValue {
    NSAssert(!_valueSet || !_isObjectValue, @"You can use objectValue or pointerValue, but not both");
    return _value;
}

- (void)setPointerValue:(void *)pointerValue {
    NSAssert(!_valueSet || !_isObjectValue, @"You can use objectValue or pointerValue, but not both");
    [self setValue:pointerValue];
}

- (void)setValue:(void *)value {
    
    // Assign new value
    void * oldValue = _value;
    _value = value;
    _valueSet = YES;
    
    if ( __atomicUpdateCounter == 0 ) {
        // Save value for recall on realtime thread during atomic batch update
        _atomicBatchUpdateLastValue = _value;
    } else {
        // Remember that we updated during a batch update - we'll update _atomicBatchUpdateLastValue at the end of the update
        [__atomicUpdatedValues addObject:self];
    }
    
    if ( oldValue ) {
        // Mark old value as pending release - it'll be transferred to the release queue by
        // AEManagedValueGetValue on the audio thread
        linkedlistitem_t * release = (linkedlistitem_t*)calloc(1, sizeof(linkedlistitem_t));
        release->data = oldValue;
        
        OSAtomicEnqueue(&_pendingReleaseQueue, release, offsetof(linkedlistitem_t, next));
        _pendingReleaseCount++;
        
        if ( !self.pollTimer ) {
            // Start polling for pending releases
            AEManagedValueProxy * proxy = [AEManagedValueProxy alloc];
            proxy.target = self;
            self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:proxy
                                                            selector:@selector(pollReleaseList) userInfo:nil repeats:YES];
        }
    }
}

#pragma mark - Realtime thread accessor

void * AEManagedValueGetValue(__unsafe_unretained AEManagedValue * THIS) {
    if ( !THIS ) return NULL;
    
    if ( pthread_mutex_trylock(&__atomicUpdateMutex) != 0 ) {
        // Atomic update in progress - return previous value
        return THIS->_atomicBatchUpdateLastValue;
    }
    
    linkedlistitem_t * release;
    while ( (release = OSAtomicDequeue(&THIS->_pendingReleaseQueue, offsetof(linkedlistitem_t, next))) ) {
        OSAtomicEnqueue(&THIS->_releaseQueue, release, offsetof(linkedlistitem_t, next));
    }
    
    void * value = THIS->_value;
    
    pthread_mutex_unlock(&__atomicUpdateMutex);
    
    return value;
}

#pragma mark - Helpers

- (void)pollReleaseList {
    linkedlistitem_t * release;
    while ( (release = OSAtomicDequeue(&_releaseQueue, offsetof(linkedlistitem_t, next))) ) {
        [self releaseOldValue:release->data];
        free(release);
        _pendingReleaseCount--;
    }
    if ( _pendingReleaseCount == 0 ) {
        [self.pollTimer invalidate];
        self.pollTimer = nil;
    }
}

- (void)releaseOldValue:(void *)value {
    if ( _isObjectValue ) {
        CFRelease(value);
    } else if ( _releaseBlock ) {
        _releaseBlock(value);
    } else {
        free(value);
    }
}

@end

@implementation AEManagedValueProxy
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [_target methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    [invocation setTarget:_target];
    [invocation invoke];
}
@end
