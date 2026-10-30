package com.henrypann.jinbao365.ui

/** Photo selection uses per-URI grants; optional metadata never blocks onboarding. */
const val REQUIRE_PHOTOS_PERMISSION_GATE = false

enum class OnboardingStep { Permissions, Cloud, Parent, Home }

@Suppress("UNUSED_PARAMETER")
fun nextOnboardingStep(
    permissionsComplete: Boolean,
    permissionsStepDone: Boolean,
    cloudConnected: Boolean,
    parentConfirmed: Boolean,
    requirePhotos: Boolean = REQUIRE_PHOTOS_PERMISSION_GATE,
): OnboardingStep = when {
    !parentConfirmed -> OnboardingStep.Parent
    !cloudConnected -> OnboardingStep.Cloud
    else -> OnboardingStep.Home
}
