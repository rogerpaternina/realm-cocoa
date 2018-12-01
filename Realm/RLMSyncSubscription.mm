////////////////////////////////////////////////////////////////////////////
//
// Copyright 2018 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMSyncSubscription.h"

#import "RLMObjectSchema_Private.hpp"
#import "RLMObject_Private.hpp"
#import "RLMProperty_Private.hpp"
#import "RLMRealm_Private.hpp"
#import "RLMResults_Private.hpp"
#import "RLMUtil.hpp"

#import "object_store.hpp"
#import "sync/partial_sync.hpp"

using namespace realm;

@interface RLMSyncSubscription ()
@property (nonatomic, readwrite) RLMSyncSubscriptionState state;
@property (nonatomic, readwrite, nullable) NSError *error;
@end

@implementation RLMSyncSubscription {
    @public
    NSString *_name;
}

- (instancetype)initPrivate {
    return (self = [super init]);
}

- (void)unsubscribe {
    __builtin_unreachable();
}
@end

@interface RLMSyncSubscriptionObject : RLMObjectBase
@end
@implementation RLMSyncSubscriptionObject {
    util::Optional<NotificationToken> _token;
    Object _obj;
}

- (NSString *)name {
    return _row.is_attached() ? RLMStringDataToNSString(_row.get_string(_row.get_column_index("name"))) : nil;
}

- (RLMSyncSubscriptionState)state {
    if (!_row.is_attached()) {
        return RLMSyncSubscriptionStateInvalidated;
    }
    return (RLMSyncSubscriptionState)_row.get_int(_row.get_column_index("status"));
}

- (NSError *)error {
    if (!_row.is_attached()) {
        return nil;
    }
    StringData err = _row.get_string(_row.get_column_index("error_message"));
    if (!err.size()) {
        return nil;
    }
    return [NSError errorWithDomain:RLMErrorDomain
                               code:RLMErrorFail
                           userInfo:@{NSLocalizedDescriptionKey: RLMStringDataToNSString(err)}];
}

- (NSString *)descriptionWithMaxDepth:(NSUInteger)depth {
    if (depth == 0) {
        return @"<Maximum depth exceeded>";
    }

    auto objectType = _row.get_string(_row.get_column_index("matches_property"));
    objectType = objectType.substr(0, objectType.size() - strlen("_matches"));
    return [NSString stringWithFormat:@"RLMSyncSubscription {\n\tname = %@\n\tobjectType = %@\n\tquery = %@\n\tstatus = %@\n\terror = %@\n}",
            self.name, RLMStringDataToNSString(objectType),
            RLMStringDataToNSString(_row.get_string(_row.get_column_index("query"))),
            @(self.state), self.error];
}

- (void)unsubscribe {
    if (_row) {
        partial_sync::unsubscribe(Object(_realm->_realm, *_info->objectSchema, _row));
    }
}

- (void)addObserver:(id)observer
         forKeyPath:(NSString *)keyPath
            options:(NSKeyValueObservingOptions)options
            context:(void *)context {
    if (!_token) {
        struct {
            __weak RLMSyncSubscriptionObject *weakSelf;

            void before(realm::CollectionChangeSet const&) {
                @autoreleasepool {
                    [weakSelf willChangeValueForKey:@"state"];
                }
            }

            void after(realm::CollectionChangeSet const&) {
                @autoreleasepool {
                    [weakSelf didChangeValueForKey:@"state"];
                }
            }

            void error(std::exception_ptr) {}
        } callback{self};
        _obj = Object(_realm->_realm, *_info->objectSchema, _row);
        _token = _obj.add_notification_callback(callback);
    }
    [super addObserver:observer forKeyPath:keyPath options:options context:context];
}
@end

@interface RLMSyncSubscriptionNew : RLMSyncSubscription
@end

@implementation RLMSyncSubscriptionNew {
    partial_sync::SubscriptionNotificationToken _token;
    util::Optional<partial_sync::Subscription> _subscription;
    RLMRealm *_realm;
}

