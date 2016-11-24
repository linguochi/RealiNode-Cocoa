//
//  H3CClientBackend.m
//  OS-X-H3CClient
//
//  Created by Arthas on 6/6/14.
//  Copyright (c) 2014 Shandong University. All rights reserved.
//

#import "H3CClientBackend.h"
#import <string.h>
#import <pcap/pcap.h>

@implementation H3CClientBackend

NSDictionary *_adapterList;

+ (H3CClientBackend*)defaultBackend {
    static H3CClientBackend *backend;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        backend = [[H3CClientBackend alloc] init];
    });
    return backend;
}

- (id)init {
    if(self = [super init]) {
        _adapterList = nil;
        self.connectionState = Disconnected;
        self.globalConfiguration = [NSUserDefaults standardUserDefaults];
        //self.adapterList = [self getAdapterList];
        self.connector = [[H3CClientConnector alloc] init];
        self.manualDisconnect = NO;
        self.status = @"Disconnected";
    }
    return self;
}

- (void)dealloc
{
}

- (void)sendUserNotificationWithDescription:(NSString *)desc
{
    NSUserNotification *notification = [[NSUserNotification alloc] init];
    notification.title = @"RealiNode";
    notification.informativeText = desc;
    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
}

- (void)connect
{
    [self reloadBPF];
    long int selected = [self.globalConfiguration integerForKey:@"default"];
    if(selected == -1) {
        [self sendUserNotificationWithDescription:@"No default profile set."];
        return ;
    }
    [self connectUsingProfile:selected];
}

- (void)connectUsingProfile:(NSInteger)selected
{
    [self reloadBPF];
    self.connectionState = Connecting;
    dispatch_async(dispatch_get_global_queue(0, 0), ^(){
        NSLog(@"connecting...");
        NSArray *profiles = [self.globalConfiguration objectForKey:@"profiles"];
        if([profiles count] == 0) {
//            [self sendUserNotificationWithDescription:@"Please add a profile before connecting."];
            [self sendUserNotificationWithDescription:NSLocalizedString(@"noprofile", @"Please add a profile before connecting.")];
            
            return ;
        }
        NSDictionary *dict = [profiles objectAtIndex:selected];
        NSString *userName = dict[@"username"];
        NSString *password = dict[@"password"];
        NSString *adapterName = dict[@"interface"];
        if(userName == nil || [userName isEqualToString:@""] || password == nil || [password isEqualToString:@""]) {
            [self sendUserNotificationWithDescription:@"Username and password are required."];
            self.connectionState = Disconnected;
            return ;
        }

        self.userName = userName;
        self.status = @"Opening adapter...";
        if(![self.connector openAdapter:adapterName]) {
            [self sendUserNotificationWithDescription:@"Failed to open network adapter."];
            self.connectionState = Disconnected;
            self.status = @"Disconnected";
            return ;
        }

        self.status = @"Looking for server...";
        if(![self.connector findServer]) {
            [self sendUserNotificationWithDescription:@"Cannot find authentication server."];
            self.connectionState = Disconnected;
            self.status = @"Disconnected";
            return ;
        }

        self.timeConnected = time(NULL);
        self.trafficStatConnected = [self.connector getTrafficStat];
        while(![self startDaemonWithUserName:userName password:password]) {
            if(![self.globalConfiguration boolForKey:@"reconnect"]) {
//                [self sendUserNotificationWithDescription:@"Connection was interrupted."];
                [self sendUserNotificationWithDescription:NSLocalizedString(@"interupt", @"Connection was interrupted.")];
                break;
            } else {
//                [self sendUserNotificationWithDescription:@"Connection was interrupted, reconnecting..."];
                [self sendUserNotificationWithDescription:NSLocalizedString(@"interuptAndReconnect", @"Connection was interrupted, reconnecting...")];
                self.connectionState = Connecting;

                if(![self.connector openAdapter:adapterName]) {
                    [self sendUserNotificationWithDescription:@"Failed to open network adapter."];
                    break;
                }

                if(![self.connector findServer]) {
                    [self sendUserNotificationWithDescription:@"Cannot find authentication server."];
                    break;
                }
            }
        }
        self.manualDisconnect = NO;
        self.connectionState = Disconnected;
        self.status = @"Disconnected";
        return ;

    });
}

