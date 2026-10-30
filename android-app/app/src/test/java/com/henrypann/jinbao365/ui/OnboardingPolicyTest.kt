package com.henrypann.jinbao365.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class OnboardingPolicyTest {
    @Test fun identityAlwaysComesFirst() {
        for (complete in listOf(false, true)) for (done in listOf(false, true)) for (cloud in listOf(false, true))
            assertEquals(OnboardingStep.Parent, nextOnboardingStep(complete, done, cloud, false))
    }
    @Test fun optionalPermissionsNeverAddAnOnboardingStep() {
        for (complete in listOf(false, true)) for (done in listOf(false, true)) {
            assertEquals(OnboardingStep.Cloud, nextOnboardingStep(complete, done, false, true))
            assertEquals(OnboardingStep.Home, nextOnboardingStep(complete, done, true, true))
        }
    }
    @Test fun oldPermissionSwitchCannotReintroduceTheGate() {
        assertEquals(OnboardingStep.Home, nextOnboardingStep(false, false, true, true, requirePhotos = true))
    }
}
