//
//  ComPusherPusherChannelProxy.m
//  pusher
//
//  Created by Ruben Fonseca on 02/11/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import "ComPusherChannelProxy.h"
#import "ComPusherChannelMembersProxy.h"

#import "TiUtils.h"

#define IS_PRESENCE_CHANNEL(channel) \
  [channel isKindOfClass:[PTPusherPresenceChannel class]]

@implementation ComPusherChannelProxy {
	ComPusherChannelMembersProxy *_membersProxy;
	NSMutableDictionary *bindings;
}

-(void)dealloc {
	// Remove all bindings
	[pusherChannel removeAllBindings];
	
  RELEASE_TO_NIL(pusherModule)
  RELEASE_TO_NIL(channel)
	RELEASE_TO_NIL(_membersProxy);
	RELEASE_TO_NIL(bindings);
  [super dealloc];
}

-(void)_configureWithPusher:(ComPusherModule *)aPusherModule andChannel:(NSString *)aChannel {
  RELEASE_TO_NIL(pusherModule)
  pusherModule = [aPusherModule retain];
	bindings = [[NSMutableDictionary alloc] init];
  
  [channel release];
  channel = [aChannel retain];
}

-(void)_subscribe {
  // Subscribe the channel!
  pusherChannel = [pusherModule.pusher subscribeToChannelNamed:channel];
  [pusherChannel retain];
	
	if(IS_PRESENCE_CHANNEL(pusherChannel)) {
		ComPusherChannelMembersProxy *membersProxy = [[ComPusherChannelMembersProxy alloc] _initWithPageContext:self.pageContext];
		[membersProxy _configureWithChannel:(PTPusherPresenceChannel *)pusherChannel];
		RELEASE_AND_REPLACE(_membersProxy, membersProxy);
		[membersProxy release];
		
		((PTPusherPresenceChannel *)pusherChannel).presenceDelegate = self;
	}
}

#pragma mark - Methods
-(void)unsubscribe:(id)args {
	[pusherChannel unsubscribe];
}

-(void)sendEvent:(id)args {
  ENSURE_UI_THREAD_1_ARG(args)
  
  enum Args {
    kArgName = 0,
    kArgData,
    kArgCount
  };
  
  ENSURE_ARG_COUNT(args, kArgCount);
  NSString *eventName = [TiUtils stringValue:[args objectAtIndex:kArgName]];
  NSDictionary *data  = [args objectAtIndex:kArgData];
  
  if(pusherModule.pusherAPI)
		[pusherModule.pusherAPI triggerEvent:eventName onChannel:channel data:data socketID:pusherModule.pusher.connection.socketID];
  else
    [self throwException:@"PusherAPI is not initialized" subreason:@"Please call the setup method with both the appID and the secret" location:CODELOCATION];
}

-(id)members {
	if(IS_PRESENCE_CHANNEL(pusherChannel)) {
		return _membersProxy;
	} else {
		return nil;
	}
}

-(id)trigger:(id)args {
	enum Args {
		kArgEventName = 0,
		kArgData,
		kArgCount
	};
	
	ENSURE_ARG_COUNT(args, kArgCount);
	NSString *eventName = [TiUtils stringValue:[args objectAtIndex:kArgEventName]];
	NSDictionary *eventData = [args objectAtIndex:kArgData];
	ENSURE_TYPE(eventData, NSDictionary);
	
	if([pusherChannel isKindOfClass:[PTPusherPrivateChannel class]]) {
		PTPusherPrivateChannel *privateChannel = (PTPusherPrivateChannel *)pusherChannel;
		[privateChannel triggerEventNamed:eventName data:eventData];
		
		return @(YES);
	} else {
		return @(NO);
	}
}

#pragma mark - Listeners
-(void)bind:(id)args {
	NSString *type = [args objectAtIndex:0];
	KrollCallback* listener = [[args objectAtIndex:1] retain];
	ENSURE_TYPE(listener,KrollCallback);
	
	TiObjectRef callbackFunction = [listener function];
	
	// First make sure that the binding doesn't exist already
	NSMutableDictionary *map = [bindings objectForKey:type];
	if(map) {
		TiObjectRef callbackFunction = [listener function];
		NSValue *callbackValue = [NSValue valueWithPointer:callbackFunction];
		PTPusherEventBinding *binding = [map objectForKey:callbackValue];
		
		if(binding)
			// Binding already exists, ignore!
			return;
	}
	
	PTPusherEventBinding *binding = [pusherChannel bindToEventNamed:type handleWithBlock:^(PTPusherEvent *pusher_event) {
		[[listener context] invokeBlockOnThread:^{
			[listener call:@[pusher_event.data] thisObject:self];
		}];
	}];
	
	NSValue *callbackValue = [NSValue valueWithPointer:callbackFunction];
	map = [bindings objectForKey:type];
	if(!map)
		map = [[[NSMutableDictionary alloc] init] autorelease];
	
	[map setObject:binding forKey:callbackValue];
	[bindings setObject:map forKey:type];
}

-(void)unbind:(id)args {
	NSString *type = [args objectAtIndex:0];
	KrollCallback* listener = [args objectAtIndex:1];
	ENSURE_TYPE(listener,KrollCallback);
	
	NSMutableDictionary *map = [bindings objectForKey:type];
	if(map) {
		TiObjectRef callbackFunction = [listener function];
		NSValue *callbackValue = [NSValue valueWithPointer:callbackFunction];
		PTPusherEventBinding *binding = [map objectForKey:callbackValue];
		
		if(binding) {
			[pusherChannel removeBinding:binding];
			[map removeObjectForKey:callbackValue];
			[bindings setObject:map forKey:type];
		}
	}
}

-(void)fireEvent:(NSString *)type withObject:(id)data {
	NSDictionary *map = [bindings objectForKey:type];
	[map enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
		TiObjectRef callbackFunction = [(NSValue *)key pointerValue];
		KrollCallback *callback = [KrollObject toID:[self.executionContext krollContext] value:callbackFunction];
		
		NSArray *payload = @[];
		if(data) { payload = @[data]; }
		
		[[callback context] invokeBlockOnThread:^{
			[callback call:payload thisObject:self];
		}];
	}];
}

#pragma mark - PTPusherPresenceChannelDelegate
-(void)presenceChannel:(PTPusherPresenceChannel *)channel memberAddedWithID:(NSString *)memberID memberInfo:(NSDictionary *)memberInfo {
	[self fireEvent:@"pusher:member_added" withObject:@{ @"member" : @{ @"id" : memberID, @"info": memberInfo } }];
}

-(void)presenceChannel:(PTPusherPresenceChannel *)channel memberRemovedWithID:(NSString *)memberID memberInfo:(NSDictionary *)memberInfo atIndex:(NSInteger)index {
	[self fireEvent:@"pusher:member_removed" withObject:@{ @"member" : @{ @"id" : memberID, @"info": memberInfo } }];
}

-(void)presenceChannel:(PTPusherPresenceChannel *)channel didSubscribeWithMemberList:(NSArray *)members {
}

@end
