//
//  UsersManager.m
//  TelegramTest
//
//  Created by keepcoder on 26.10.13.
//  Copyright (c) 2013 keepcoder. All rights reserved.
//

#import "UsersManager.h"
#import "UploadOperation.h"
#import "TGFileLocation+Extensions.h"
#import "ImageUtils.h"
#import "TGTimer.h"

@interface UsersManager ()
@property (nonatomic, strong) TGTimer *lastSeenUpdater;
@property (nonatomic, strong) RPCRequest *lastSeenRequest;
@end

@implementation UsersManager


- (id)init {
    if(self = [super init]) {
        [Notification addObserver:self selector:@selector(protocolUpdated:) name:PROTOCOL_UPDATED];
        [Notification addObserver:self selector:@selector(logoutNotification) name:LOGOUT_EVENT];
    }
    return self;
}

- (void)protocolUpdated:(NSNotification *)notify {
    [ASQueue dispatchOnStageQueue:^{
        [self.lastSeenUpdater invalidate];
        [self.lastSeenRequest cancelRequest];
        
        self.lastSeenUpdater = [[TGTimer alloc] initWithTimeout:300 repeat:YES completion:^{
            [self statusUpdater];
        } queue:[ASQueue globalQueue].nativeQueue];
        
        [self.lastSeenUpdater start];
        [self statusUpdater];
    }];
}

- (void)statusUpdater {
    [self.lastSeenRequest cancelRequest];
    
    NSMutableArray *needUsersUpdate = [[NSMutableArray alloc] init];
    for(TGUser *user in list) {
        if(user.lastSeenUpdate + 300 < [[MTNetwork instance] getTime]) {
            if(user.type == TGUserTypeForeign || user.type == TGUserTypeRequest) {
                [needUsersUpdate addObject:user.inputUser];
            }
        }
    }
    
    if(needUsersUpdate.count == 0)
        return;
    
    self.lastSeenRequest = [RPCRequest sendRequest:[TLAPI_users_getUsers createWithN_id:needUsersUpdate] successHandler:^(RPCRequest *request, NSMutableArray *response) {
        
        [self add:response withCustomKey:@"n_id" update:YES];
        
    } errorHandler:nil];
}

- (void)logoutNotification {
    [ASQueue dispatchOnStageQueue:^{
        [self.lastSeenRequest cancelRequest];
        [self.lastSeenUpdater invalidate];
        self.lastSeenUpdater = nil;
    }];
}

-(void)drop {
    [ASQueue dispatchOnStageQueue:^{
        [self->list removeAllObjects];
        [self->keys removeAllObjects];
    }];
}

-(void)loadUsers:(NSArray *)users completeHandler:(void (^)())completeHandler {
    
    [RPCRequest sendRequest:[TLAPI_users_getUsers createWithN_id:[users mutableCopy]] successHandler:^(RPCRequest *request, id response) {
        
        [self add:response];
        if(completeHandler)
            completeHandler();
    } errorHandler:^(RPCRequest *request, RpcError *error) {
        if(completeHandler) {
            completeHandler();
        }
    }];
}

- (void)addFromDB:(NSArray *)array {
    [self add:array withCustomKey:@"n_id" update:NO];
}

- (void)add:(NSArray *)all withCustomKey:(NSString *)key {
    [self add:all withCustomKey:key update:YES];
}

