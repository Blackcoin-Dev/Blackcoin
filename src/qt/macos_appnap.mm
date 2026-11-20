// Copyright (c) 2011-2018 The Bitcoin Core developers
// Copyright (c) 2011-2018 Blackcoin Core Developers
// Copyright (c) 2011-2018 Blackcoin More Developers
// Copyright (c) 2011-2018 Blackcoin Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include "macos_appnap.h"

#include <AvailabilityMacros.h>
#include <Foundation/NSProcessInfo.h>
#include <Foundation/Foundation.h>

class CAppNapInhibitor::CAppNapImpl
{
public:
    ~CAppNapImpl()
    {
        if(activityId)
            enableAppNap();
    }

    void disableAppNap()
    {
        if (!activityId)
        {
            @autoreleasepool {
                // User-initiated work: keeps App Nap off and the process on
                // the performance cores, disables sudden and automatic
                // termination, and still lets the system and display sleep
                // when idle.
                const NSActivityOptions activityOptions =
                NSActivityUserInitiatedAllowingIdleSystemSleep;

                id processInfo = [NSProcessInfo processInfo];
                if ([processInfo respondsToSelector:@selector(beginActivityWithOptions:reason:)])
                {
                    activityId = [processInfo beginActivityWithOptions: activityOptions reason:@"Blackcoin Core is loading wallets, syncing, staking or mining."];
                    [activityId retain];
                }
            }
        }
    }

    bool held() const { return activityId != nil; }

    void enableAppNap()
    {
        if(activityId)
        {
            @autoreleasepool {
                id processInfo = [NSProcessInfo processInfo];
                if ([processInfo respondsToSelector:@selector(endActivity:)])
                    [processInfo endActivity:activityId];

                [activityId release];
                activityId = nil;
            }
        }
    }

private:
    NSObject* activityId{nil};
};

CAppNapInhibitor::CAppNapInhibitor() : impl(new CAppNapImpl()) {}

CAppNapInhibitor::~CAppNapInhibitor() = default;

void CAppNapInhibitor::disableAppNap()
{
    impl->disableAppNap();
}

bool CAppNapInhibitor::isAppNapDisabled() const
{
    return impl->held();
}

void CAppNapInhibitor::enableAppNap()
{
    impl->enableAppNap();
}
