#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PBProcessEnvironment : NSObject

+ (NSDictionary<NSString *, NSString *> *)preparedEnvironment:(NSDictionary<NSString *, NSString *> *)environment
                                                homeDirectory:(NSString *)homeDirectory;

@end

NS_ASSUME_NONNULL_END