- (void)add:(NSArray *)all withCustomKey:(NSString *)key update:(BOOL)isNeedUpdateDB {

    [ASQueue dispatchOnStageQueue:^{
        
        NSMutableArray *usersToUpdate = [NSMutableArray array];
        
        for (TGUser *newUser in all) {
            TGUser *currentUser = [keys objectForKey:[newUser valueForKey:key]];
            
            BOOL needUpdateUserInDB = NO;
            if(currentUser) {
                BOOL isNeedRebuildNames = NO;
                BOOL isNeedChangeTypeNotify = NO;
                if(newUser.type != currentUser.type) {
                    [currentUser setType:newUser.type];
                    
                    isNeedRebuildNames = YES;
                    isNeedChangeTypeNotify = YES;
                }
                
                if(currentUser.type != TGUserTypeEmpty) {
                    if(![newUser.first_name isEqualToString:currentUser.first_name] || ![newUser.last_name isEqualToString:currentUser.last_name]) {
                        
                        currentUser.first_name = newUser.first_name;
                        currentUser.last_name = newUser.last_name;
                        
                        isNeedRebuildNames = YES;
                    }
                }
                
                if(currentUser.photo.photo_small.hashCacheKey != newUser.photo.photo_small.hashCacheKey) {
                    currentUser.photo = newUser.photo;
                    [Notification perform:USER_UPDATE_PHOTO data:@{KEY_USER: currentUser}];
                    needUpdateUserInDB = YES;
                }
                
                currentUser.access_hash = newUser.access_hash;
                currentUser.inactive = newUser.inactive;
                
                if(!currentUser.phone || !currentUser.phone.length)
                    currentUser.phone = newUser.phone;
                
                if(isNeedRebuildNames) {
                    [currentUser rebuildNames];
                    [Notification perform:USER_UPDATE_NAME data:@{KEY_USER: currentUser}];
                }
                
                if(isNeedChangeTypeNotify) {
                    [Notification perform:[Notification notificationForUser:currentUser action:USER_CHANGE_TYPE] data:@{KEY_USER:currentUser}];
                }
                
            } else {
                
                if(newUser.type == TGUserTypeEmpty) {
                    newUser.first_name = @"Deleted";
                    newUser.last_name = @"";
                    newUser.phone = @"";
                }
                
                [self->list addObject:newUser];
                [self->keys setObject:newUser forKey:[newUser valueForKey:key]];
                
                [newUser rebuildNames];
                
                
                
                [newUser rebuildType];
                
                 currentUser = newUser;
                if(isNeedUpdateDB) {
                    currentUser.lastSeenUpdate = [[MTNetwork instance] getTime];
                }

                
                needUpdateUserInDB = YES;
            }
            
            if(currentUser.type == TGUserTypeSelf)
                _userSelf = currentUser;
            
            BOOL result = [self setUserStatus:newUser.status forUser:currentUser];
            if(!needUpdateUserInDB && result) {
                needUpdateUserInDB = YES;
            }
            
            if(needUpdateUserInDB && isNeedUpdateDB) {
                [usersToUpdate addObject:currentUser];
            }
        }
        
        if(usersToUpdate.count)
            [[Storage manager] insertUsers:usersToUpdate completeHandler:nil];
    }];
    
}

- (BOOL)setUserStatus:(TGUserStatus *)status forUser:(TGUser *)currentUser {
    
    BOOL result = currentUser.status.expires != status.expires && currentUser.status.was_online != status.was_online;
    
    currentUser.status.expires = status.expires;
    currentUser.status.was_online = status.was_online;
    
    
    currentUser.lastSeenUpdate = [[MTNetwork instance] getTime];
    
    
    [Notification perform:USER_STATUS data:@{KEY_USER_ID: @(currentUser.n_id)}];
    
    return result;
}

- (void)setUserStatus:(TGUserStatus *)status forUid:(int)uid {
    [ASQueue dispatchOnStageQueue:^{
        TGUser *currentUser = [keys objectForKey:@(uid)];
        if(currentUser) {
            BOOL result = [self setUserStatus:status forUser:currentUser];
            if(result) {
                [[Storage manager] updateLastSeen:currentUser];
            }
        }
    }];
}


+ (int)currentUserId {
    return [[UsersManager sharedManager] userSelf].n_id;
}


+ (TGUser *)currentUser {
    return [[UsersManager sharedManager] userSelf];
}