- (instancetype)initWithName:(NSString *)name results:(Results const&)results realm:(RLMRealm *)realm {
    if (!(self = [super initPrivate]))
        return nil;

    _name = [name copy];
    _realm = realm;
    try {
        _subscription = partial_sync::subscribe(results, name ? util::make_optional<std::string>(name.UTF8String) : util::none);
    }
    catch (std::exception const& e) {
        @throw RLMException(e);
    }
    self.state = (RLMSyncSubscriptionState)_subscription->state();
    __weak auto weakSelf = self;
    _token = _subscription->add_notification_callback([weakSelf] {
        auto self = weakSelf;
        if (!self)
            return;

        // Retrieve the current error and status. Update our properties only if the values have changed,
        // since clients use KVO to observe these properties.

        if (auto error = self->_subscription->error()) {
            try {
                std::rethrow_exception(error);
            } catch (...) {
                NSError *nsError;
                RLMRealmTranslateException(&nsError);
                if (!self.error || ![self.error isEqual:nsError])
                    self.error = nsError;
            }
        }
        else if (self.error) {
            self.error = nil;
        }

        auto status = (RLMSyncSubscriptionState)self->_subscription->state();
        if (status != self.state) {
            if (status == RLMSyncSubscriptionStateCreating) {
                // If a subscription is deleted without going through this
                // object's unsubscribe() method the subscription will transition
                // back to Creating rather than Invalidated since it doesn't
                // have a good way to track that it previously existed
                if (self.state != RLMSyncSubscriptionStateInvalidated)
                    self.state = RLMSyncSubscriptionStateInvalidated;
            }
            else {
                self.state = status;
            }
        }
    });

    return self;
}

- (void)unsubscribe {
    partial_sync::unsubscribe(*_subscription);
}
@end

RLMResultsSetInfo::RLMResultsSetInfo(__unsafe_unretained RLMRealm *const realm)
: osObjectSchema(ObjectSchema(realm->_realm->read_group(), "__ResultSets"))
, rlmObjectSchema([RLMObjectSchema objectSchemaForObjectStoreSchema:osObjectSchema])
, info(realm, rlmObjectSchema, &osObjectSchema)
{
    rlmObjectSchema.accessorClass = [RLMSyncSubscriptionObject class];
}

RLMClassInfo& RLMResultsSetInfo::get(__unsafe_unretained RLMRealm *const realm) {
    if (!realm->_resultsSetInfo) {
        realm->_resultsSetInfo = std::make_unique<RLMResultsSetInfo>(realm);
    }
    return realm->_resultsSetInfo->info;
}

@interface RLMSubscriptionResults : RLMResults
@end

@implementation RLMSubscriptionResults {
}

+ (instancetype)resultsWithRealm:(RLMRealm *)realm {
    // The server automatically adds a few subscriptions for the permissions types which we want to hide
    auto table = ObjectStore::table_for_object_type(realm->_realm->read_group(), "__ResultSets");
    auto query = table->where().ends_with(table->get_column_index("matches_property"), "_matches");
    return [self resultsWithObjectInfo:RLMResultsSetInfo::get(realm)
                               results:Results(realm->_realm, std::move(query))];
}
@end

@implementation RLMResults (SyncSubscription)
- (RLMSyncSubscription *)subscribe {
    return [[RLMSyncSubscriptionNew alloc] initWithName:nil results:_results realm:self.realm];
}

- (RLMSyncSubscription *)subscribeWithName:(NSString *)subscriptionName {
    return [[RLMSyncSubscriptionNew alloc] initWithName:subscriptionName results:_results realm:self.realm];
}

- (RLMSyncSubscription *)subscribeWithName:(NSString *)subscriptionName limit:(NSUInteger)limit {
    return [[RLMSyncSubscriptionNew alloc] initWithName:subscriptionName results:_results.limit(limit) realm:self.realm];
}
@end

@implementation RLMRealm (SyncSubscription)
- (RLMResults<RLMSyncSubscription *> *)subscriptions {
    [self verifyThread];
    return [RLMSubscriptionResults resultsWithRealm:self];
}

- (nullable RLMSyncSubscription *)subscriptionWithName:(NSString *)name {
    [self verifyThread];
    auto& info = RLMResultsSetInfo::get(self);
    auto row = info.table()->find_first(info.table()->get_column_index("name"),
                                        RLMStringDataWithNSString(name));
    if (row == npos) {
        return nil;
    }
    RLMObjectBase *acc = RLMCreateManagedAccessor(info.rlmObjectSchema.accessorClass, self, &info);
    acc->_row = info.table()->get(row);
    return (RLMSyncSubscription *)acc;
}
@end