- (void)disconnect
{
    self.manualDisconnect = YES;
    self.connectionState = Disconnecting;
    [self.connector breakLoop];
}

- (NSDictionary *)getAdapterList
{
    NSMutableDictionary *adapters = [NSMutableDictionary new];
    NSDictionary *networkServices = [NSDictionary dictionaryWithContentsOfFile:@"/Library/Preferences/SystemConfiguration/preferences.plist"][@"NetworkServices"];
    for (id key in networkServices)
    {
        id interface = networkServices[key];
        if (interface[@"Interface"])
            [adapters setObject:interface[@"Interface"][@"DeviceName"] forKey:interface[@"UserDefinedName"]];
    }
    return adapters;
}

- (BOOL)startDaemonWithUserName:(NSString *)userName password:(NSString *)password
{
    const PacketFrame *frame;
    HWADDR srvaddr;
    BOOL srvfound = NO;
    NSString *message;
    BYTE token[32];

    while([self.connector nextPacket:&frame withTimeout:30]) {
        if(frame == nil) continue;
        switch(frame->code) {
            case EAP_REQUEST:
                switch(frame->eaptype) {
                    case EAP_KEEPONLINE:
                        NSLog(@"received EAP_REQUEST/EAP_KEEPONLINE");
                        if(srvfound && ![self.connector keepOnlineWithId:frame->pid userName:userName token:token on:srvaddr]) {
                            [self sendUserNotificationWithDescription:@"Failed to communicate with server."];
                            self.connectionState = Disconnecting;
                            self.status = @"Error occured";
                        }
                        break;
                    case EAP_IDENTIFY:
                        NSLog(@"received EAP_REQUEST/EAP_IDENTIFY");
                        if(!srvfound) {
                            self.status = @"Verifying username...";
                            memcpy(&srvaddr, &(frame->ethernet.source), sizeof(HWADDR));
                            srvfound = YES;
                        }
                        if(![self.connector verifyUserName:userName withId:frame->pid on:srvaddr]) {
                            [self sendUserNotificationWithDescription:@"Failed to communicate with server."];
                            self.connectionState = Disconnecting;
                            self.status = @"Error occured";
                        }
                        break;
                    case EAP_MD5:
                        NSLog(@"received EAP_REQUEST/EAP_MD5");
                        self.status = @"Verifying password...";
                        if(srvfound && ![self.connector verifyPassword:password withId:frame->pid userName:userName seed:((PasswordFrame *)frame)->password on:srvaddr]) {
                            [self sendUserNotificationWithDescription:@"Failed to communicate with server."];
                            self.connectionState = Disconnecting;
                            self.status = @"Error occured";
                        }
                        break;
                    default:
                        NSLog(@"received EAP_REQUEST/UNKNOWN %d", frame->eaptype);
                }
                break;
            case EAP_SUCCESS:
                self.status = @"Online";
                NSLog(@"received EAP_SUCCESS");
//                [self sendUserNotificationWithDescription:@"Authenticated successfully."];
                
                [self sendUserNotificationWithDescription:NSLocalizedString(@"success", @"Authenticated successfully.")];
                [self.connector updateIP];
                self.connectionState = Connected;
                break;
            case EAP_FAILURE:
                self.status = @"Error occured";
                NSLog(@"received EAP_FAILURE");
                message = [self.connector parseFailureFrame:(FailureFrame *)frame];
                NSLog(@"Reason: %@", message);
            
                if ([message hasPrefix:@"63018"]) {
                    [self sendUserNotificationWithDescription:NSLocalizedString(@"noUser", "Faild! User Does not exist!")];
                    self.manualDisconnect = YES; // we do not reconnect for no exsiting username.
                    
                }else if ([message hasPrefix:@"63032"]){
                    [self sendUserNotificationWithDescription:NSLocalizedString(@"incorrectPwd", "Falid! Incorrect Password!")];
                    self.manualDisconnect = YES; // we do not reconnect for wrong username/password.
                    
                }else if ([message hasPrefix:@"63022"]){
                    [self sendUserNotificationWithDescription:NSLocalizedString(@"upperLimit", "Falid! The online number reaches the upper-limit!")];
                    self.manualDisconnect = YES; // we do not reconnect for reaching the upper limit
                    
                }else if ([message hasPrefix:@"ADIUS Server No Response"]){
                    [self sendUserNotificationWithDescription:NSLocalizedString(@"ServerNoResponse", "Falid! Server No response try again later!")];
                    self.manualDisconnect = YES; // we do not reconnect for reaching the upper limit
                
                }else{
                    [self sendUserNotificationWithDescription:message];
                }
            
                self.connectionState = Disconnecting;
                
//                if(((FailureFrame *)frame)->errcode != 8 && message.length >= 5) {
//                    self.manualDisconnect = YES; // we do not reconnect for wrong username/password.
//                }
                break;
            case EAP_OTHER:
                NSLog(@"received EAP_OTHER");
                if([self.connector parseTokenFrame:(TokenFrame *)frame to:token])
                    break;
                // Rest ignored.
                break;
            default:
                NSLog(@"received UNKNOWN");
        }
        if(self.connectionState == Disconnecting)
            break;
    }
    if(self.connectionState == Disconnecting) {
        if(srvfound)
            [self.connector logout:srvaddr];
    }
    [self.connector closeAdapter];
    return self.manualDisconnect;
}