-(void)updateAccount:(NSString *)firstName lastName:(NSString *)lastName completeHandler:(void (^)(TGUser *))completeHandler errorHandler:(void (^)(NSString *))errorHandler {
    [RPCRequest sendRequest:[TLAPI_account_updateProfile createWithFirst_name:firstName last_name:lastName] successHandler:^(RPCRequest *request, TGUser *response) {
        
        if(response.type == TGUserTypeSelf) {
            [self add:@[response]];
        }
        
        
        [[Storage manager] insertUser:self.userSelf completeHandler:nil];
        
        completeHandler(self.userSelf);
        [Notification perform:USER_UPDATE_NAME data:@{KEY_USER:self.userSelf}];
    } errorHandler:^(RPCRequest *request, RpcError *error) {
        if(errorHandler)
            errorHandler(NSLocalizedString(@"Profile.CantUpdate", nil));
    } timeout:10];
}

-(void)updateAccountPhoto:(NSString *)path completeHandler:(void (^)(TGUser *user))completeHandler progressHandler:(void (^)(float))progressHandler errorHandler:(void (^)(NSString *description))errorHandler {
    UploadOperation *operation = [[UploadOperation alloc] init];
    
    [operation setUploadComplete:^(UploadOperation *operation, id input) {
        
        [RPCRequest sendRequest:[TLAPI_photos_uploadProfilePhoto createWithFile:input caption:@"me" geo_point:[TL_inputGeoPointEmpty create] crop:[TL_inputPhotoCropAuto create]] successHandler:^(RPCRequest *request, id response) {
            
            [SharedManager proccessGlobalResponse:response];
            
            if(completeHandler)
                completeHandler(self.userSelf);
        } errorHandler:^(RPCRequest *request, RpcError *error) {
            if(errorHandler)
                errorHandler(NSLocalizedString(@"Profile.Error.CantUpdatePhoto", nil));
        } timeout:10];
        
    }];
    
    [operation setUploadProgress:^(UploadOperation *operation, NSUInteger current, NSUInteger total) {
         if(progressHandler)
             progressHandler((float)current/(float)total * 100);
    }];
    
    [operation setUploadStarted:^(UploadOperation *operation, NSData *data) {
        
    }];
    
    [operation setFilePath:path];
    [operation ready:UploadImageType];
}

-(void)updateAccountPhotoByNSImage:(NSImage *)image completeHandler:(void (^)(TGUser *user))completeHandler progressHandler:(void (^)(float progress))progressHandler errorHandler:(void (^)(NSString *description))errorHandler {
    
    UploadOperation *operation = [[UploadOperation alloc] init];
    
    [operation setUploadComplete:^(UploadOperation *operation, id input) {
        
        [RPCRequest sendRequest:[TLAPI_photos_uploadProfilePhoto createWithFile:input caption:@"me" geo_point:[TL_inputGeoPointEmpty create] crop:[TL_inputPhotoCropAuto create]] successHandler:^(RPCRequest *request, id response) {
            [SharedManager proccessGlobalResponse:response];
            
            if(completeHandler)
                completeHandler(self.userSelf);
        } errorHandler:^(RPCRequest *request, RpcError *error) {
            if(errorHandler)
                errorHandler(NSLocalizedString(@"Profile.Error.CantUpdatePhoto", nil));
        } timeout:10];
        
    }];
    
    [operation setUploadProgress:^(UploadOperation *operation, NSUInteger current, NSUInteger total) {
        if(progressHandler)
            progressHandler((float)current/(float)total * 100);
    }];
    
    [operation setUploadStarted:^(UploadOperation *operation, NSData *data) {
        
    }];
    
    [operation setFileData:compressImage([image TIFFRepresentation], 0.7)];
    [operation ready:UploadImageType];
}



+(id)sharedManager {
    static id instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        
        instance = [[[self class] alloc] init];
    });
    return instance;
}
@end
