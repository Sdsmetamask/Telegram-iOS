#import <MtProtoKit/MTRequestMessageService.h>

#import <MtProtoKit/MTLogging.h>
#import <MtProtoKit/MTTime.h>
#import <MtProtoKit/MTTimer.h>
#import <MtProtoKit/MTContext.h>
#import <MtProtoKit/MTSerialization.h>
#import <MtProtoKit/MTProto.h>
#import <MtProtoKit/MTQueue.h>
#import <MtProtoKit/MTMessageTransaction.h>
#import <MtProtoKit/MTIncomingMessage.h>
#import <MtProtoKit/MTOutgoingMessage.h>
#import <MtProtoKit/MTPreparedMessage.h>
#import <MtProtoKit/MTRequest.h>
#import <MtProtoKit/MTRequestContext.h>
#import <MtProtoKit/MTRequestErrorContext.h>
#import <MtProtoKit/MTDropResponseContext.h>
#import <MtProtoKit/MTApiEnvironment.h>
#import <MtProtoKit/MTDatacenterAuthInfo.h>
#import <MtProtoKit/MTSignal.h>
#import "MTBuffer.h"

#import "MTInternalMessageParser.h"
#import "MTRpcResultMessage.h"
#import <MtProtoKit/MTRpcError.h>
#import "MTDropRpcResultMessage.h"

@interface MTRequestVerificationData : NSObject

@property (nonatomic, strong, readonly) NSString *nonce;
@property (nonatomic, strong, readonly) NSString *secret;

@end

@implementation MTRequestVerificationData

- (instancetype)initWithNonce:(NSString *)nonce secret:(NSString *)secret {
    self = [super init];
    if (self != nil) {
        _nonce = nonce;
        _secret = secret;
    }
    return self;
}

@end

@interface MTRequestRecaptchaVerificationData : NSObject

@property (nonatomic, strong, readonly) NSString *token;

@end

@implementation MTRequestRecaptchaVerificationData

- (instancetype)initWithToken:(NSString *)token {
    self = [super init];
    if (self != nil) {
        _token = token;
    }
    return self;
}

@end

@interface MTRequestMessageService ()
{
    MTContext *_context;
    
    __weak MTProto *_mtProto;
    MTQueue *_queue;
    id<MTSerialization> _serialization;
    
    NSMutableArray *_requests;
    NSMutableArray *_dropReponseContexts;
    
    MTTimer *_requestsServiceTimer;
    MTTimer *_requestsTimeoutTimer;
}

@end

@implementation MTRequestMessageService

