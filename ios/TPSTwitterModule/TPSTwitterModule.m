#import "TPSTwitterModule.h"
#import <TwitterKit/TwitterKit.h>
#import <Social/Social.h>
#import "RCTUtils.h"
#import <OAuthCore.h>

typedef void(^TWTAPIHandler)(NSData *data, NSError *error);
typedef void(^TWTRSessionHandler)(TWTRSession *session, NSError *error);

@implementation TPSTwitterModule

RCT_EXPORT_MODULE()

- (dispatch_queue_t)methodQueue {
    return dispatch_get_main_queue();
}

RCT_EXPORT_METHOD(setTwitterKeys:(NSDictionary*)twitterCredentials) {
    [[Twitter sharedInstance] startWithConsumerKey:twitterCredentials[@"consumerKey"] consumerSecret:twitterCredentials[@"consumerSecret"]];
}

RCT_EXPORT_METHOD(login:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    ACAccountStore *account = [[ACAccountStore alloc] init];
    ACAccountType *accountType = [account accountTypeWithAccountTypeIdentifier:
                                  ACAccountTypeIdentifierTwitter];
    __typeof__(self) __weak weakSelf = self;
    [account requestAccessToAccountsWithType:accountType options:nil completion:^(BOOL granted, NSError *error) {
        if (granted) {
            NSArray *accounts = [account
                                 accountsWithAccountType:accountType];
            if (accounts.count) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
                
                for (ACAccount *twAccount in accounts) {

                    UIAlertAction* action = [UIAlertAction
                                                    actionWithTitle:[NSString stringWithFormat:@"@%@", twAccount.username]
                                                    style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction * action) {
                                                        __strong typeof(self) strongSelf = weakSelf;
                                                        [strongSelf createSessionFromAccount:twAccount withHandler:^(TWTRSession *session, NSError *error) {
                                                            if (error) {
                                                                reject(nil, nil, error);
                                                            } else {
                                                                NSDictionary *body = @{@"authToken": session.authToken,
                                                                                       @"authTokenSecret": session.authTokenSecret,
                                                                                       @"userID":session.userID,
                                                                                       @"userName":session.userName};
                                                                resolve(body);
                                                            }
                                                        }];
                                                    }];
                    [alert addAction:action];
                }
                
                UIAlertAction* webLoginAction = [UIAlertAction
                                         actionWithTitle:@"Log in as another user"
                                         style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction * action) {
                                             __strong typeof(self) strongSelf = weakSelf;
                                             [strongSelf webBasedLogin:resolve rejecter:reject];
                                         }];
                [alert addAction:webLoginAction];
                
                UIAlertAction* cancelAction = [UIAlertAction
                                                 actionWithTitle:@"Cancel"
                                                 style:UIAlertActionStyleCancel
                                                 handler:nil];
                [alert addAction:cancelAction];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [RCTPresentedViewController() presentViewController:alert animated:YES completion:nil];
                });
            } else {
                __strong typeof(self) strongSelf = weakSelf;
                [strongSelf webBasedLogin:resolve rejecter:reject];
            }
        } else {
            reject(nil, nil, error);
        }
    }];
}

- (void)webBasedLogin:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject {
    //TODO: Add Checking [[Twitter sharedInstance] authConfig]
    [[Twitter sharedInstance] logInWithMethods:TWTRLoginMethodWebBasedForceLogin completion:^(TWTRSession *session, NSError *error) {
        if (session) {
            NSDictionary *body = @{@"authToken": session.authToken,
                                   @"authTokenSecret": session.authTokenSecret,
                                   @"userID":session.userID,
                                   @"userName":session.userName};
            resolve(body);
        } else {
            reject(nil, nil, error);
        }
    }];

}

- (void)createSessionFromAccount:(ACAccount*)account withHandler:(TWTRSessionHandler)handler {
    [self performReverseAuthForAccount:account withHandler:^(NSData *responseData, NSError *error) {
        if (error) {
            if (handler) {
                handler(nil, error);
            }
        } else {
            NSString *responseStr = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
            
            NSDictionary *twitterCredential = [self parseQueryString:responseStr];
            
            TWTRSession *session = [[TWTRSession alloc] initWithAuthToken:twitterCredential[@"oauth_token"] authTokenSecret:twitterCredential[@"oauth_token_secret"] userName:twitterCredential[@"screen_name"] userID:twitterCredential[@"user_id"]];
            if (handler) {
                handler(session, nil);
            }
        }
    }];
}

#pragma mark - Twitter Reverse Auth

- (void)performReverseAuthForAccount:(ACAccount *)account withHandler:(TWTAPIHandler)handler {
    [self _step1WithCompletion:^(NSData *data, NSError *error) {
        if (!data) {
            dispatch_async(dispatch_get_main_queue(), ^{
                handler(nil, error);
            });
        }
        else {
            NSString *signedReverseAuthSignature = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            [self _step2WithAccount:account signature:signedReverseAuthSignature andHandler:^(NSData *responseData, NSError *error2) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    handler(responseData, error2);
                });
            }];
        }
    }];
}

- (void)_step1WithCompletion:(TWTAPIHandler)completion {
    //TwitterKit must be used only from the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *url = [NSURL URLWithString:@"https://api.twitter.com/oauth/request_token"];
        NSString *paramsString = @"x_auth_mode=reverse_auth&";
        //  Create the authorization header and attach to our request
        NSData *bodyData = [paramsString dataUsingEncoding:NSUTF8StringEncoding];
        NSString *authorizationHeader = OAuthorizationHeader(url, @"POST", bodyData, [Twitter sharedInstance].authConfig.consumerKey, [Twitter sharedInstance].authConfig.consumerSecret, nil, nil);
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        [request setValue:authorizationHeader forHTTPHeaderField:@"Authorization"];
        request.HTTPBody = bodyData;
        
        [NSURLConnection sendAsynchronousRequest:request queue:[[NSOperationQueue alloc] init] completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
            completion(data, connectionError);
        }];
    });
}

- (void)_step2WithAccount:(ACAccount *)account signature:(NSString *)signedReverseAuthSignature andHandler:(TWTAPIHandler)completion {
    //TwitterKit must be used only from the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *step2Params = @{@"x_reverse_auth_target": [Twitter sharedInstance].authConfig.consumerKey, @"x_reverse_auth_parameters": signedReverseAuthSignature};
        NSURL *authTokenURL = [NSURL URLWithString:@"https://api.twitter.com/oauth/access_token"];
        SLRequest *step2Request = [SLRequest requestForServiceType:SLServiceTypeTwitter requestMethod:SLRequestMethodPOST URL:authTokenURL parameters:step2Params];
        step2Request.account = account;
        [step2Request performRequestWithHandler:^(NSData *responseData, NSHTTPURLResponse *urlResponse, NSError *error) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                completion(responseData, error);
            });
        }];
    });
}

- (NSDictionary *)parseQueryString:(NSString *)string {
    NSMutableDictionary *queryStringDictionary = [[NSMutableDictionary alloc] init];
    NSArray *urlComponents = [string componentsSeparatedByString:@"&"];
    
    for (NSString *keyValuePair in urlComponents) {
        NSArray *pairComponents = [keyValuePair componentsSeparatedByString:@"="];
        NSString *key = [pairComponents objectAtIndex:0];
        NSString *value = [pairComponents objectAtIndex:1];
        
        [queryStringDictionary setObject:value forKey:key];
    }
    
    return queryStringDictionary;
}

@end