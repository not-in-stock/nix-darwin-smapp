#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>

int main(int argc, char *argv[]) {
    @autoreleasepool {
        BOOL unregisterMode = NO;
        if (argc > 1 && strcmp(argv[1], "--unregister") == 0) {
            unregisterMode = YES;
        }

        NSString *agentsDir = [NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:@"Contents/Library/LaunchAgents"];

        NSArray *items = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:agentsDir error:nil];

        for (NSString *item in items) {
            if (![item hasSuffix:@".plist"]) continue;

            SMAppService *service = [SMAppService agentServiceWithPlistName:item];

            if (unregisterMode) {
                NSError *error = nil;
                if ([service unregisterAndReturnError:&error]) {
                    NSLog(@"Unregistered %@", item);
                } else {
                    NSLog(@"Failed to unregister %@: %@", item, error.localizedDescription);
                }
                continue;
            }

            // Unregister first to pick up changes from rebuilt bundle
            if (service.status == SMAppServiceStatusEnabled) {
                [service unregisterAndReturnError:nil];
            }

            NSError *error = nil;
            if ([service registerAndReturnError:&error]) {
                NSLog(@"Registered %@", item);
            } else {
                NSLog(@"Failed to register %@: %@", item, error.localizedDescription);
            }
        }
    }

    usleep(500000);
    return 0;
}