- (NSDictionary *)adapterList
{
    if(_adapterList == nil) {
        _adapterList = [self getAdapterList];
    }
    return _adapterList;
}

- (NSString*)getUserName
{
    if(self.connectionState == Connected) {
        return self.userName;
    } else {
        return @"N/A";
    }
}

- (NSString*)getIPAddress
{
    static NSString *cachedAddress = nil;

    if(self.connectionState == Connected) {
        if (cachedAddress != nil)
            return cachedAddress;
        NSArray *addrs = [[NSHost currentHost] addresses];
        for (NSString *addr in addrs) {
            if (![addr hasPrefix:@"127"] && [[addr componentsSeparatedByString:@"."] count] == 4) {
                cachedAddress = addr;
                return addr;
            }
        }
    }

    cachedAddress = nil;
    return @"No IPv4 address";
}

- (void)updateIP
{
    [self.connector updateIP];
}

- (NSDictionary*)getTrafficStatSinceConnected
{
    if(self.connectionState != Connected) {
        NSMutableDictionary *dict = [NSMutableDictionary new];
        [dict setObject:[NSNumber numberWithUnsignedInteger:0] forKey:@"input"];
        [dict setObject:[NSNumber numberWithUnsignedInteger:0] forKey:@"output"];
        return dict;
    } else {
        NSMutableDictionary *dict = [self.connector getTrafficStat];
        unsigned input = [((NSNumber*)dict[@"input"]) intValue] - [self.trafficStatConnected[@"input"] intValue];
        unsigned output = [((NSNumber*)dict[@"output"]) intValue] - [self.trafficStatConnected[@"output"] intValue];
        dict[@"input"] = [NSNumber numberWithUnsignedInteger:input];
        dict[@"output"] = [NSNumber numberWithUnsignedInteger:output];
        return dict;
    }
}

-(void)reloadBPF{
    NSString *prefix = [[NSBundle mainBundle] resourcePath];
    NSString *combined = [NSString stringWithFormat:@"%@%@", prefix, @"/Script.sh"];
    
    [[NSProcessInfo processInfo] processIdentifier];
    NSPipe *pipe = [NSPipe pipe];
    NSFileHandle *file = pipe.fileHandleForReading;
    
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/sh";
    task.arguments =@[combined];
    task.standardOutput = pipe;
    
    [task launch];
    
    NSData *data = [file readDataToEndOfFile];
    [file closeFile];
    
    NSString *grepOutput = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
    NSLog (@"\n%@", grepOutput);
    
}

@end