- (instancetype)initWithContext:(MTContext *)context
{
    self = [super init];
    if (self != nil)
    {
        _context = context;
        
        __weak MTRequestMessageService *weakSelf = self;
        MTContextBlockChangeListener *changeListener = [[MTContextBlockChangeListener alloc] init];
        changeListener.contextIsPasswordRequiredUpdated = ^(MTContext *context, NSInteger datacenterId)
        {
            __strong MTRequestMessageService *strongSelf = weakSelf;
            [strongSelf _contextIsPasswordRequiredUpdated:context datacenterId:datacenterId];
        };
        
        [_context addChangeListener:changeListener];
        
        _requests = [[NSMutableArray alloc] init];
        _dropReponseContexts = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc
{
    if (_requestsServiceTimer != nil)
    {
        [_requestsServiceTimer invalidate];
        _requestsServiceTimer = nil;
    }
    if (_requestsTimeoutTimer != nil) {
        [_requestsTimeoutTimer invalidate];
        _requestsTimeoutTimer = nil;
    }
}

- (void)addRequest:(MTRequest *)request
{
    [_queue dispatchOnQueue:^
    {
        MTProto *mtProto = _mtProto;
        if (mtProto == nil)
            return;
        
        if (![_requests containsObject:request])
        {
            if (MTLogEnabled()) {
                MTLog(@"[MTRequestMessageService#%" PRIxPTR " add request %@]", (intptr_t)self, request.metadata);
            }
            
            [_requests addObject:request];
            [mtProto requestTransportTransaction];
        }
    }];
}

- (void)removeRequestByInternalId:(id)internalId
{
    [self removeRequestByInternalId:internalId askForReconnectionOnDrop:false];
}

- (void)removeRequestByInternalId:(id)internalId askForReconnectionOnDrop:(bool)askForReconnectionOnDrop
{
    [_queue dispatchOnQueue:^
    {
        bool anyNewDropRequests = false;
        bool removedAnyRequest = false;
        bool mergedAskForReconnectionOnDrop = askForReconnectionOnDrop;
        
        int index = -1;
        for (MTRequest *request in _requests)
        {
            index++;
            
            if ([request.internalId isEqual:internalId])
            {
                if (request.requestContext != nil)
                {
                    //[_dropReponseContexts addObject:[[MTDropResponseContext alloc] initWithDropMessageId:request.requestContext.messageId]];
                    anyNewDropRequests = true;
                    if (request.expectedResponseSize >= 512 * 1024) {
                        mergedAskForReconnectionOnDrop = true;
                    }
                }
                
                if (request.requestContext.messageId != 0) {
                    if (MTLogEnabled()) {
                        MTLog(@"[MTRequestMessageService#%" PRIxPTR " drop %" PRId64 "]", (intptr_t)self, request.requestContext.messageId);
                    }
                }
                
                request.requestContext = nil;
                [_requests removeObjectAtIndex:(NSUInteger)index];
                removedAnyRequest = true;
                
                break;
            }
        }
        
        if (anyNewDropRequests)
        {
            MTProto *mtProto = _mtProto;
            
            if (mergedAskForReconnectionOnDrop) {
                [mtProto resetSessionInfo:true];
            }

            [mtProto requestTransportTransaction];
        }
        
        if (removedAnyRequest && _requests.count == 0)
        {
            id<MTRequestMessageServiceDelegate> delegate = _delegate;
            if ([delegate respondsToSelector:@selector(requestMessageServiceDidCompleteAllRequests:)])
                [delegate requestMessageServiceDidCompleteAllRequests:self];
        }
        
        [self updateRequestsTimer];
        [self updateRequestsTimeoutTimerWithReset:false];
    }];
}

- (void)requestCount:(void (^)(NSUInteger requestCount))completion
{
    if (completion == nil)
        return;
    
    if (_queue == nil)
        completion(0);
    else
    {
        [_queue dispatchOnQueue:^
        {
            completion(_requests.count);
        }];
    }
}

- (void)_contextIsPasswordRequiredUpdated:(MTContext *)context datacenterId:(NSInteger)datacenterId
{
    [_queue dispatchOnQueue:^
    {
        if ([context isPasswordInputRequiredForDatacenterWithId:datacenterId])
            return;
        
        if (context != _context)
            return;
        
        MTProto *mtProto = _mtProto;
        if (datacenterId == mtProto.datacenterId)
            [mtProto requestTransportTransaction];
    }];
}

- (void)updateRequestsTimer
{
    [_queue dispatchOnQueue:^
    {
        CFAbsoluteTime currentTime = MTAbsoluteSystemTime();
        
        CFAbsoluteTime minWaitTime = DBL_MAX;
        bool needTimer = false;
        bool needTransaction = false;
        
        for (MTRequest *request in _requests)
        {
            if (request.errorContext != nil)
            {
                if (request.errorContext.waitingForRequestToComplete != nil) {
                    bool foundDependency = false;
                    for (MTRequest *anotherRequest in _requests) {
                        if (request.errorContext.waitingForRequestToComplete == anotherRequest.internalId) {
                            foundDependency = true;
                            break;
                        }
                    }

                    if (!foundDependency) {
                        needTransaction = true;
                    }
                }

                if (request.requestContext == nil)
                {
                    if (request.errorContext.minimalExecuteTime > currentTime + DBL_EPSILON)
                    {
                        needTimer = true;
                        minWaitTime = MIN(minWaitTime, request.errorContext.minimalExecuteTime - currentTime);
                    }
                    else
                    {
                        request.errorContext.minimalExecuteTime = 0.0;
                        needTransaction = true;
                    }
                }
            }
        }
        
        if (needTimer)
        {
            if (_requestsServiceTimer == nil)
            {
                __weak MTRequestMessageService *weakSelf = self;
                _requestsServiceTimer = [[MTTimer alloc] initWithTimeout:minWaitTime repeat:false completion:^
                {
                    __strong MTRequestMessageService *strongSelf = weakSelf;
                    [strongSelf requestTimerEvent];
                } queue:_queue.nativeQueue];
                [_requestsServiceTimer start];
            }
            else
                [_requestsServiceTimer resetTimeout:minWaitTime];
        }
        else if (!needTimer && _requestsServiceTimer != nil)
        {
            [_requestsServiceTimer invalidate];
            _requestsServiceTimer = nil;
        }
        
        if (needTransaction)
        {
            MTProto *mtProto = _mtProto;
            [mtProto requestTransportTransaction];
        }
    }];
}

- (void)requestTimerEvent
{
    if (_requestsServiceTimer != nil)
    {
        [_requestsServiceTimer invalidate];
        _requestsServiceTimer = nil;
    }
    
    MTProto *mtProto = _mtProto;
    [mtProto requestTransportTransaction];
}

- (void)updateRequestsTimeoutTimerWithReset:(bool)reset {
    CFAbsoluteTime currentTime = MTAbsoluteSystemTime();
    
    bool needTimer = false;
    
    for (MTRequest *request in _requests) {
        if (!request.needsTimeoutTimer) {
            continue;
        }
        if (request.errorContext != nil) {
            if (request.errorContext.waitingForRequestToComplete != nil) {
                bool foundDependency = false;
                for (MTRequest *anotherRequest in _requests) {
                    if (request.errorContext.waitingForRequestToComplete == anotherRequest.internalId) {
                        foundDependency = true;
                        break;
                    }
                }
                
                if (!foundDependency) {
                    needTimer = true;
                }
            }
            
            if (request.requestContext == nil) {
                if (request.errorContext.minimalExecuteTime > currentTime + DBL_EPSILON) {
                } else {
                    request.errorContext.minimalExecuteTime = 0.0;
                    needTimer = true;
                }
            }
        } else {
            needTimer = true;
        }
    }
    
    if (needTimer) {
        if (reset) {
            if (_requestsTimeoutTimer != nil) {
                [_requestsTimeoutTimer invalidate];
                _requestsTimeoutTimer = nil;
            }
        }
        
        if (_requestsTimeoutTimer == nil) {
            __weak MTRequestMessageService *weakSelf = self;
            _requestsTimeoutTimer = [[MTTimer alloc] initWithTimeout:5.0 repeat:false completion:^
            {
                __strong MTRequestMessageService *strongSelf = weakSelf;
                [strongSelf requestTimerTimeoutEvent];
            } queue:_queue.nativeQueue];
            [_requestsTimeoutTimer start];
        }
    } else {
        if (_requestsTimeoutTimer != nil) {
            [_requestsTimeoutTimer invalidate];
            _requestsTimeoutTimer = nil;
        }
    }
}

- (void)requestTimerTimeoutEvent {
    MTProto *mtProto = _mtProto;
    if (mtProto) {
        [mtProto requestSecureTransportReset];
        [mtProto requestTransportTransaction];
    }
}

- (void)mtProtoWillAddService:(MTProto *)mtProto
{
    _queue = [mtProto messageServiceQueue];
}

- (void)mtProtoDidAddService:(MTProto *)mtProto
{
    _mtProto = mtProto;
    _serialization = mtProto.context.serialization;
    _apiEnvironment = mtProto.apiEnvironment;
}
    
- (void)mtProtoApiEnvironmentUpdated:(MTProto *)mtProto apiEnvironment:(MTApiEnvironment *)apiEnvironment {
    bool updateApiInitialization = ![_apiEnvironment.apiInitializationHash isEqualToString:apiEnvironment.apiInitializationHash];
    
    _apiEnvironment = apiEnvironment;
    
    if (updateApiInitialization) {
        MTRequest *request = [[MTRequest alloc] init];
        __autoreleasing NSData *noopData = nil;
        MTRequestNoopParser responseParser = [[_context serialization] requestNoop:&noopData];
        [request setPayload:noopData metadata:@"noop" shortMetadata:@"noop" responseParser:responseParser];
        
        [request setCompleted:^(__unused id result, __unused MTRequestResponseInfo *info, __unused id error) {
        }];
        
        [self addRequest:request];
    }
}

- (NSData *)decorateRequestData:(MTRequest *)request initializeApi:(bool)initializeApi requestVerificationData:(MTRequestVerificationData *)requestVerificationData recaptchaVerificationData:(MTRequestRecaptchaVerificationData *)recaptchaVerificationData unresolvedDependencyOnRequestInternalId:(__autoreleasing id *)unresolvedDependencyOnRequestInternalId decoratedDebugDescription:(__autoreleasing NSString **)decoratedDebugDescription
{
    NSData *currentData = request.payload;
    
    NSString *debugDescription = @"";
    
    if (initializeApi && _apiEnvironment != nil)
    {
        if (MTLogEnabled()) {
            MTLog(@"apiEnvironment: %@", [_apiEnvironment apiInitializationHash]);
        }
        MTBuffer *buffer = [[MTBuffer alloc] init];
        
        // invokeWithLayer
        [buffer appendInt32:(int32_t)0xda9b0d0d];
        [buffer appendInt32:(int32_t)[_serialization currentLayer]];

        int32_t flags = 0;
        if (_apiEnvironment.socksProxySettings.secret != nil) {
            flags |= (1 << 0);
        }
        if (_apiEnvironment.systemCode != nil) {
            flags |= (1 << 1);
        }
        
        [buffer appendInt32:(int32_t)0xc1cd5ea9];
        [buffer appendInt32:flags];
        [buffer appendInt32:(int32_t)_apiEnvironment.apiId];
        [buffer appendTLString:_apiEnvironment.deviceModel];
        [buffer appendTLString:_apiEnvironment.systemVersion];
        [buffer appendTLString:_apiEnvironment.appVersion];
        [buffer appendTLString:_apiEnvironment.systemLangCode];
        
        [buffer appendTLString:_apiEnvironment.langPack];
        [buffer appendTLString:_apiEnvironment.langPackCode];
        
        if (_apiEnvironment.socksProxySettings.secret != nil) {
            [buffer appendInt32:(int32_t)0x75588b3f];
            [buffer appendTLString:_apiEnvironment.socksProxySettings.ip];
            [buffer appendInt32:_apiEnvironment.socksProxySettings.port];
        }
        
        if (_apiEnvironment.systemCode != nil) {
            [buffer appendBytes:_apiEnvironment.systemCode.bytes length:_apiEnvironment.systemCode.length];
        }
        
        [buffer appendBytes:currentData.bytes length:currentData.length];
        currentData = buffer.data;
    }
    
    if ((_apiEnvironment != nil && _apiEnvironment.disableUpdates) || _forceBackgroundRequests)
    {
        MTBuffer *buffer = [[MTBuffer alloc] init];
        
        [buffer appendInt32:(int32_t)0xbf9459b7];

        [buffer appendBytes:currentData.bytes length:currentData.length];
        currentData = buffer.data;
        
        debugDescription = [debugDescription stringByAppendingString:@", disableUpdates"];
    }
    
    if (request.shouldDependOnRequest != nil)
    {
        NSUInteger index = [_requests indexOfObject:request];
        if (index != NSNotFound)
        {
            for (MTRequest *anotherRequest in _requests.reverseObjectEnumerator)
            {
                if (request == anotherRequest) {
                    continue;
                }
                
                if (request.shouldDependOnRequest(anotherRequest))
                {
                    if (anotherRequest.requestContext != nil)
                    {
                        MTBuffer *buffer = [[MTBuffer alloc] init];
                        
                        // invokeAfterMsg
                        [buffer appendInt32:(int32_t)0xcb9f372d];
                        [buffer appendInt64:anotherRequest.requestContext.messageId];
                        [buffer appendBytes:currentData.bytes length:currentData.length];
                        
                        currentData = buffer.data;
                        
                        debugDescription = [debugDescription stringByAppendingFormat:@", invokeAfter(%lld)", anotherRequest.requestContext.messageId];
                    }
                    else if (unresolvedDependencyOnRequestInternalId != nil) {
                        *unresolvedDependencyOnRequestInternalId = anotherRequest.internalId;
                        debugDescription = [debugDescription stringByAppendingString:@", unresolvedDependency"];
                    }
                    
                    break;
                }
            }
        }
    }
    
    if (requestVerificationData != nil) {
        MTBuffer *buffer = [[MTBuffer alloc] init];
        
        [buffer appendInt32:(int32_t)0xdae54f8];
        [buffer appendTLString:requestVerificationData.nonce];
        [buffer appendTLString:requestVerificationData.secret];

        [buffer appendBytes:currentData.bytes length:currentData.length];
        currentData = buffer.data;
        
        debugDescription = [debugDescription stringByAppendingFormat:@", apnsSecret(%@, %@)", requestVerificationData.nonce, requestVerificationData.secret];
    }
    
    if (recaptchaVerificationData != nil) {
        MTBuffer *buffer = [[MTBuffer alloc] init];
        
        [buffer appendInt32:(int32_t)0xadbb0f94];
        [buffer appendTLString:recaptchaVerificationData.token];

        [buffer appendBytes:currentData.bytes length:currentData.length];
        currentData = buffer.data;
        
        debugDescription = [debugDescription stringByAppendingFormat:@", recaptcha(%@)", recaptchaVerificationData.token];
    }
    
    if (decoratedDebugDescription != nil) {
        *decoratedDebugDescription = debugDescription;
    }
    
    return currentData;
}

- (MTMessageTransaction *)mtProtoMessageTransaction:(MTProto *)mtProto authInfoSelector:(MTDatacenterAuthInfoSelector)authInfoSelector sessionInfo:(MTSessionInfo *)sessionInfo scheme:(MTTransportScheme *)scheme
{
    NSMutableArray *messages = nil;
    NSMutableDictionary *requestInternalIdToMessageInternalId = nil;
    
    bool requestsWillInitializeApi = _apiEnvironment != nil && ![_apiEnvironment.apiInitializationHash isEqualToString:[_context authInfoForDatacenterWithId:mtProto.datacenterId selector:authInfoSelector].authKeyAttributes[@"apiInitializationHash"]];
    
    CFAbsoluteTime currentTime = MTAbsoluteSystemTime();
    
    for (MTRequest *request in _requests)
    {
        if (request.dependsOnPasswordEntry && [_context isPasswordInputRequiredForDatacenterWithId:mtProto.datacenterId])
            continue;
        
        if (request.errorContext != nil)
        {
            if (request.errorContext.minimalExecuteTime > currentTime) {
                continue;
            }
            if (request.errorContext.waitingForTokenExport) {
                continue;
            }
            if (request.errorContext.pendingVerificationData != nil) {
                if (!request.errorContext.pendingVerificationData.isResolved) {
                    continue;
                }
            }
            if (request.errorContext.pendingRecaptchaVerificationData != nil) {
                if (!request.errorContext.pendingRecaptchaVerificationData.isResolved) {
                    continue;
                }
            }

            bool foundDependency = false;
            for (MTRequest *anotherRequest in _requests) {
                if (request.errorContext.waitingForRequestToComplete == anotherRequest.internalId) {
                    foundDependency = true;
                    break;
                }
            }
            if (foundDependency) {
                continue;
            }
        }
        
        if (request.requestContext == nil || (!request.requestContext.waitingForMessageId && !request.requestContext.delivered && request.requestContext.transactionId == nil))
        {   
            if (messages == nil)
                messages = [[NSMutableArray alloc] init];
            if (requestInternalIdToMessageInternalId == nil)
                requestInternalIdToMessageInternalId = [[NSMutableDictionary alloc] init];
            
            __autoreleasing id autoreleasingUnresolvedDependencyOnRequestInternalId = nil;
            __autoreleasing NSString *decoratedDebugDescription = nil;
            
            int64_t messageId = 0;
            int32_t messageSeqNo = 0;
            if (request.requestContext != nil)
            {
                messageId = request.requestContext.messageId;
                messageSeqNo = request.requestContext.messageSeqNo;
            }
            
            MTRequestVerificationData *requestVerificationData = nil;
            if (request.errorContext != nil) {
                if (request.errorContext.pendingVerificationData != nil) {
                    if (request.errorContext.pendingVerificationData.isResolved) {
                        requestVerificationData = [[MTRequestVerificationData alloc] initWithNonce:request.errorContext.pendingVerificationData.nonce secret:request.errorContext.pendingVerificationData.secret];
                    }
                }
            }
            
            MTRequestRecaptchaVerificationData *recaptchaVerificationData = nil;
            if (request.errorContext != nil) {
                if (request.errorContext.pendingRecaptchaVerificationData != nil) {
                    if (request.errorContext.pendingRecaptchaVerificationData.isResolved) {
                        recaptchaVerificationData = [[MTRequestRecaptchaVerificationData alloc] initWithToken:request.errorContext.pendingRecaptchaVerificationData.token];
                    }
                }
            }
            
            NSData *decoratedRequestData = [self decorateRequestData:request initializeApi:requestsWillInitializeApi requestVerificationData:requestVerificationData recaptchaVerificationData:recaptchaVerificationData unresolvedDependencyOnRequestInternalId:&autoreleasingUnresolvedDependencyOnRequestInternalId decoratedDebugDescription:&decoratedDebugDescription];
            
            MTOutgoingMessage *outgoingMessage = [[MTOutgoingMessage alloc] initWithData:decoratedRequestData metadata:request.metadata additionalDebugDescription:decoratedDebugDescription shortMetadata:request.shortMetadata messageId:messageId messageSeqNo:messageSeqNo];
            outgoingMessage.needsQuickAck = request.acknowledgementReceived != nil;
            outgoingMessage.hasHighPriority = request.hasHighPriority;
            
            id unresolvedDependencyOnRequestInternalId = autoreleasingUnresolvedDependencyOnRequestInternalId;
            if (unresolvedDependencyOnRequestInternalId != nil)
            {
                outgoingMessage.dynamicDecorator = ^id (int64_t currentMessageId, NSData *currentData, NSDictionary *messageInternalIdToPreparedMessage)
                {
                    id messageInternalId = requestInternalIdToMessageInternalId[unresolvedDependencyOnRequestInternalId];
                    if (messageInternalId != nil)
                    {
                        MTPreparedMessage *preparedMessage = messageInternalIdToPreparedMessage[messageInternalId];
                        if (preparedMessage != nil)
                        {
                            MTBuffer *invokeAfterBuffer = [[MTBuffer alloc] init];
                            [invokeAfterBuffer appendInt32:(int32_t)0xcb9f372d];
                            [invokeAfterBuffer appendInt64:preparedMessage.messageId];
                            [invokeAfterBuffer appendBytes:currentData.bytes length:currentData.length];
                            if (MTLogEnabled()) {
                                MTLog(@"[MTRequestMessageService] %lld dynamically added invokeAfter %lld", currentMessageId, preparedMessage.messageId);
                            }
                            return invokeAfterBuffer.data;
                        }
                    }
                    
                    return currentData;
                };
            }
            
            requestInternalIdToMessageInternalId[request.internalId] = outgoingMessage.internalId;
            [messages addObject:outgoingMessage];
        }
    }
    
    NSMutableDictionary *dropMessageIdToMessageInternalId = nil;
    for (MTDropResponseContext *dropContext in _dropReponseContexts)
    {
        if (messages == nil)
            messages = [[NSMutableArray alloc] init];
        if (dropMessageIdToMessageInternalId == nil)
            dropMessageIdToMessageInternalId = [[NSMutableDictionary alloc] init];
        
        MTBuffer *dropAnswerBuffer = [[MTBuffer alloc] init];
        [dropAnswerBuffer appendInt32:(int32_t)0x58e4a740];
        [dropAnswerBuffer appendInt64:dropContext.dropMessageId];
        
        NSString *messageDecription = [NSString stringWithFormat:@"dropAnswer for %" PRId64, dropContext.dropMessageId];
        MTOutgoingMessage *outgoingMessage = [[MTOutgoingMessage alloc] initWithData:dropAnswerBuffer.data metadata:messageDecription additionalDebugDescription:nil shortMetadata:messageDecription messageId:dropContext.messageId messageSeqNo:dropContext.messageSeqNo];
        outgoingMessage.requiresConfirmation = false;
        dropMessageIdToMessageInternalId[@(dropContext.dropMessageId)] = outgoingMessage.internalId;
        [messages addObject:outgoingMessage];
    }
    
    if (messages.count != 0)
    {
        NSMutableDictionary *requestInternalIdToTransactionResetStateVersion = [[NSMutableDictionary alloc] init];
        for (MTRequest *request in _requests) {
            requestInternalIdToTransactionResetStateVersion[request.internalId] = @(request.transactionResetStateVersion);
        }
        return [[MTMessageTransaction alloc] initWithMessagePayload:messages prepared:^(NSDictionary *messageInternalIdToPreparedMessage) {
            for (MTRequest *request in _requests) {
                id messageInternalId = requestInternalIdToMessageInternalId[request.internalId];
                if (messageInternalId != nil) {
                    MTPreparedMessage *preparedMessage = messageInternalIdToPreparedMessage[messageInternalId];
                    if (preparedMessage != nil) {
                        NSNumber *nTransactionResetStateVersion = requestInternalIdToTransactionResetStateVersion[request.internalId];
                        if (nTransactionResetStateVersion != nil && [nTransactionResetStateVersion intValue] != request.transactionResetStateVersion) {
                            if (MTLogEnabled()) {
                                MTLog(@"[MTRequestMessageService#%p request %" PRId64 " skipped in transaction: transactionResetStateVersion %d != %d]", self, preparedMessage.messageId, [nTransactionResetStateVersion intValue], request.transactionResetStateVersion);
                            }
                            continue;
                        }
                        
                        MTRequestContext *requestContext = [[MTRequestContext alloc] initWithMessageId:preparedMessage.messageId messageSeqNo:preparedMessage.seqNo transactionId:nil quickAckId:0];
                        requestContext.sentTimestamp = CFAbsoluteTimeGetCurrent();
                        requestContext.willInitializeApi = requestsWillInitializeApi;
                        requestContext.waitingForMessageId = true;
                        request.requestContext = requestContext;
                    }
                }
            }
        } failed:^{
            for (MTRequest *request in _requests) {
                id messageInternalId = requestInternalIdToMessageInternalId[request.internalId];
                if (messageInternalId != nil) {
                    request.requestContext.waitingForMessageId = false;
                }
            }
        } completion:^(NSDictionary *messageInternalIdToTransactionId, NSDictionary *messageInternalIdToPreparedMessage, NSDictionary *messageInternalIdToQuickAckId)
        {
            for (MTRequest *request in _requests)
            {
                id messageInternalId = requestInternalIdToMessageInternalId[request.internalId];
                if (messageInternalId != nil)
                {
                    request.requestContext.waitingForMessageId = false;
                    MTPreparedMessage *preparedMessage = messageInternalIdToPreparedMessage[messageInternalId];
                    if (preparedMessage != nil && messageInternalIdToTransactionId[messageInternalId] != nil)
                    {
                        NSNumber *nTransactionResetStateVersion = requestInternalIdToTransactionResetStateVersion[request.internalId];
                        if (nTransactionResetStateVersion != nil && [nTransactionResetStateVersion intValue] != request.transactionResetStateVersion) {
                            if (MTLogEnabled()) {
                                MTLog(@"[MTRequestMessageService#%p request %" PRId64 " skipped in transaction: transactionResetStateVersion %d != %d]", self, preparedMessage.messageId, [nTransactionResetStateVersion intValue], request.transactionResetStateVersion);
                            }
                            continue;
                        }
                        MTRequestContext *requestContext = [[MTRequestContext alloc] initWithMessageId:preparedMessage.messageId messageSeqNo:preparedMessage.seqNo transactionId:messageInternalIdToTransactionId[messageInternalId] quickAckId:(int32_t)[messageInternalIdToQuickAckId[messageInternalId] intValue]];
                        requestContext.sentTimestamp = CFAbsoluteTimeGetCurrent();
                        requestContext.willInitializeApi = requestsWillInitializeApi;
                        request.requestContext = requestContext;
                    }
                }
            }
            
            for (MTDropResponseContext *dropContext in _dropReponseContexts)
            {
                MTPreparedMessage *preparedMessage = messageInternalIdToPreparedMessage[dropMessageIdToMessageInternalId[@(dropContext.dropMessageId)]];
                if (preparedMessage != nil)
                {
                    dropContext.messageId = preparedMessage.messageId;
                    dropContext.messageSeqNo = preparedMessage.seqNo;
                }
            }
        }];
    }
    
    return nil;
}

- (void)mtProto:(MTProto *)__unused mtProto receivedMessage:(MTIncomingMessage *)message authInfoSelector:(MTDatacenterAuthInfoSelector)authInfoSelector networkType:(int32_t)networkType
{
    if ([message.body isKindOfClass:[MTRpcResultMessage class]])
    {
        MTRpcResultMessage *rpcResultMessage = message.body;
        
        id maybeInternalMessage = [MTInternalMessageParser parseMessage:rpcResultMessage.data];
        
        if ([maybeInternalMessage isKindOfClass:[MTDropRpcResultMessage class]])
        {
            NSInteger index = -1;
            for (MTDropResponseContext *dropContext in _dropReponseContexts)
            {
                index++;
                if (dropContext.messageId == rpcResultMessage.requestMessageId)
                {
                    [_dropReponseContexts removeObjectAtIndex:(NSUInteger)index];
                    break;
                }
            }
        }
        else
        {
            bool requestFound = false;
            
            NSMutableArray<MTRequest *> *removeRequests = [[NSMutableArray alloc] init];
            for (MTRequest *request in _requests) {
                if (request.requestContext != nil && request.requestContext.messageId == rpcResultMessage.requestMessageId) {
                    requestFound = true;
                    
                    bool restartRequest = false;
                    
                    id rpcResult = nil;
                    MTRpcError *rpcError = nil;
                    
                    if ([maybeInternalMessage isKindOfClass:[MTRpcError class]])
                        rpcError = maybeInternalMessage;
                    else
                    {
                        NSData *unwrappedData = [MTInternalMessageParser unwrapMessage:rpcResultMessage.data];
                        rpcResult = request.responseParser(unwrappedData);
                        if (rpcResult == nil)
                        {
                            rpcError = [[MTRpcError alloc] initWithErrorCode:500 errorDescription:@"TL_PARSING_ERROR"];
                            [_context performBatchUpdates:^{
                                MTDatacenterAuthInfo *authInfo = [_context authInfoForDatacenterWithId:mtProto.datacenterId selector:authInfoSelector];
                                
                                NSMutableDictionary *authKeyAttributes = [[NSMutableDictionary alloc] initWithDictionary:authInfo.authKeyAttributes];
                                authKeyAttributes[@"apiInitializationHash"] = @"";
                                
                                authInfo = [authInfo withUpdatedAuthKeyAttributes:authKeyAttributes];
                                [_context updateAuthInfoForDatacenterWithId:mtProto.datacenterId authInfo:authInfo selector:authInfoSelector];
                            }];
                        }
                    }
                    
                    if (rpcResult != nil) {
                        if (MTLogEnabled()) {
                            MTLog(@"[MTRequestMessageService#%p response for %" PRId64 " is %@]", self, request.requestContext.messageId, rpcResult);
                        }
                    } else {
                        if (MTLogEnabled()) {
                            MTLog(@"[MTRequestMessageService#%p response for %" PRId64 " is error: %d: %@]", self, request.requestContext.messageId, (int)rpcError.errorCode, rpcError.errorDescription);
                        }
                    }
                    
                    if (rpcResult != nil && request.requestContext.willInitializeApi) {
                        MTDatacenterAuthInfo *authInfo = [_context authInfoForDatacenterWithId:mtProto.datacenterId selector:authInfoSelector];
                        
                        if (![_apiEnvironment.apiInitializationHash isEqualToString:authInfo.authKeyAttributes[@"apiInitializationHash"]]) {
                            NSMutableDictionary *authKeyAttributes = [[NSMutableDictionary alloc] initWithDictionary:authInfo.authKeyAttributes];
                            authKeyAttributes[@"apiInitializationHash"] = _apiEnvironment.apiInitializationHash;
                            
                            authInfo = [authInfo withUpdatedAuthKeyAttributes:authKeyAttributes];
                            [_context updateAuthInfoForDatacenterWithId:mtProto.datacenterId authInfo:authInfo selector:authInfoSelector];
                        }
                    }
                    
                    if (rpcError != nil) {
                        if (rpcError.errorCode == 401) {
                            if ([rpcError.errorDescription rangeOfString:@"SESSION_PASSWORD_NEEDED"].location != NSNotFound) {
                                if (!request.passthroughPasswordEntryError)
                                {
                                    [_context updatePasswordInputRequiredForDatacenterWithId:mtProto.datacenterId required:true];
                                }
                            } else {
                                id<MTRequestMessageServiceDelegate> delegate = _delegate;
                                if ([delegate respondsToSelector:@selector(requestMessageServiceAuthorizationRequired:)])
                                {
                                    [delegate requestMessageServiceAuthorizationRequired:self];
                                }
                                
                                MTProto *mtProto = _mtProto;
                                if (mtProto.requiredAuthToken != nil && ([rpcError.errorDescription rangeOfString:@"SESSION_REVOKED"].location != NSNotFound || [rpcError.errorDescription rangeOfString:@"AUTH_KEY_UNREGISTERED"].location != NSNotFound))
                                {
                                    if (request.errorContext == nil)
                                        request.errorContext = [[MTRequestErrorContext alloc] init];
                                    request.errorContext.waitingForTokenExport = true;
                                    
                                    restartRequest = true;
                                }
                            }
                        } else if (rpcError.errorCode == -500 || rpcError.errorCode == 500) {
                            if (request.errorContext == nil)
                                request.errorContext = [[MTRequestErrorContext alloc] init];
                            request.errorContext.internalServerErrorCount++;
                            
                            if (request.shouldContinueExecutionWithErrorContext != nil && request.shouldContinueExecutionWithErrorContext(request.errorContext)) {
                                restartRequest = true;
                                request.errorContext.minimalExecuteTime = MAX(request.errorContext.minimalExecuteTime, MTAbsoluteSystemTime() + 2.0);
                            }
                        }
                        else if (
                            (
                                rpcError.errorCode == 400 &&
                                [rpcError.errorDescription isEqualToString:@"MSG_WAIT_TIMEOUT"]
                            ) ||
                            (
                                rpcError.errorCode == 500 &&
                                [rpcError.errorDescription isEqualToString:@"MSG_WAIT_FAILED"]
                            )
                        ) {
                            if (request.errorContext == nil) {
                                request.errorContext = [[MTRequestErrorContext alloc] init];
                            }

                            for (MTRequest *anotherRequest in _requests) {
                                if (request.shouldDependOnRequest != nil && request.shouldDependOnRequest(anotherRequest)) {
                                    request.errorContext.waitingForRequestToComplete = anotherRequest.internalId;
                                    break;
                                }
                            }
                            restartRequest = true;
                        }
                        else if ((rpcError.errorCode == 420 && [rpcError.errorDescription rangeOfString:@"FROZEN_METHOD_INVALID"].location == NSNotFound) || [rpcError.errorDescription rangeOfString:@"FLOOD_WAIT_"].location != NSNotFound || [rpcError.errorDescription rangeOfString:@"FLOOD_PREMIUM_WAIT_"].location != NSNotFound) {
                            if (request.errorContext == nil)
                                request.errorContext = [[MTRequestErrorContext alloc] init];
                            
                            if ([rpcError.errorDescription rangeOfString:@"FLOOD_WAIT_"].location != NSNotFound) {
                                int errorWaitTime = 0;
                                
                                NSScanner *scanner = [[NSScanner alloc] initWithString:rpcError.errorDescription];
                                [scanner scanUpToString:@"FLOOD_WAIT_" intoString:nil];
                                [scanner scanString:@"FLOOD_WAIT_" intoString:nil];
                                if ([scanner scanInt:&errorWaitTime])
                                {
                                    request.errorContext.floodWaitSeconds = errorWaitTime;
                                    request.errorContext.floodWaitErrorText = rpcError.errorDescription;
                                    
                                    if (request.shouldContinueExecutionWithErrorContext != nil)
                                    {
                                        if (request.shouldContinueExecutionWithErrorContext(request.errorContext))
                                        {
                                            restartRequest = true;
                                            request.errorContext.minimalExecuteTime = MAX(request.errorContext.minimalExecuteTime, MTAbsoluteSystemTime() + (CFAbsoluteTime)errorWaitTime);
                                        }
                                    }
                                    else
                                    {
                                        restartRequest = true;
                                        request.errorContext.minimalExecuteTime = MAX(request.errorContext.minimalExecuteTime, MTAbsoluteSystemTime() + (CFAbsoluteTime)errorWaitTime);
                                    }
                                }
                            } else if ([rpcError.errorDescription rangeOfString:@"FLOOD_PREMIUM_WAIT_"].location != NSNotFound) {
                                int errorWaitTime = 0;
                                
                                NSScanner *scanner = [[NSScanner alloc] initWithString:rpcError.errorDescription];
                                [scanner scanUpToString:@"FLOOD_PREMIUM_WAIT_" intoString:nil];
                                [scanner scanString:@"FLOOD_PREMIUM_WAIT_" intoString:nil];
                                if ([scanner scanInt:&errorWaitTime])
                                {
                                    request.errorContext.floodWaitSeconds = errorWaitTime;
                                    request.errorContext.floodWaitErrorText = rpcError.errorDescription;
                                    
                                    if (request.shouldContinueExecutionWithErrorContext != nil)
                                    {
                                        if (request.shouldContinueExecutionWithErrorContext(request.errorContext))
                                        {
                                            restartRequest = true;
                                            request.errorContext.minimalExecuteTime = MAX(request.errorContext.minimalExecuteTime, MTAbsoluteSystemTime() + (CFAbsoluteTime)errorWaitTime);
                                        }
                                    }
                                    else
                                    {
                                        restartRequest = true;
                                        request.errorContext.minimalExecuteTime = MAX(request.errorContext.minimalExecuteTime, MTAbsoluteSystemTime() + (CFAbsoluteTime)errorWaitTime);
                                    }
                                }
                            }
                        }
                        else if (rpcError.errorCode == 400 && [rpcError.errorDescription rangeOfString:@"CONNECTION_NOT_INITED"].location != NSNotFound) {
                            [_context performBatchUpdates:^{
                                MTDatacenterAuthInfo *authInfo = [_context authInfoForDatacenterWithId:mtProto.datacenterId selector:authInfoSelector];
                                
                                NSMutableDictionary *authKeyAttributes = [[NSMutableDictionary alloc] initWithDictionary:authInfo.authKeyAttributes];
                                [authKeyAttributes removeObjectForKey:@"apiInitializationHash"];
                                
                                authInfo = [authInfo withUpdatedAuthKeyAttributes:authKeyAttributes];
                                [_context updateAuthInfoForDatacenterWithId:mtProto.datacenterId authInfo:authInfo selector:authInfoSelector];
                            }];
                            
                            restartRequest = true;
                        } else if (rpcError.errorCode == 403 && [rpcError.errorDescription rangeOfString:@"APNS_VERIFY_CHECK_"].location != NSNotFound) {
                            if (request.errorContext == nil) {
                                request.errorContext = [[MTRequestErrorContext alloc] init];
                            }
                            
                            NSString *nonce = [rpcError.errorDescription substringFromIndex:[@"APNS_VERIFY_CHECK_" length]];
                            request.errorContext.pendingVerificationData = [[MTRequestPendingVerificationData alloc] initWithNonce:nonce];
                            
                            __weak MTRequestMessageService *weakSelf = self;
                            MTQueue *queue = _queue;
                            id requestId = request.internalId;
                            request.errorContext.pendingVerificationData.disposable = [[_context performExternalRequestVerificationWithNonce:nonce] startWithNext:^(id result) {
                                [queue dispatchOnQueue:^{
                                    __strong MTRequestMessageService *strongSelf = weakSelf;
                                    if (!strongSelf) {
                                        return;
                                    }
                                    for (MTRequest *request in strongSelf->_requests) {
                                        if (request.internalId == requestId) {
                                            request.errorContext.pendingVerificationData.secret = result;
                                            request.errorContext.pendingVerificationData.isResolved = true;
                                        }
                                    }
                                    [strongSelf->_mtProto requestTransportTransaction];
                                }];
                            }];
                            
                            restartRequest = true;
                        } else if (rpcError.errorCode == 403 && [rpcError.errorDescription rangeOfString:@"RECAPTCHA_CHECK_"].location != NSNotFound) {
                            NSString *checkData = [rpcError.errorDescription substringFromIndex:[@"RECAPTCHA_CHECK_" length]];
                            
                            NSRange separatorRange = [checkData rangeOfString:@"__"];
                            NSString *method = nil;
                            NSString *siteKey = nil;
                            if (separatorRange.location != NSNotFound) {
                                method = [checkData substringToIndex:separatorRange.location];
                                siteKey = [checkData substringFromIndex:separatorRange.location + separatorRange.length];
                            }
                            
                            if (method != nil && siteKey != nil) {
                                if (request.errorContext == nil) {
                                    request.errorContext = [[MTRequestErrorContext alloc] init];
                                }
                                
                                request.errorContext.pendingRecaptchaVerificationData = [[MTRequestPendingRecaptchaVerificationData alloc] initWithSiteKey:siteKey];
                                
                                __weak MTRequestMessageService *weakSelf = self;
                                MTQueue *queue = _queue;
                                id requestId = request.internalId;
                                request.errorContext.pendingRecaptchaVerificationData.disposable = [[_context performExternalRecaptchaRequestVerificationWithMethod:method siteKey:siteKey] startWithNext:^(id result) {
                                    [queue dispatchOnQueue:^{
                                        __strong MTRequestMessageService *strongSelf = weakSelf;
                                        if (!strongSelf) {
                                            return;
                                        }
                                        for (MTRequest *request in strongSelf->_requests) {
                                            if (request.internalId == requestId) {
                                                request.errorContext.pendingRecaptchaVerificationData.token = result;
                                                request.errorContext.pendingRecaptchaVerificationData.isResolved = true;
                                            }
                                        }
                                        [strongSelf->_mtProto requestTransportTransaction];
                                    }];
                                }];
                                
                                restartRequest = true;
                            }
                        } else if (rpcError.errorCode == 406) {
                            if (_didReceiveSoftAuthResetError) {
                                _didReceiveSoftAuthResetError();
                            }
                        }
                    }
                    
                    double sentTimestamp = request.requestContext.sentTimestamp;
                    
                    request.requestContext = nil;
                    
                    if (restartRequest) {
                    } else {
                        void (^completed)(id result, MTRequestResponseInfo *info, id error) = [request.completed copy];
                        [removeRequests addObject:request];
                        
                        if (completed) {
                            double duration = 0.0;
                            if (sentTimestamp != 0.0) {
                                duration = CFAbsoluteTimeGetCurrent() - sentTimestamp;
                            }
                            MTRequestResponseInfo *info = [[MTRequestResponseInfo alloc] initWithNetworkType:networkType timestamp:message.timestamp duration:duration];
                            completed(rpcResult, info, rpcError);
                        }
                    }
                    
                    break;
                }
            }
            
            for (MTRequest *request in removeRequests) {
                [_requests removeObject:request];
            }
            
            if (!requestFound) {
                if (MTLogEnabled()) {
                    MTLog(@"[MTRequestMessageService#%p response %" PRId64 " for % " PRId64 " didn't match any request]", self, message.messageId, rpcResultMessage.requestMessageId);
                }
            }
            else if (_requests.count == 0)
            {
                id<MTRequestMessageServiceDelegate> delegate = _delegate;
                if ([delegate respondsToSelector:@selector(requestMessageServiceDidCompleteAllRequests:)])
                    [delegate requestMessageServiceDidCompleteAllRequests:self];
            }
            
            [self updateRequestsTimer];
            [self updateRequestsTimeoutTimerWithReset:false];
        }
    }
}

- (void)mtProto:(MTProto *)__unused mtProto receivedQuickAck:(int32_t)quickAckId
{
    for (MTRequest *request in _requests)
    {
        if (request.requestContext != nil && request.requestContext.quickAckId == quickAckId)
        {
            if (request.acknowledgementReceived != nil)
                request.acknowledgementReceived();
        }
    }
}

- (void)mtProtoTransportActivityUpdated:(MTProto *) __unused mtProto {
    [self updateRequestsTimeoutTimerWithReset:true];
}

- (void)mtProto:(MTProto *)__unused mtProto messageDeliveryConfirmed:(NSArray *)messageIds
{
    for (NSNumber *nMessageId in messageIds)
    {
        int64_t messageId = (int64_t)[nMessageId longLongValue];
        
        for (MTRequest *request in _requests)
        {
            if (request.requestContext != nil && request.requestContext.messageId == messageId)
            {
                request.requestContext.delivered = true;
                
                break;
            }
        }
    }
}

- (void)mtProto:(MTProto *)mtProto messageDeliveryFailed:(int64_t)messageId
{
    bool requestTransaction = false;
    
    for (MTRequest *request in _requests)
    {
        if (request.requestContext != nil && request.requestContext.messageId == messageId)
        {
            request.requestContext = nil;
            requestTransaction = true;
            
            break;
        }
    }
    
    for (MTDropResponseContext *dropContext in _dropReponseContexts)
    {
        if (dropContext.messageId == messageId)
        {
            dropContext.messageId = 0;
            dropContext.messageSeqNo = 0;
            requestTransaction = true;
            
            break;
        }
    }
    
    if (requestTransaction)
        [mtProto requestTransportTransaction];
}

- (void)mtProto:(MTProto *)mtProto transactionsMayHaveFailed:(NSArray *)transactionIds
{
    bool requestTransaction = false;
    
    for (MTRequest *request in _requests)
    {
        if (request.requestContext != nil && request.requestContext.transactionId != nil && [transactionIds containsObject:request.requestContext.transactionId])
        {
            request.requestContext = nil;
            request.transactionResetStateVersion += 1;
            requestTransaction = true;
        }
    }
    
    if (requestTransaction)
        [mtProto requestTransportTransaction];
}

- (void)mtProtoAllTransactionsMayHaveFailed:(MTProto *)mtProto
{
    bool requestTransaction = false;
    
    for (MTRequest *request in _requests)
    {
        if (request.requestContext != nil)
        {
            request.requestContext = nil;
            request.transactionResetStateVersion += 1;
            requestTransaction = true;
        }
    }
    
    if (requestTransaction)
        [mtProto requestTransportTransaction];
}

- (bool)mtProto:(MTProto *)__unused mtProto shouldRequestMessageWithId:(int64_t)responseMessageId inResponseToMessageId:(int64_t)messageId currentTransactionId:(id)currentTransactionId
{
    for (MTRequest *request in _requests)
    {
        if (request.requestContext != nil && request.requestContext.messageId == messageId)
        {
            if (request.requestContext.transactionId == nil || [request.requestContext.transactionId isEqual:currentTransactionId]) {
                MTLog(@"[MTRequestMessageService#%" PRIxPTR " will request message %" PRId64 "]", (intptr_t)self, messageId);
                request.requestContext.responseMessageId = responseMessageId;
                return true;
            } else {
                MTLog(@"[MTRequestMessageService#%" PRIxPTR " will not request message %" PRId64 " (transaction was not completed)]", (intptr_t)self, messageId);
                MTLog(@"[MTRequestMessageService#%" PRIxPTR " but today it will]", (intptr_t)self);
                return true;
            }
        }
    }
    
    MTLog(@"[MTRequestMessageService#%" PRIxPTR " will not request message %" PRId64 " (request not found)]", (intptr_t)self, messageId);
    
    return false;
}

- (void)mtProto:(MTProto *)mtProto messageResendRequestFailed:(int64_t)messageId
{
    bool requestTransaction = false;
    
    for (MTRequest *request in _requests)
    {
        if (request.requestContext != nil && request.requestContext.responseMessageId == messageId)
        {
            request.requestContext = nil;
            requestTransaction = true;
        }
    }
    
    if (requestTransaction)
        [mtProto requestTransportTransaction];
}

- (void)mtProto:(MTProto *)mtProto updateReceiveProgressForToken:(id)progressToken progress:(float)progress packetLength:(NSInteger)packetLength
{
    if ([progressToken respondsToSelector:@selector(longLongValue)])
    {
        int64_t messageId = [(NSNumber *)progressToken longLongValue];
        
        for (MTRequest *request in _requests)
        {
            if (request.requestContext != nil && request.requestContext.messageId == messageId && request.progressUpdated)
                request.progressUpdated(progress, packetLength);
        }
    }
}

- (void)mtProtoDidChangeSession:(MTProto *)mtProto
{
    for (MTRequest *request in _requests)
    {
        request.requestContext = nil;
    }
    
    [_dropReponseContexts removeAllObjects];
    
    if (_requests.count != 0)
        [mtProto requestTransportTransaction];
}

- (void)mtProtoServerDidChangeSession:(MTProto *)mtProto firstValidMessageId:(int64_t)firstValidMessageId otherValidMessageIds:(NSArray *)otherValidMessageIds
{
    bool resendSomeRequests = false;
    for (MTRequest *request in _requests)
    {
        if (request.requestContext != nil && (request.requestContext.messageId < firstValidMessageId && ![otherValidMessageIds containsObject:@(request.requestContext.messageId)]))
        {
            request.requestContext = nil;
            
            resendSomeRequests = true;
        }
    }
    
    if (resendSomeRequests)
        [mtProto requestTransportTransaction];
}

- (void)mtProtoAuthTokenUpdated:(MTProto *)mtProto
{
    bool resendSomeRequests = false;
    for (MTRequest *request in _requests)
    {
        if (request.errorContext != nil && request.errorContext.waitingForTokenExport)
        {
            request.errorContext.waitingForTokenExport = false;
            resendSomeRequests = true;
        }
    }
    
    if (resendSomeRequests)
        [mtProto requestTransportTransaction];
}

/*- (int32_t)possibleSignatureForResult:(int64_t)messageId found:(bool *)found
{
    for (MTRequest *request in _requests)
    {
        if (request.requestContext != nil && request.requestContext.messageId == messageId)
        {
            if (found != NULL)
                *found = true;
            
            return [_serialization rpcRequestBodyResponseSignature:request.body];
        }
    }
    
    for (MTDropResponseContext *dropContext in _dropReponseContexts)
    {
        if (dropContext.messageId == messageId)
        {
            if (found != NULL)
                *found = true;
            
            return 0;
        }
    }
    
    return 0;
}*/

@end
